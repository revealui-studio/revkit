#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu',
    [string]$SnapshotDir = 'E:\backups\wsl-snapshots\current',
    [long]$ReserveBytes = 1GB,
    [ValidateSet('full-image', 'borg-readiness')][string]$RecoveryBackend = 'full-image',
    [string]$IncrementalConfigurationPath,
    [string]$IncrementalObservationPath,
    [string]$ReviewedConfigurationSha256,
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib' 'WslBackup.ps1')
if ($RecoveryBackend -ceq 'borg-readiness') {
    if ($Execute) { throw 'Borg execution is unavailable: only the readiness/evidence contract is implemented. No backend, repository or key was invoked.' }
    Get-WslBorgReadinessPlan -ConfigurationPath $IncrementalConfigurationPath -ObservationPath $IncrementalObservationPath -ReviewedConfigurationSha256 $ReviewedConfigurationSha256 | ConvertTo-Json -Depth 12
    exit 3
}
if ($IncrementalConfigurationPath -or $IncrementalObservationPath -or $ReviewedConfigurationSha256) {
    throw 'Incremental inputs require the explicit borg-readiness contract; refusing a full-export fallback.'
}
Assert-WslBackupLeaf $Distro
$source = Get-WslRegisteredVhdx -Distro $Distro
$destination = Get-Item -LiteralPath $SnapshotDir -ErrorAction Stop
if (-not $destination.PSIsContainer -or ($destination.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'SnapshotDir must be an existing private directory, not a link.'
}
if ($null -eq $destination.PSDrive.Free) { throw 'Available destination capacity could not be determined.' }
if ($Execute) {
    $acl = Get-Acl -LiteralPath $destination.FullName
    $allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
    foreach ($entry in $acl.Access) {
        if ($entry.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $entry.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $allowed) {
            throw 'SnapshotDir grants access outside the owner, SYSTEM and Administrators.'
        }
    }
    $running = @(& wsl.exe --list --running --quiet)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot verify the source distribution is stopped.' }
    foreach ($line in $running) {
        if ($line.ToString().Replace([string][char]0, '').Trim() -ceq $Distro) {
            throw 'Cold backup requires the source to be quiesced and stopped before execution. No distributions were terminated.'
        }
    }
}
$mutex = $null
$held = $false
try {
    if ($Execute) {
        $scopeHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($destination.FullName.ToUpperInvariant())))
        $mutex = [Threading.Mutex]::new($false, ('Global\revealfleet-WslBackup-' + $scopeHash))
        try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'A backup already owns this destination; refusing a concurrent export.' }
        Set-WslBackupAwake
    }
    $destination = Get-Item -LiteralPath $SnapshotDir -ErrorAction Stop
    $result = Invoke-WslColdBackup -Distro $Distro -SourceVhdx $source -Directory $destination.FullName -AvailableBytes $destination.PSDrive.Free -ReserveBytes $ReserveBytes -Execute:$Execute
} finally {
    if ($Execute) { Clear-WslBackupAwake }
    if ($held) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
$result | ConvertTo-Json -Depth 6
if ($Execute) {
    Write-Warning 'Export is pending artifact-bound independent restoration validation. Existing recovery files were preserved; retention did not run.'
    exit 3
}

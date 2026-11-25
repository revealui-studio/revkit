#Requires -Version 7.0

[CmdletBinding()]
param([switch]$LivePlatform)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
. (Join-Path $root 'scripts' 'lib' 'WslBackup.ps1')
. (Join-Path $root 'scripts' 'lib' 'WslPlatform.ps1')
. (Join-Path $root 'powershell' 'Modules' 'RevealUI.RevStation' 'Private' 'ConvertFrom-WslProbeState.ps1')
function Assert-RecoveryTest {
    param([bool]$Passed, [string]$Message)
    if (-not $Passed) { throw $Message }
}
function Assert-RecoveryRefusal {
    param([scriptblock]$Action)
    $refused = $false
    try { & $Action | Out-Null } catch { $refused = $true }
    Assert-RecoveryTest $refused 'Expected the unsafe recovery operation to be refused.'
}
$plan = Get-WslBackupCapacityPlan -SourceBytes 635582808064 -AvailableBytes 943636373504 -ReserveBytes 1GB
Assert-RecoveryTest $plan.CanExport 'The measured first full image should fit.'
$next = Get-WslBackupCapacityPlan -SourceBytes 635582808064 -AvailableBytes (943636373504 - 635582808064) -ReserveBytes 1GB
Assert-RecoveryTest (-not $next.CanExport -and $next.ReclaimBeforeExportBytes -eq 0) 'Replacement must refuse without deleting existing recovery.'
Assert-RecoveryTest ((ConvertFrom-WslProbeState -Output @('NOT_MOUNTED') -AllowedStates @('MOUNTED', 'NOT_MOUNTED')) -ceq 'NOT_MOUNTED') 'Mount state must be exact.'
Assert-RecoveryTest ((ConvertFrom-WslPlatformVersion -Output @('WSL version: 3.0.5.0')) -eq [Version]'3.0.5.0') 'Supported WSL version parse failed.'
Assert-RecoveryRefusal { Assert-WslPlatformVersion -Version ([Version]'2.6.0.0') }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('revealfleet-recovery-test-' + [Guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($temporary)
try {
    $artifact = Join-Path $temporary 'synthetic.vhdx'
    [IO.File]::WriteAllText($artifact, 'synthetic recovery bytes')
    $proof = Join-Path $temporary 'synthetic-proof.json'
    $hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
    $evidence = @{
        schemaVersion = 1; kind = 'revealfleet-wsl-restore-validation'; sourceDistro = 'Ubuntu'
        recoveryDistro = 'Ubuntu-synthetic-recovery'; artifactSha256 = $hash
        artifactBytes = (Get-Item -LiteralPath $artifact).Length
        artifactPreserved = $true; verifiedAt = [DateTimeOffset]::UtcNow.ToString('o')
        verifierProtocol = 'revealfleet-isolated-restore-probe-v1'; verifierSourceSha256 = '1' * 64
        probe = @{ protocol = 'revealfleet-isolated-restore-probe-v1'; pid1Comm = 'init'; rootFilesystem = 'ext4'; uid = 1000; homeExists = $true; repositoryExists = $true; unexpectedProcesses = @() }
        checks = @{ registration = $true; filesystem = $true; boot = $true; identity = $true; servicesIsolated = $true }
    }
    $evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $proof
    $verified = Confirm-WslBackupArtifact -ArtifactPath $artifact -Distro Ubuntu -RestoreEvidencePath $proof
    $checked = Get-WslVerifiedBackup -ReceiptPath $verified.ReceiptPath -VerifyContent
    Assert-RecoveryTest ($checked.Sha256 -ceq $hash) 'Synthetic artifact verification failed.'
    [IO.File]::AppendAllText($artifact, 'changed')
    Assert-RecoveryRefusal { Get-WslVerifiedBackup -ReceiptPath $verified.ReceiptPath }
} finally { [IO.Directory]::Delete($temporary, $true) }
$platform = if ($LivePlatform) { (Assert-WslPlatformVersion).ToString() } else { $null }
[pscustomobject]@{ Passed = $true; LiveWslPlatform = $platform; ProductionStateMutated = $false; Test = 'synthetic-capacity-state-receipt' } | ConvertTo-Json -Compress

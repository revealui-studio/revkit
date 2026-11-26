#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$SnapshotDir = 'E:\backups\wsl-snapshots\current',
    [string]$Distro = 'Ubuntu',
    [ValidateRange(1, 3650)][int]$MaxAgeDays = 10,
    [string]$EventSource = 'RevealUI-Health',
    [int]$EventId = 9100,
    [switch]$VerifyContent
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib' 'WslBackup.ps1')
function Write-Health {
    param([string]$EntryType, [string]$Message)
    Write-Host "$([DateTimeOffset]::UtcNow.ToString('o')) [$EntryType] $Message"
    if ($IsWindows) {
        try {
            [System.Diagnostics.EventLog]::WriteEntry($EventSource, $Message, [System.Diagnostics.EventLogEntryType]::$EntryType, $EventId)
        } catch {
            $fallback = Join-Path $SnapshotDir 'health.log'
            Add-Content -LiteralPath $fallback -Value "$EntryType $Message" -ErrorAction Stop
        }
    }
}
if (-not (Test-Path -LiteralPath $SnapshotDir -PathType Container)) {
    Write-Health Error 'WSL backup directory is missing.'
    exit 1
}
$backups = @(Get-WslVerifiedBackups -Directory $SnapshotDir -Distro $Distro -VerifyContent:$VerifyContent | Sort-Object VerifiedAt -Descending)
if ($backups.Count -eq 0) {
    Write-Health Error 'No artifact-bound, independently restore-verified WSL backup exists. Export timestamps and image sizes do not establish recovery.'
    exit 1
}
$age = ([DateTimeOffset]::UtcNow - $backups[0].VerifiedAt).TotalDays
if ($age -gt $MaxAgeDays) {
    Write-Health Warning "Newest independently verified recovery is $([Math]::Round($age, 1)) days old; threshold is $MaxAgeDays days."
    exit 2
}
[pscustomobject]@{ Artifact = $backups[0].ArtifactPath; VerifiedAt = $backups[0].VerifiedAt; ContentRehashed = [bool]$VerifyContent } | ConvertTo-Json -Compress

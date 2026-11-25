#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$ArtifactPath,
    [Parameter(Mandatory)][string]$RestoreEvidencePath,
    [string]$Distro = 'Ubuntu',
    [ValidateRange(1, 1000)][int]$KeepCount = 1,
    [switch]$Prune
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib' 'WslBackup.ps1')
if (-not $PSCmdlet.ShouldProcess($ArtifactPath, 'Record artifact-bound restore verification')) { return }
$verified = Confirm-WslBackupArtifact -ArtifactPath $ArtifactPath -Distro $Distro -RestoreEvidencePath $RestoreEvidencePath
$directory = [IO.Path]::GetDirectoryName($verified.ArtifactPath)
$backups = @(Get-WslVerifiedBackups -Directory $directory -Distro $Distro -VerifyContent)
$retention = @(Get-WslBackupRetentionPlan -VerifiedBackups $backups -NewVerifiedArtifact $verified.ArtifactPath -KeepCount $KeepCount)
[pscustomobject]@{ Verified = $verified; RetentionCandidates = @($retention.ArtifactPath); PruneRequested = [bool]$Prune } | ConvertTo-Json -Depth 8
if ($Prune) {
    foreach ($old in $retention) {
        if ($PSCmdlet.ShouldProcess($old.ArtifactPath, 'Delete older independently verified recovery and its metadata')) {
            Remove-Item -LiteralPath $old.ArtifactPath -ErrorAction Stop
            Remove-Item -LiteralPath $old.ReceiptPath -ErrorAction Stop
            Remove-Item -LiteralPath $old.RestoreEvidencePath -ErrorAction Stop
        }
    }
}

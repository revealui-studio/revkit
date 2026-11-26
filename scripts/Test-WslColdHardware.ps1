#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PolicyPath,[Parameter(Mandatory)][string]$ReviewedPolicySha256)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib' 'WslBackup.ps1')
if(-not $IsWindows){throw 'Windows hardware observations require Windows.'}
[void](Assert-WslColdProtectedPath $PolicyPath)
$doc=Read-WslRecoveryDocument $PolicyPath
if($doc.Sha256 -cne $ReviewedPolicySha256){throw 'Live signed policy changed.'}
$p=$doc.Value
Assert-WslColdRepositoryHardware $p.repository
foreach($row in @($p.controller.source,$p.controller.protected,@{vhdx=$p.controller.workerVhdx.path;hardware=$p.controller.workerVhdx.hardware},@{vhdx=$p.controller.restore.path;hardware=$p.controller.restore.hardware})) {
    [void](Assert-WslColdWindowsHardware $row.vhdx $row.hardware)
}
# No source reads, worker launch, mounts, credentials or mutations.
[Console]::Write('windows-hardware-bound-v1')

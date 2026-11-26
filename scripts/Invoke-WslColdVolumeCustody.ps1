#Requires -Version 7.0
[CmdletBinding()]
param([ValidateSet('Plan','Apply','Rollback','PlanRollback')][string]$Phase='Plan',[string]$PolicyPath,[string]$PlanPath,[string]$ReviewedPlanSha256,[string]$ApplyReceiptPath,[string]$ReviewedApplyReceiptSha256)
$ErrorActionPreference='Stop'
if($Phase -cin @('Apply','Rollback') -and ('Revealfleet.Backup.ColdProtocol' -as [type])){throw 'Apply/Rollback require a fresh noninteractive PowerShell process and reviewed source closure.'}
. (Join-Path $PSScriptRoot 'lib/WslColdVolumeCustody.ps1')
if($Phase -ceq 'Plan') {
    if(-not $PolicyPath -or $PlanPath -or $ReviewedPlanSha256 -or $ApplyReceiptPath -or $ReviewedApplyReceiptSha256){throw 'Plan accepts only an explicit policy path; stdout is review data, not authority.'}
    $policy=Read-WslRecoveryDocument $PolicyPath
    Get-WslColdVolumeCustodyPlan $policy.Value | ConvertTo-Json -Depth 30
} elseif($Phase -ceq 'PlanRollback') {
    if($PolicyPath -or -not $PlanPath -or -not $ReviewedPlanSha256){throw 'PlanRollback requires original saved plan and independently reviewed digest.'}
    Get-WslColdVolumeRollbackPlan $PlanPath $ReviewedPlanSha256 $ApplyReceiptPath $ReviewedApplyReceiptSha256 | ConvertTo-Json -Depth 30
} else {
    if($PolicyPath -or -not $PlanPath -or -not $ReviewedPlanSha256 -or $ApplyReceiptPath -or $ReviewedApplyReceiptSha256){throw 'Apply/Rollback require the independently reviewed saved plan and exact SHA256.'}
    Invoke-WslColdVolumeCustody -Phase $Phase -PlanPath $PlanPath -ReviewedPlanSha256 $ReviewedPlanSha256 | ConvertTo-Json -Depth 12
}

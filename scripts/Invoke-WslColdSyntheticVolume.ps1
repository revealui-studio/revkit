#Requires -Version 7.0
[CmdletBinding()]
param([ValidateSet('Plan','Execute')][string]$Phase='Plan',[string]$FixtureParent,[string]$EvidenceParent,[string]$SourceManifestSha256,[string]$PlanPath,[string]$ReviewedPlanSha256)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib/WslColdSyntheticVolume.ps1')
if($Phase -ceq 'Plan'){
    if($PlanPath -or $ReviewedPlanSha256 -or -not $FixtureParent -or -not $EvidenceParent -or -not $SourceManifestSha256){throw 'Plan requires only explicit protected C parents and source manifest hash.'}
    Get-WslColdSyntheticVolumePlan $FixtureParent $EvidenceParent $SourceManifestSha256|ConvertTo-Json -Depth 30
}else{
    if($FixtureParent -or $EvidenceParent -or $SourceManifestSha256 -or -not $PlanPath -or -not $ReviewedPlanSha256){throw 'Execute requires only independently saved/reviewed plan path and exact digest.'}
    Invoke-WslColdSyntheticVolume $PlanPath $ReviewedPlanSha256|ConvertTo-Json -Depth 12
}

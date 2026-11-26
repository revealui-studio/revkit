#Requires -Version 7.0
[CmdletBinding()]
param([ValidateSet('StoragePreflight','Plan','Execute')][string]$Phase='Plan',[string]$FixtureParent,[string]$EvidenceParent,[string]$SourceManifestSha256,[string]$PlanPath,[string]$ReviewedPlanSha256,[ValidateSet('exact-raw-acl-capacity-v1','permission-ace-zero-unused-v1')][string]$FidelityProfile='exact-raw-acl-capacity-v1')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib/WslColdSyntheticVolume.ps1')
if($Phase -ceq 'StoragePreflight'){
    if($FixtureParent -or $EvidenceParent -or $SourceManifestSha256 -or $PlanPath -or $ReviewedPlanSha256 -or $PSBoundParameters.ContainsKey('FidelityProfile')){throw 'Read-only StoragePreflight accepts no disk, fixture, plan or execution inputs.'}
    Get-WslColdStoragePreflight|ConvertTo-Json -Depth 12
}elseif($Phase -ceq 'Plan'){
    if($PlanPath -or $ReviewedPlanSha256 -or -not $FixtureParent -or -not $EvidenceParent -or -not $SourceManifestSha256){throw 'Plan requires only explicit protected C parents and source manifest hash.'}
    Get-WslColdSyntheticVolumePlan $FixtureParent $EvidenceParent $SourceManifestSha256 $FidelityProfile|ConvertTo-Json -Depth 30
}else{
    if($FixtureParent -or $EvidenceParent -or $SourceManifestSha256 -or -not $PlanPath -or -not $ReviewedPlanSha256 -or $PSBoundParameters.ContainsKey('FidelityProfile')){throw 'Execute requires only independently saved/reviewed plan path and exact digest; profile comes from that plan.'}
    Invoke-WslColdSyntheticVolume $PlanPath $ReviewedPlanSha256|ConvertTo-Json -Depth 12
}

#Requires -Version 7.0
# Synthetic acceptance only. No real volume root, worker, VHD, key or repository.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$RetainedFixtureParent,
    [switch]$IncludeElevated,
    [switch]$CreateCiAnchor
)
$ErrorActionPreference='Stop'
if(-not $IsWindows){throw 'Actual Windows required; native compilation is not host acceptance.'}
. (Join-Path $PSScriptRoot '../../scripts/lib/WslColdVolumeCustody.ps1')
Initialize-WslColdWorkerProtocol
if(Test-Path -LiteralPath $OutputDirectory){throw 'Fresh acceptance output directory required.'}
# Output contains only explicitly selected nonsecret synthetic results, never
# fixture payloads or recursive copies. Retain fixtures separately on failure.
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$elevated=$false
if($IncludeElevated -or $CreateCiAnchor){
    if(-not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))){throw 'Elevated synthetic subset requires an actual administrative token.'}
    $scope=[Revealfleet.Backup.ColdRestorePrivilege]::new()
    $scope.Dispose();$elevated=$true
}
if($CreateCiAnchor){
    if($env:GITHUB_ACTIONS -cne 'true' -or $RetainedFixtureParent){throw 'Disposable GitHub Windows runner only; no caller-selected CI anchor.'}
    # Existing ProgramFiles and its ancestors are read/validated, never edited.
    [void](Assert-WslColdProtectedPath $env:ProgramFiles -Directory)
    $RetainedFixtureParent=Join-Path $env:ProgramFiles ('revkit-synthetic-'+[Guid]::NewGuid().ToString('N'))
    [Revealfleet.Backup.ColdSourceLease]::CreateProtectedDirectory($RetainedFixtureParent,(New-WslColdNamespaceDescriptor ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)))
}
if(-not $RetainedFixtureParent){throw 'Explicit audited private synthetic fixture parent required.'}
[void](Assert-WslColdProtectedPath $RetainedFixtureParent -Directory -PrivateData)
$names=@('WindowsArtifactDeployment','CodexOfflineCopy','WslColdVolumeCustody','WslColdControl','WslColdAdmission','WslColdWorker','WslColdContainer')
$containers=@()
foreach($name in $names){
    $path=Join-Path $PSScriptRoot ($name+'.Tests.ps1')
    $data=if($name -ceq 'WslColdVolumeCustody'){@{RetainedFixtureParent=$RetainedFixtureParent}}else{@{}}
    $containers+=New-PesterContainer -Path $path -Data $data
}
$env:REVKIT_TEST_PYTHON=(Get-Command python -ErrorAction Stop).Source
$config=New-PesterConfiguration
$config.Run.Container=$containers;$config.Run.PassThru=$true;$config.Run.Exit=$false
if(-not $IncludeElevated){$config.Filter.ExcludeTag=@('Elevated')}
$config.Output.Verbosity='Detailed'
$config.TestResult.Enabled=$true;$config.TestResult.OutputPath=Join-Path $OutputDirectory 'windows-results.xml'
$config.TestResult.OutputFormat='NUnitXml'
$result=Invoke-Pester -Configuration $config
$expectedSkips=@('cannot invoke native mutation or accept another plan without Windows admission','has no native-host fallback that can open a real Windows source')
$unexpected=@($result.Tests|Where-Object {$_.Result -eq 'Skipped' -and $_.Name -cnotin $expectedSkips})
$summary=@{schemaVersion=1;syntheticOnly=$true;productionAccepted=$false;nativeApiCandidateAcceptedForProduction=$false;total=$result.TotalCount;passed=$result.PassedCount;failed=$result.FailedCount;skipped=$result.SkippedCount;notRun=$result.NotRunCount;unexpectedSkips=@($unexpected.Name);elevatedRequested=[bool]$IncludeElevated;elevatedPrerequisiteProved=$elevated;fixtureParent=$RetainedFixtureParent;xmlSha256=(Get-FileHash -LiteralPath $config.TestResult.OutputPath.Value).Hash.ToLowerInvariant()}
Write-WslBackupJsonNew (Join-Path $OutputDirectory 'windows-acceptance.json') $summary
if($result.FailedCount -ne 0 -or $result.NotRunCount -ne 0 -or $result.TotalCount -eq 0 -or $unexpected.Count -ne 0){throw 'Windows synthetic acceptance failed; preserve XML, summary and original fixture trees.'}
$summary

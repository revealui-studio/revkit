#Requires -Version 7.0
# Synthetic acceptance only. No real volume root, worker, VHD, key or repository.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$RetainedFixtureParent,
    [string]$AdminFixtureParent,
    [string]$PythonPath,
    [string]$PythonSha256,
    [switch]$IncludeElevated,
    [switch]$CreateCiAnchor
)
$ErrorActionPreference='Stop'
if(-not $IsWindows){throw 'Actual Windows required; native compilation is not host acceptance.'}
. (Join-Path $PSScriptRoot '../../scripts/lib/WslColdVolumeCustody.ps1')
Initialize-WslColdWorkerProtocol
. (Join-Path $PSScriptRoot 'WslColdWindowsAcceptance.Helpers.ps1')
if(Test-Path -LiteralPath $OutputDirectory){throw 'Fresh acceptance output directory required.'}
# Output contains only explicitly selected nonsecret synthetic results, never
# fixture payloads or recursive copies. Retain fixtures separately on failure.
[void][IO.Directory]::CreateDirectory($OutputDirectory)
try {
$elevated=$false
if($IncludeElevated){
    if(-not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))){throw 'Elevated synthetic subset requires an actual administrative token.'}
    $scope=[Revealfleet.Backup.ColdRestorePrivilege]::new()
    $scope.Dispose();$elevated=$true
}
if($CreateCiAnchor){
    if($env:GITHUB_ACTIONS -cne 'true' -or $RetainedFixtureParent){throw 'Disposable GitHub Windows runner only; no caller-selected CI anchor.'}
    $RetainedFixtureParent=New-WslColdSyntheticAnchor -Parent ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) -AuditPath (Join-Path $OutputDirectory 'private-anchor-audit.json')
    if($IncludeElevated){
        $AdminFixtureParent=New-WslColdSyntheticAnchor -Parent $env:ProgramFiles -Authority -AuditPath (Join-Path $OutputDirectory 'authority-anchor-audit.json')
    }
}
if(-not $RetainedFixtureParent){throw 'Explicit audited private synthetic fixture parent required.'}
[void](Assert-WslColdProtectedPath $RetainedFixtureParent -Directory -PrivateData)
$names=@('WindowsArtifactDeployment','CodexOfflineCopy','WslColdVolumeCustody','WslColdControl','WslColdAdmission','WslColdWorker','WslColdContainer','WslColdWindowsAcceptance')
$containers=@()
foreach($name in $names){
    $path=Join-Path $PSScriptRoot ($name+'.Tests.ps1')
    $data=if($name -ceq 'WslColdVolumeCustody'){@{RetainedFixtureParent=$RetainedFixtureParent;AdminFixtureParent=$AdminFixtureParent}}else{@{}}
    $containers+=New-PesterContainer -Path $path -Data $data
}
if($IncludeElevated -and -not $AdminFixtureParent){throw 'Separately audited public-authority synthetic parent required for elevated namespace case.'}
if($PythonPath){
    if(-not [IO.Path]::IsPathFullyQualified($PythonPath) -or -not (Test-Path -LiteralPath $PythonPath -PathType Leaf)){throw 'Explicit absolute installed Python executable required.'}
    Assert-WslBackupHash $PythonSha256
    if((Get-FileHash -LiteralPath $PythonPath).Hash.ToLowerInvariant() -cne $PythonSha256){throw 'Synthetic interpreter differs from reviewed installed binary.'}
    $env:REVKIT_TEST_PYTHON=$PythonPath
}else{$env:REVKIT_TEST_PYTHON=(Get-Command python -ErrorAction Stop).Source}
if($PythonSha256 -and -not $PythonPath){throw 'Reviewed interpreter digest requires its explicit path.'}
$manifest=Get-WslColdCaseManifest @($containers|ForEach-Object {$_.Item.FullName})
$config=New-PesterConfiguration
$config.Run.Container=$containers;$config.Run.PassThru=$true;$config.Run.Exit=$false
if(-not $IncludeElevated){$config.Filter.ExcludeTag=@('Elevated')}
$config.Output.Verbosity='Detailed'
$config.TestResult.Enabled=$true;$config.TestResult.OutputPath=Join-Path $OutputDirectory 'windows-results.xml'
$config.TestResult.OutputFormat='NUnitXml'
$result=Invoke-Pester -Configuration $config
$observed=@($result.Tests|ForEach-Object {
    $test=$_;$block=$test.Block;$tags=@($test.Tag)
    while($block){$tags+=@($block.Tag);$block=$block.Parent}
    @{file=[IO.Path]::GetFullPath($test.ScriptBlock.File);name=$test.Name;result=[string]$test.Result;elevated=('Elevated' -cin $tags);shouldRun=[bool]$test.ShouldRun}
})
$accounting=Get-WslColdAcceptanceAccounting $manifest $observed -IncludeElevated:$IncludeElevated
$summary=@{schemaVersion=2;syntheticOnly=$true;productionAccepted=$false;nativeApiCandidateAcceptedForProduction=$false;accounting=$accounting;total=$result.TotalCount;passed=$result.PassedCount;failed=$result.FailedCount;skipped=$result.SkippedCount;notRun=$result.NotRunCount;unexpectedSkips=[string[]]$accounting.unexpectedSkips;ordinaryComponentAccepted=$accounting.componentAccepted;elevatedRequested=[bool]$IncludeElevated;elevatedPrerequisiteProved=$elevated;elevatedAccepted=([bool]$IncludeElevated -and $elevated -and $accounting.componentAccepted);fullSyntheticAccepted=([bool]$IncludeElevated -and $elevated -and $accounting.componentAccepted);pythonPath=$env:REVKIT_TEST_PYTHON;pythonSha256=(Get-FileHash -LiteralPath $env:REVKIT_TEST_PYTHON).Hash.ToLowerInvariant();fixtureParent=$RetainedFixtureParent;adminFixtureParent=$AdminFixtureParent;xmlSha256=(Get-FileHash -LiteralPath $config.TestResult.OutputPath.Value).Hash.ToLowerInvariant()}
Write-WslBackupJsonNew (Join-Path $OutputDirectory 'windows-acceptance.json') $summary
if(-not $accounting.componentAccepted){throw 'Windows synthetic acceptance failed; preserve XML, summary and original fixture trees.'}
$summary

} catch {
    $primary=$_
    # A preflight refusal must leave a bounded result too; never overwrite a
    # completed Pester summary or replace the original failure with evidence I/O.
    try {
        $path=Join-Path $OutputDirectory 'windows-acceptance.json'
        if(-not (Test-Path -LiteralPath $path)){
            $message=$primary.Exception.Message
            if($message.Length -gt 2048){$message=$message.Substring(0,2048)}
            Write-WslBackupJsonNew $path @{schemaVersion=1;syntheticOnly=$true;productionAccepted=$false;phase='runner-refusal';testsAccepted=$false;reason=$message}
        }
    } catch {Write-Warning 'Secondary acceptance receipt failed; original refusal preserved.'}
    throw $primary
}

BeforeAll {. (Join-Path $PSScriptRoot 'WslColdWindowsAcceptance.Helpers.ps1')}
Describe 'Windows component accounting never promotes excluded elevation or missing tests' {
    BeforeEach {
        $script:file='/synthetic/WslColdVolumeCustody.Tests.ps1'
        $script:elevated='restores an unresolved SID with scoped privilege and leaves all descendants unchanged'
        $script:manifest=@(@{file=$file;name='ordinary proof'},@{file=$file;name=$elevated})
        $script:observed=@(@{file=$file;name='ordinary proof';result='Passed';elevated=$false;shouldRun=$true},@{file=$file;name=$elevated;result='NotRun';elevated=$true;shouldRun=$false})
    }
    It 'accepts only the selected ordinary component with exact explicitly filtered elevation and empty arrays' {
        $a=Get-WslColdAcceptanceAccounting $manifest $observed
        $a.componentAccepted|Should -BeTrue;$a.total|Should -Be 2;$a.selected|Should -Be 1;$a.excluded|Should -Be 1;$a.notRun|Should -Be 0
        ($a|ConvertTo-Json -Compress).Contains('"unexpectedSkips":[]')|Should -BeTrue
    }
    It 'refuses filtered elevation during full acceptance and unexpected not-run or skipped tests' {
        (Get-WslColdAcceptanceAccounting $manifest $observed -IncludeElevated).componentAccepted|Should -BeFalse
        $observed[0].result='NotRun';(Get-WslColdAcceptanceAccounting $manifest $observed).componentAccepted|Should -BeFalse
        $observed[0].result='Skipped';(Get-WslColdAcceptanceAccounting $manifest $observed).componentAccepted|Should -BeFalse
        $observed[0].result='Passed';$observed[1].elevated=$false;(Get-WslColdAcceptanceAccounting $manifest $observed).componentAccepted|Should -BeFalse
    }
    It 'refuses discovery omissions, duplicates and unknown cases' {
        (Get-WslColdAcceptanceAccounting $manifest @($observed[0])).componentAccepted|Should -BeFalse
        {Get-WslColdAcceptanceAccounting $manifest @($observed[0],$observed[0])}|Should -Throw
        $observed[1].name='unexpected case';{Get-WslColdAcceptanceAccounting $manifest $observed}|Should -Throw
    }
    It 'inventories all committed literal cases per required owner without executing any test body' {
        $paths=@('WslColdVolumeCustody','WslColdControl','WslColdAdmission','WslColdWorker','WslColdContainer','WindowsArtifactDeployment','CodexOfflineCopy')|ForEach-Object {Join-Path $PSScriptRoot ($_+'.Tests.ps1')}
        $containers=@($paths|ForEach-Object {New-PesterContainer -Path $_})
        $manifest=Get-WslColdCaseManifest @($containers|ForEach-Object {$_.Item.FullName})
        $manifest.Count|Should -BeGreaterThan 100
        foreach($path in $paths){@($manifest|Where-Object file -eq $path).Count|Should -BeGreaterThan 0}
    }
}

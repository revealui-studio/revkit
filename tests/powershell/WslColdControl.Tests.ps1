#Requires -Version 7.0
BeforeAll {
    . (Join-Path $PSScriptRoot '..' '..' 'scripts/lib/WslBackup.ps1')
    Initialize-WslColdWorkerProtocol
    function Start-SyntheticControl([string]$Code,[switch]$NoOutputRedirect) {
        $psi=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
        $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=-not $NoOutputRedirect;$psi.RedirectStandardError=$true
        foreach($a in @('-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code)))){$psi.ArgumentList.Add($a)}
        [Diagnostics.Process]::Start($psi)
    }
    function Control-Prefix { '[Console]::Write("revkit-cold-control-started-v1`n");[Console]::Out.Flush();' }
    function Close-SyntheticControl($Child) {
        if(-not $Child.HasExited){$Child.Kill($true);if(-not $Child.WaitForExit(5000)){throw 'Defensive test cleanup unconfirmed'}}
        $Child.Dispose()
    }
}
Describe 'Selected-worker cold-start budget is distinct from operation time' {
    It 'allows slow startup beyond the work deadline then finishes bounded work' {
        $child=Start-SyntheticControl ('[Threading.Thread]::Sleep(1250);'+(Control-Prefix)+'[Console]::Write("{`"runtimeAdmitted`":false}")')
        try {
            $result=[Revealfleet.Backup.ColdProtocol]::RunSelectedControlOnProcessAsync($child,[byte[]]@(),15000,1000,5000).GetAwaiter().GetResult()
            $result|Should -BeExactly '{"runtimeAdmitted":false}'
            $child.HasExited|Should -BeTrue
        } finally {Close-SyntheticControl $child}
    }
    It 'refuses operation timeout, missing marker, diagnostics, nonzero exit and excess output with child exit BEFORE defensive cleanup' {
        $cases=@(
            @{Code=((Control-Prefix)+'[Threading.Thread]::Sleep(10000)');Startup=15000;Work=100},
            @{Code='[Threading.Thread]::Sleep(10000)';Startup=100;Work=5000},
            @{Code=((Control-Prefix)+'[Console]::Error.Write("synthetic startup warning");[Console]::Error.Flush();[Threading.Thread]::Sleep(10000)');Startup=15000;Work=5000},
            @{Code=((Control-Prefix)+'exit 7');Startup=15000;Work=5000},
            @{Code=((Control-Prefix)+'[Console]::Write([string]::new([char]65,65537));[Threading.Thread]::Sleep(10000)');Startup=15000;Work=5000},
            @{Code='[Console]::Write([string]::new([char]88,64));[Threading.Thread]::Sleep(10000)';Startup=15000;Work=5000})
        foreach($case in $cases){
            $child=Start-SyntheticControl $case.Code
            try {
                {[Revealfleet.Backup.ColdProtocol]::RunSelectedControlOnProcessAsync($child,[byte[]]@(),$case.Startup,$case.Work,5000).GetAwaiter().GetResult()}|Should -Throw -ExpectedMessage '*Control command refused*'
                $child.HasExited|Should -BeTrue
            } finally {Close-SyntheticControl $child}
        }
    }
    It 'keeps local signing diagnostics separate from clean selected-worker stderr' {
        $hostPath=(Get-Process -Id $PID).Path
        $code='[Console]::Error.Write("synthetic signing diagnostic");[Console]::Write("verified fixture")'
        $args=@('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code)))
        [Revealfleet.Backup.ColdProtocol]::RunControlAsync($hostPath,$args,[byte[]]@(),5000).GetAwaiter().GetResult()|Should -BeExactly 'verified fixture'
        {[Revealfleet.Backup.ColdProtocol]::RunControlAsync('not-launched',[string[]]@(),[byte[]]@(),30001).GetAwaiter().GetResult()}|Should -Throw
        {[Revealfleet.Backup.ColdProtocol]::RunSelectedWorkerControlAsync('not-launched',[string[]]@(),[byte[]]@(),180001,1000,5000).GetAwaiter().GetResult()}|Should -Throw
    }
    It 'launches both owned control paths in the executable directory independently of caller cwd' {
        $hostPath=(Get-Process -Id $PID).Path
        $expected=[IO.Path]::GetDirectoryName($hostPath)
        $other=Join-Path $TestDrive 'caller-cwd';[void][IO.Directory]::CreateDirectory($other)
        $old=[Environment]::CurrentDirectory
        try {
            [Environment]::CurrentDirectory=$other
            foreach($selected in @($false,$true)){
                $code=if($selected){Control-Prefix}else{''}
                $code+='[Console]::Write([Environment]::CurrentDirectory)'
                $argv=@('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code)))
                $result=if($selected){[Revealfleet.Backup.ColdProtocol]::RunSelectedWorkerControlAsync($hostPath,$argv,[byte[]]@(),15000,5000,5000).GetAwaiter().GetResult()}else{[Revealfleet.Backup.ColdProtocol]::RunControlAsync($hostPath,$argv,[byte[]]@(),5000).GetAwaiter().GetResult()}
                $result|Should -BeExactly $expected
                [Environment]::CurrentDirectory|Should -BeExactly $other
            }
        } finally {[Environment]::CurrentDirectory=$old}
    }
    It 'derives finite phase budgets and fixed control arguments from reviewed selected-worker policy' {
        $p=@{budget=@{timeoutSeconds=60};sourceCommit=('a'*40);transactionId='11111111-1111-4111-8111-111111111111';worker=@{distro='synthetic-worker';interpreter='/usr/bin/python3.14';controlBudget=@{bootInitMilliseconds=60000;launchAllowanceMilliseconds=30000;operationMilliseconds=15000;reconciliationMilliseconds=30000;frontendTeardownMilliseconds=5000}}}
        (Get-WslColdWorkerControlBudget $p prepare).StartupMilliseconds|Should -Be 90000
        (Get-WslColdWorkerControlBudget $p status).OperationMilliseconds|Should -Be 15000
        (Get-WslColdWorkerControlBudget $p reconcile).OperationMilliseconds|Should -Be 30000
        foreach($action in @('prepare','status','reconcile','probe','serve')){
            $argv=Get-WslColdWorkerArguments $p $action
            $argv[0..6]|Should -Be @('--distribution','synthetic-worker','--user','root','--cd','/','--exec')
            if($action -ne 'serve'){$argv|Should -Contain ('--control-'+$action)}
        }
        $p.worker.controlBudget.frontendTeardownMilliseconds=10001
        {Get-WslColdWorkerControlBudget $p reconcile}|Should -Throw
    }
}

Describe 'Control teardown must not infer descendant exit from parent exit' {
    It 'refuses partial control output without claiming descendant exit after frontend exit' {
        $pidFile=Join-Path $TestDrive 'owned-descendant.pid'
        $escaped=$pidFile.Replace("'","''")
        $grandchild='[Threading.Thread]::Sleep(10000)'
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($grandchild))
        $code='$p=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$p.UseShellExecute=$false;$p.CreateNoWindow=$true;'
        $code+='foreach($a in @(''-NoLogo'',''-NoProfile'',''-NonInteractive'',''-EncodedCommand'','''+$encoded+''')){$p.ArgumentList.Add($a)};'
        $code+='$owned=[Diagnostics.Process]::Start($p);[IO.File]::WriteAllText('''+$escaped+''',[string]$owned.Id);'+(Control-Prefix)+'exit 0'
        $child=Start-SyntheticControl $code;$descendant=$null
        try {
            {[Revealfleet.Backup.ColdProtocol]::RunSelectedControlOnProcessAsync($child,[byte[]]@(),15000,1500,200).GetAwaiter().GetResult()}|Should -Throw -ExpectedMessage '*Control command refused*'
            $child.HasExited|Should -BeTrue
            $descendant=[Diagnostics.Process]::GetProcessById([int][IO.File]::ReadAllText($pidFile))
            $descendant.HasExited|Should -BeFalse
        } finally {
            if(-not $descendant -and (Test-Path -LiteralPath $pidFile)){
                try {$descendant=[Diagnostics.Process]::GetProcessById([int][IO.File]::ReadAllText($pidFile))}catch [ArgumentException] {}
            }
            if($descendant){Close-SyntheticControl $descendant};Close-SyntheticControl $child
        }
    }
}

Describe 'Control pipe setup remains inside cleanup ownership' {
    It 'reaps its child before cleanup when a required redirected pipe is unavailable' {
        $child=Start-SyntheticControl '[Threading.Thread]::Sleep(10000)' -NoOutputRedirect
        try {
            {[Revealfleet.Backup.ColdProtocol]::RunSelectedControlOnProcessAsync($child,[byte[]]@(),15000,1000,5000).GetAwaiter().GetResult()}|Should -Throw -ExpectedMessage '*Control command refused*'
            $child.HasExited|Should -BeTrue
        } finally {Close-SyntheticControl $child}
    }
}

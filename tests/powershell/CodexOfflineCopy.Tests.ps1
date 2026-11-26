BeforeAll {
    . (Join-Path $PSScriptRoot '../../scripts/Invoke-CodexOfflineCopy.ps1')
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
        function Get-CimInstance { throw 'Unexpected platform process census in fixture.' }
    }
}
Describe 'Offline copy boundaries' {
    It 'checks digest syntax' {
        { Assert-CodexOfflineDigest ('a' * 64) } | Should -Not -Throw
        { Assert-CodexOfflineDigest ('g' * 64) } | Should -Throw
        { Assert-CodexOfflineDigest ('a' * 63) } | Should -Throw
    }
    It 'detects equal and nested paths but permits adjacent names' {
        $root = Join-Path $TestDrive 'home'
        Test-CodexOfflineOverlap $root $root | Should -BeTrue
        Test-CodexOfflineOverlap $root (Join-Path $root 'child') | Should -BeTrue
        Test-CodexOfflineOverlap $root ($root + '-copy') | Should -BeFalse
    }
    It 'refuses existing destinations' {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'existing')
        { Get-CodexOfflineRegularPath $root.FullName -Directory -Absent } | Should -Throw
    }
    It 'refuses linked ancestry' -Skip:(-not $IsWindows) {
        $root = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'real')
        $link = New-Item -ItemType Junction -Path (Join-Path $TestDrive 'linked') -Target $root.FullName
        { Get-CodexOfflineRegularPath (Join-Path $link.FullName 'copy') -Directory -Absent } | Should -Throw
    }
    It 'detects the app and arbitrary processes referencing the source' {
        Mock Get-CimInstance { [pscustomobject]@{Name='ChatGPT.exe';ProcessId=987654;CommandLine='app'} }
        Test-CodexOfflineWriters 'C:\source' | Should -BeTrue
        Mock Get-CimInstance { [pscustomobject]@{Name='python.exe';ProcessId=987654;CommandLine='python C:\source\task.py'} }
        Test-CodexOfflineWriters 'C:\source' | Should -BeTrue
    }
    It 'fails closed on an unavailable census' {
        Mock Get-CimInstance { throw 'census denied' }
        { Test-CodexOfflineWriters 'C:\source' } | Should -Throw
    }
    It 'allows unrelated processes' {
        Mock Get-CimInstance { [pscustomobject]@{Name='editor.exe';ProcessId=987654;CommandLine='unrelated'} }
        Test-CodexOfflineWriters 'C:\source' | Should -BeFalse
    }
    It 'waits for normal Quit' {
        $script:checks = 0
        Mock Test-CodexOfflineWriters { $script:checks++; return $script:checks -lt 2 }
        Mock Start-Sleep {}
        Wait-CodexOfflineQuit @{sourceHome='source';waitTimeoutSeconds=10;pollSeconds=1}
        Should -Invoke Start-Sleep -Exactly 1
        Should -Invoke Test-CodexOfflineWriters -Exactly 2
    }
    It 'times out without stopping processes' {
        Mock Test-CodexOfflineWriters { $true }
        Mock Start-Sleep {}
        { Wait-CodexOfflineQuit @{sourceHome='source';waitTimeoutSeconds=0;pollSeconds=1} } | Should -Throw
        Should -Invoke Start-Sleep -Exactly 0
    }
}
Describe 'Reviewed offline requests' -Skip:(-not $IsWindows) {
    BeforeEach {
        $script:caseRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $script:adapterRoot = Join-Path $script:caseRoot 'adapter'
        $source = Join-Path $script:caseRoot 'source'
        $null = New-Item -ItemType Directory -Path $script:adapterRoot,$source
        $hashes = @{}
        foreach ($relative in $script:CodexOfflineRequiredFiles) {
            $file = Join-Path $script:adapterRoot $relative
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file))
            [IO.File]::WriteAllText($file, 'synthetic pinned file')
            $hashes[$relative] = (Get-FileHash -LiteralPath $file).Hash
        }
        $python = Join-Path $script:caseRoot 'python.exe'
        [IO.File]::WriteAllText($python,'synthetic executable; never launched')
        $script:request = @{schemaVersion=1;sourceHome=$source;targetHome=(Join-Path $script:caseRoot 'target');
            adapterDirectory=$script:adapterRoot;adapterHashes=$hashes;pythonPath=$python;pythonSha256=(Get-FileHash -LiteralPath $python).Hash;
            receiptDirectory=(Join-Path $script:caseRoot 'receipts');waitTimeoutSeconds=30;pollSeconds=1}
        $script:requestFile = Join-Path $script:caseRoot 'request.json'
        $script:originalAdapterRoot = $script:CodexOfflineScriptDirectory
        $script:CodexOfflineScriptDirectory = $script:adapterRoot
    }
    AfterEach { $script:CodexOfflineScriptDirectory = $script:originalAdapterRoot }
    It 'validates without creating state' {
        $script:request | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:requestFile
        $result = Get-CodexOfflineRequest $script:requestFile (Get-FileHash -LiteralPath $script:requestFile).Hash
        $result.sourceHome | Should -Be $script:request.sourceHome
        Test-Path -LiteralPath $script:request.targetHome | Should -BeFalse
        Test-Path -LiteralPath $script:request.receiptDirectory | Should -BeFalse
    }
    It 'hashes the same request bytes it parses without reopening through Get-FileHash' {
        $script:request | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:requestFile
        $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($script:requestFile)))
        Mock Get-FileHash { throw 'Request must not be reopened for hashing.' } -ParameterFilter { $LiteralPath -eq $script:requestFile }
        $result = Get-CodexOfflineRequest $script:requestFile $digest
        $result.sourceHome | Should -Be $script:request.sourceHome
        Should -Invoke Get-FileHash -Exactly 0 -ParameterFilter { $LiteralPath -eq $script:requestFile }
    }
    It 'refuses a changed request' {
        $script:request | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:requestFile
        { Get-CodexOfflineRequest $script:requestFile ('0' * 64) } | Should -Throw
    }
    It 'refuses extra fields' {
        $script:request.activate = $true
        $script:request | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:requestFile
        { Get-CodexOfflineRequest $script:requestFile (Get-FileHash -LiteralPath $script:requestFile).Hash } | Should -Throw
    }
    It 'refuses overlapping receipts' {
        $script:request.receiptDirectory = Join-Path $script:request.sourceHome 'receipts'
        $script:request | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:requestFile
        { Get-CodexOfflineRequest $script:requestFile (Get-FileHash -LiteralPath $script:requestFile).Hash } | Should -Throw
    }
    It 'refuses changed source and interpreter pins' {
        $script:request | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:requestFile
        $adapter = Join-Path $script:adapterRoot 'codex-home-migrate.py'
        [IO.File]::WriteAllText($adapter,'changed')
        { Get-CodexOfflineRequest $script:requestFile (Get-FileHash -LiteralPath $script:requestFile).Hash } | Should -Throw
        $script:request.adapterHashes['codex-home-migrate.py'] = (Get-FileHash -LiteralPath $adapter).Hash
        $script:request | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:requestFile
        [IO.File]::WriteAllText($script:request.pythonPath,'changed interpreter')
        { Get-CodexOfflineRequest $script:requestFile (Get-FileHash -LiteralPath $script:requestFile).Hash } | Should -Throw
    }
}
Describe 'Copy workflow' {
    BeforeEach {
        $script:flowRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $adapter = Join-Path $script:flowRoot 'adapter'
        $null = [IO.Directory]::CreateDirectory((Join-Path $adapter 'lib'))
        [IO.File]::WriteAllText((Join-Path $adapter 'lib/WindowsArtifactDeployment.ps1'),
            'function Set-RevkitPrivateDirectory { param([string]$Path) $null = [IO.Directory]::CreateDirectory($Path) }')
        $script:flowRequest = @{sourceHome=(Join-Path $script:flowRoot 'source');targetHome=(Join-Path $script:flowRoot 'target');
            adapterDirectory=$adapter;receiptDirectory=(Join-Path $script:flowRoot 'receipts');adapterHashes=@{};pythonSha256=('a' * 64)}
        Mock Get-CodexOfflineRequest { $script:flowRequest }
        Mock Wait-CodexOfflineQuit {}
        $script:actions = [Collections.Generic.List[string]]::new()
        Mock Invoke-CodexOfflineAdapter {
            param($Request,$Action)
            $script:actions.Add($Action)
            return @{pending=@(@{field='plugin';kind='requires-supported-regeneration'})}
        }
    }
    It 'orders all phases and leaves activation pending' {
        $result = Invoke-CodexOfflineCopy 'request.json' ('a' * 64)
        ($script:actions -join ',') | Should -Be 'plan,prepare,verify'
        $result.status | Should -Be 'copy-verified-awaiting-operator-review'
        $result.activationPerformed | Should -BeFalse
        $result.environmentChanged | Should -BeFalse
        $result.processesStopped | Should -BeFalse
        $result.originalsRetained | Should -BeTrue
        $result.pending[0].field | Should -Be 'plugin'
        foreach ($name in @('plan.json','prepare.json','verify.json','executor.json')) {
            Test-Path -LiteralPath (Join-Path $script:flowRequest.receiptDirectory $name) | Should -BeTrue
        }
    }
    It 'records timeout without invoking adapter' {
        Mock Wait-CodexOfflineQuit { throw 'timed out' }
        { Invoke-CodexOfflineCopy 'request.json' ('a' * 64) } | Should -Throw
        Should -Invoke Invoke-CodexOfflineAdapter -Exactly 0
        $receipt = Get-Content -LiteralPath (Join-Path $script:flowRequest.receiptDirectory 'executor.json') -Raw | ConvertFrom-Json
        $receipt.status | Should -Be 'stopped-for-review'
        $receipt.storageCopyVerified | Should -BeFalse
    }
    It 'stops at refusal and does not verify' {
        Mock Invoke-CodexOfflineAdapter {
            param($Request,$Action)
            $script:actions.Add($Action)
            if ($Action -eq 'prepare') { throw 'unknown schema' }
            return @{pending=@()}
        }
        { Invoke-CodexOfflineCopy 'request.json' ('a' * 64) } | Should -Throw
        ($script:actions -join ',') | Should -Be 'plan,prepare'
        $receipt = Get-Content -LiteralPath (Join-Path $script:flowRequest.receiptDirectory 'executor.json') -Raw | ConvertFrom-Json
        $receipt.status | Should -Be 'stopped-for-review'
        $receipt.activationPerformed | Should -BeFalse
    }
}

Describe 'Real adapter process boundary' -Skip:([string]::IsNullOrWhiteSpace($env:REVKIT_TEST_PYTHON)) {
    BeforeEach {
        $script:processRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $null = [IO.Directory]::CreateDirectory($script:processRoot)
        $script:processRequest = @{pythonPath=$env:REVKIT_TEST_PYTHON;adapterDirectory=$script:processRoot;
            sourceHome=(Join-Path $script:processRoot 'source with spaces');
            targetHome=(Join-Path $script:processRoot 'target with spaces');receiptDirectory=$script:processRoot}
        $fixture = @'
import json
from pathlib import Path
import sys
mode = Path(__file__).with_name("mode.txt").read_text()
action = sys.argv[1]
pending = [{"field": "synthetic-review", "kind": "pending"}] if mode == "pending" else []
result = {"status": {"plan": "planned", "prepare": "prepared", "verify": "verified"}[action],
          "pending": pending, "ready_for_activation": mode == "claims-ready",
          "source_unchanged": True, "storage_copy_verified": True, "arguments": sys.argv[2:]}
if mode == "bad-phase":
    result["status"] = "prepared"
if mode == "malformed":
    print("not JSON")
else:
    print(json.dumps(result))
print("synthetic diagnostic", file=sys.stderr)
sys.exit(1 if mode == "refusal" else 2 if pending else 0)
'@
        [IO.File]::WriteAllText((Join-Path $script:processRoot 'codex-home-migrate.py'), $fixture)
        [IO.File]::WriteAllText((Join-Path $script:processRoot 'mode.txt'), 'pending')
        Mock Assert-CodexOfflinePinnedFiles {}
    }
    It 'accepts exit-two pending work while preserving argument boundaries and logs' {
        $result = Invoke-CodexOfflineAdapter $script:processRequest plan
        $result.arguments.Count | Should -Be 4
        $result.arguments[1] | Should -Be $script:processRequest.targetHome
        $result.arguments[3] | Should -Be $script:processRequest.sourceHome
        $result.pending[0].field | Should -Be 'synthetic-review'
        Get-Content -LiteralPath (Join-Path $script:processRoot 'plan.stderr.log') -Raw | Should -BeLike '*synthetic diagnostic*'
    }
    It 'passes only the target for verify and accepts an empty pending list' {
        [IO.File]::WriteAllText((Join-Path $script:processRoot 'mode.txt'), 'clean')
        $result = Invoke-CodexOfflineAdapter $script:processRequest verify
        $result.arguments.Count | Should -Be 2
        $result.arguments[0] | Should -Be '--target'
        $result.pending.Count | Should -Be 0
    }
    It 'refuses failed exits, wrong phases, activation claims and malformed output' {
        foreach ($mode in @('refusal','bad-phase','claims-ready','malformed')) {
            [IO.File]::WriteAllText((Join-Path $script:processRoot 'mode.txt'), $mode)
            { Invoke-CodexOfflineAdapter $script:processRequest plan } | Should -Throw
        }
    }
}

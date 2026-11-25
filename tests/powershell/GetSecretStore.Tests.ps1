BeforeAll {
    . (Join-Path $PSScriptRoot '..' '..' 'powershell' 'Modules' 'RevealUI.RevStation' 'Private' 'ConvertFrom-RevvaultJson.ps1')
    . (Join-Path $PSScriptRoot '..' '..' 'powershell' 'Modules' 'RevealUI.RevStation' 'Public' 'Get-Secret.ps1')
    function wsl.exe { throw 'Only mocked native vault commands are permitted in this suite.' }
    function Find-RevealUIDrive { throw 'Code drives must never select vault storage.' }
}
Describe 'Native vault storage is independent from Windows code releases' {
    BeforeEach {
        $script:Previous = @{}
        foreach ($name in 'REVEALUI_ROOT','RV_STORE','RV_PATH','WSLENV') { $script:Previous[$name] = [Environment]::GetEnvironmentVariable($name) }
        $env:REVEALUI_ROOT = 'Z:\synthetic\code-release'
        $env:RV_STORE = 'synthetic-owner-store'
        $env:RV_PATH = 'synthetic-before'
        $env:WSLENV = 'synthetic-before-env'
        Mock Find-RevealUIDrive { throw 'Code drives do not select credential storage.' }
        Mock wsl.exe {
            if ($args[-1] -cne 'revvault get --json "$RV_PATH"') { throw 'Unexpected native command' }
            if ($env:RV_PATH -cne 'synthetic/opaque-key') { throw 'Entry name was not projected' }
            if ($env:RV_STORE -cne 'synthetic-owner-store' -or $env:WSLENV.Contains('RV_STORE')) { throw 'Store override changed or forwarded' }
            $global:LASTEXITCODE = 0
            '{"value":"synthetic\nmultiline"}'
        }
    }
    AfterEach {
        foreach ($name in $script:Previous.Keys) { [Environment]::SetEnvironmentVariable($name, $script:Previous[$name], 'Process') }
    }
    It 'uses the existing native client configuration and restores owner environment' {
        Get-Secret -Path 'synthetic/opaque-key' -AsPlainText | Should -BeExactly "synthetic`nmultiline"
        $env:RV_PATH | Should -BeExactly 'synthetic-before'
        $env:WSLENV | Should -BeExactly 'synthetic-before-env'
        $env:RV_STORE | Should -BeExactly 'synthetic-owner-store'
        Should -Invoke wsl.exe -Times 1 -Exactly
        Should -Invoke Find-RevealUIDrive -Times 0 -Exactly
    }
    It 'retains SecureString output and the explicit output-mode guard' {
        Get-Secret -Path 'synthetic/opaque-key' -AsSecureString | Should -BeOfType ([Security.SecureString])
        { Get-Secret -Path 'synthetic/opaque-key' } | Should -Throw
        Should -Invoke wsl.exe -Times 1 -Exactly
    }
}

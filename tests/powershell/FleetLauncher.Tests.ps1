BeforeAll {
    . (Join-Path $PSScriptRoot '..' '..' 'powershell' 'Modules' 'RevealUI.RevStation' 'Public' 'revealfleet.ps1')
    function wsl.exe { throw 'Interactive launches must be mocked in tests.' }
}
Describe 'Canonical fleet entry point launches only on owner invocation' {
    BeforeEach { Mock wsl.exe { 'synthetic launch' } }
    It 'does not start a terminal or agent when the function is loaded' {
        Should -Invoke wsl.exe -Times 0 -Exactly
    }
    It 'selects the canonical native fleet root without changing the default distro' {
        revealfleet revkit | Should -BeExactly 'synthetic launch'
        Should -Invoke wsl.exe -Times 1 -Exactly -ParameterFilter {
            $args -contains '~/revealfleet/revkit' -and $args -notcontains '--set-default'
        }
    }
    It 'refuses traversal and multi-segment checkout names before launching' {
        { revealfleet '..' } | Should -Throw
        { revealfleet '../other' } | Should -Throw
        Should -Invoke wsl.exe -Times 0 -Exactly
    }
}

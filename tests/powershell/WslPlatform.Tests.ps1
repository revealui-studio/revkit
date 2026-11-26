#Requires -Version 7.0

BeforeAll { . (Join-Path $PSScriptRoot '..' '..' 'scripts' 'lib' 'WslPlatform.ps1') }
Describe 'Supported WSL platform prerequisite' {
    It 'parses the installed four-part version without a language-specific label' {
        ConvertFrom-WslPlatformVersion -Output @('WSL version: 3.0.5.0', 'Kernel version: 6.18.58.1') | Should -Be ([Version]'3.0.5.0')
        ConvertFrom-WslPlatformVersion -Output @('WSL-Version: 3.0.5.0') | Should -Be ([Version]'3.0.5.0')
    }
    It 'refuses old platforms instead of applying cgroup overrides' {
        { Assert-WslPlatformVersion -Version ([Version]'2.6.0.0') } | Should -Throw
    }
    It 'accepts the approved platform and future maintenance releases' {
        Assert-WslPlatformVersion -Version ([Version]'3.0.5.0') | Should -Be ([Version]'3.0.5.0')
        Assert-WslPlatformVersion -Version ([Version]'3.0.6.0') | Should -Be ([Version]'3.0.6.0')
    }
    It 'fails closed on missing, prerelease, or unexpected output' {
        { ConvertFrom-WslPlatformVersion -Output @('') } | Should -Throw
        { ConvertFrom-WslPlatformVersion -Output @('WSL version: 3.0.5.0-preview') } | Should -Throw
        { ConvertFrom-WslPlatformVersion -Output @('WSL version: unknown') } | Should -Throw
        { ConvertFrom-WslPlatformVersion -Output @('Kernel version: 6.18.58') } | Should -Throw
    }
}

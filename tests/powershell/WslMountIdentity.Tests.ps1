#Requires -Version 7.0

BeforeAll {
    $script:MadeWslPlaceholder = $false
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        function global:wsl.exe { throw 'Native WSL calls must be mocked in this suite.' }
        $script:MadeWslPlaceholder = $true
    }
    $script:ModuleRoot = Join-Path $PSScriptRoot '..' '..' 'powershell' 'Modules' 'RevealUI.RevStation'
    Import-Module (Join-Path $script:ModuleRoot 'RevealUI.RevStation.psd1') -Force 6> $null
}
AfterAll {
    Remove-Module RevealUI.RevStation -Force -ErrorAction SilentlyContinue
    if ($script:MadeWslPlaceholder) { Remove-Item Function:\global:wsl.exe }
}
Describe 'The maintained mount owner requires complete approved identity' {
    BeforeEach {
        Mock Test-IsAdmin { $true } -ModuleName RevealUI.RevStation
        Mock Get-ModuleLogPath { [IO.Path]::GetTempPath() } -ModuleName RevealUI.RevStation
        Mock Write-DevLog { } -ModuleName RevealUI.RevStation
        Mock wsl.exe { throw 'No physical WSL operation is expected.' } -ModuleName RevealUI.RevStation
        Mock Invoke-WslProbe { throw 'No Linux probe is expected.' } -ModuleName RevealUI.RevStation
    }
    It 'refuses an absent Windows identity before any attachment' {
        Mock Get-ApprovedDriveIdentity { throw 'Unconfigured approved identity' } -ModuleName RevealUI.RevStation
        { Mount-WSLDev -IdentityPath synthetic.json -SkipWait -Confirm:$false } | Should -Throw
        Should -Invoke wsl.exe -Times 0 -Exactly -ModuleName RevealUI.RevStation
        Should -Invoke Invoke-WslProbe -Times 0 -Exactly -ModuleName RevealUI.RevStation
    }
    It 'refuses disagreement with root-owned Linux identity before attachment' {
        Mock Get-ApprovedDriveIdentity { [pscustomobject]@{ Identity = @{}; Disk = [pscustomobject]@{ Number = 7; OperationalStatus = 'Online' } } } -ModuleName RevealUI.RevStation
        Mock Assert-SandboxLinuxIdentity { throw 'Windows/Linux identity mismatch' } -ModuleName RevealUI.RevStation
        { Mount-WSLDev -IdentityPath synthetic.json -SkipWait -Confirm:$false } | Should -Throw
        Should -Invoke wsl.exe -Times 0 -Exactly -ModuleName RevealUI.RevStation
    }
    It 'validates an already mounted drive through the privileged identity helper' {
        Mock Get-ApprovedDriveIdentity { [pscustomobject]@{ Identity = @{}; Disk = [pscustomobject]@{ Number = 7; OperationalStatus = 'Online' } } } -ModuleName RevealUI.RevStation
        Mock Assert-SandboxLinuxIdentity { } -ModuleName RevealUI.RevStation
        Mock Invoke-WslProbe { [pscustomobject]@{ Output = @('YOURMOUNT_YES'); ExitCode = 0; TimedOut = $false } } -ModuleName RevealUI.RevStation
        Mock wsl.exe { if (@($args) -contains '--mount') { throw 'No physical attachment expected' }; $global:LASTEXITCODE = 0 } -ModuleName RevealUI.RevStation
        Mount-WSLDev -IdentityPath synthetic.json -SkipWait -Confirm:$false
        Should -Invoke wsl.exe -Times 1 -Exactly -ModuleName RevealUI.RevStation
    }
}

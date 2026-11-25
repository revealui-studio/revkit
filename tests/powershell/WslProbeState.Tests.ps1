#Requires -Version 7.0

BeforeAll { . (Join-Path $PSScriptRoot '..' '..' 'powershell' 'Modules' 'RevealUI.RevStation' 'Private' 'ConvertFrom-WslProbeState.ps1') }
Describe 'WSL success markers are exact parsed states' {
    It 'distinguishes MOUNTED from NOT_MOUNTED' {
        ConvertFrom-WslProbeState -Output @('NOT_MOUNTED') -AllowedStates @('MOUNTED', 'NOT_MOUNTED') | Should -BeExactly 'NOT_MOUNTED'
        ConvertFrom-WslProbeState -Output @('MOUNTED') -AllowedStates @('MOUNTED', 'NOT_MOUNTED') | Should -BeExactly 'MOUNTED'
    }
    It 'distinguishes FOUND from NOTFOUND in the maintained block readiness path' {
        ConvertFrom-WslProbeState -Output @('NOTFOUND') -AllowedStates @('FOUND', 'NOTFOUND') | Should -BeExactly 'NOTFOUND'
    }
    It 'rejects error exit codes and noisy mixed output' {
        ConvertFrom-WslProbeState -Output @('FOUND') -AllowedStates @('FOUND') -ExitCode 1 | Should -BeNullOrEmpty
        ConvertFrom-WslProbeState -Output @('error FOUND') -AllowedStates @('FOUND') | Should -BeNullOrEmpty
        ConvertFrom-WslProbeState -Output @('FOUND', 'NOTFOUND') -AllowedStates @('FOUND', 'NOTFOUND') | Should -BeNullOrEmpty
    }
}

Describe 'Read-only WSL probes have a process deadline' {
    BeforeAll { . (Join-Path $PSScriptRoot '..' '..' 'powershell' 'Modules' 'RevealUI.RevStation' 'Private' 'Invoke-WslProbe.ps1') }
    It 'captures a completed process as an exact state' {
        $result = Invoke-WslProbe -Executable (Get-Process -Id $PID).Path -Arguments @('-NoProfile', '-NonInteractive', '-Command', '[Console]::WriteLine("READY")') -TimeoutSeconds 10
        ConvertFrom-WslProbeState -Output $result.Output -AllowedStates @('READY') -ExitCode $result.ExitCode | Should -BeExactly 'READY'
        $result.TimedOut | Should -BeFalse
    }
    It 'terminates only its own timed-out probe and reports no success' {
        $result = Invoke-WslProbe -Executable (Get-Process -Id $PID).Path -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 10') -TimeoutSeconds 0.1
        $result.TimedOut | Should -BeTrue
        $result.ExitCode | Should -Be 124
        $result.Output | Should -BeNullOrEmpty
    }
}

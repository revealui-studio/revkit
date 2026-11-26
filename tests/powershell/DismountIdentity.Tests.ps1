#Requires -Version 7.0

BeforeAll {
    $root = Join-Path $PSScriptRoot '..' '..' 'powershell' 'Modules' 'RevealUI.RevStation'
    Import-Module (Join-Path $root 'RevealUI.RevStation.psd1') -Force 6> $null
}
AfterAll { Remove-Module RevealUI.RevStation -Force -ErrorAction SilentlyContinue }
Describe 'Maintained dismount preserves the intended scoped safe-eject behavior' {
    BeforeEach {
        Mock Get-ApprovedDriveIdentity { [pscustomobject]@{ Identity = @{ mountPoint = '/mnt/synthetic'; serial = 'disk-1'; model = 'synthetic'; diskBytes = 10; partitionBytes = 5; partitionUuid = 'part'; filesystemUuid = 'fs' }; Disk = [pscustomobject]@{ Number = 7 } } } -ModuleName RevealUI.RevStation
        Mock Test-IsAdmin { $true } -ModuleName RevealUI.RevStation
        Mock Invoke-WslProbe { throw 'No disk operation expected.' } -ModuleName RevealUI.RevStation
    }
    It 'does not sync/unmount/detach under WhatIf' {
        Dismount-WSLDev -IdentityPath synthetic.json -LinuxIdentityPath /etc/synthetic.json -WhatIf
        Should -Invoke Invoke-WslProbe -Times 0 -Exactly -ModuleName RevealUI.RevStation
    }
    It 'rejects an unrelated disk number or mountpoint before touching WSL' {
        { Dismount-WSLDev -IdentityPath synthetic.json -LinuxIdentityPath /etc/synthetic.json -DiskNumber 8 -Confirm:$false } | Should -Throw
        { Dismount-WSLDev -IdentityPath synthetic.json -LinuxIdentityPath /etc/synthetic.json -MountPath /mnt/other -Confirm:$false } | Should -Throw
        Should -Invoke Invoke-WslProbe -Times 0 -Exactly -ModuleName RevealUI.RevStation
    }
    It 'refuses active consumers instead of globally stopping unrelated services' {
        Mock Invoke-WslProbe {
            param($Arguments)
            if ($Arguments -contains '/usr/bin/fuser') { return [pscustomobject]@{ ExitCode = 0; Output = @('synthetic active pid') } }
            [pscustomobject]@{ ExitCode = 0; Output = @('{"identityVerified":true,"mountState":"MOUNTED","serial":"disk-1","model":"synthetic","diskBytes":10,"partitionBytes":5,"partitionUuid":"part","filesystemUuid":"fs","mountPoint":"/mnt/synthetic"}') }
        } -ModuleName RevealUI.RevStation
        { Dismount-WSLDev -IdentityPath synthetic.json -LinuxIdentityPath /etc/synthetic.json -Confirm:$false } | Should -Throw
        Should -Invoke Invoke-WslProbe -Times 2 -Exactly -ModuleName RevealUI.RevStation
    }
}

#Requires -Version 7.0

BeforeAll { . (Join-Path $PSScriptRoot '..' '..' 'scripts' 'lib' 'WslDiskIdentity.ps1') }
Describe 'Physical disk identity is exact before any Linux probe' {
    BeforeEach {
        $script:Identity = @{ schemaVersion = 1; serial = 'serial-1'; model = 'synthetic USB'; diskBytes = 2097152L; partitionBytes = 524288L; partitionStartSectors = 2048L; partitionSectors = 1024L; partitionUuid = '00000000-0000-0000-0000-000000000001' }
        $script:Disk = [pscustomobject]@{ Number = 7; SerialNumber = 'serial-1'; FriendlyName = 'synthetic USB'; Size = 2097152L; IsBoot = $false; IsSystem = $false; BusType = 'USB'; PartitionStyle = 'GPT' }
        $script:Partition = [pscustomobject]@{ DiskNumber = 7; Size = 524288L; Offset = 1048576L; Guid = '00000000-0000-0000-0000-000000000001'; GptType = '0fc63daf-8483-4772-8e79-3d69d8477de4'; DriveLetter = '' }
    }
    It 'rediscovers the approved hardware without pinning a disk number' {
        (Assert-WslDiskHardwareIdentity -Identity $script:Identity -Disks @($script:Disk) -Partitions @($script:Partition)).Number | Should -Be 7
    }
    It 'accepts only canonical absent letters including the actual Windows Char NUL' {
        foreach($value in @($null,'',[char]0)) {
            $script:Partition.DriveLetter=$value
            (Assert-WslDiskHardwareIdentity -Identity $script:Identity -Disks @($script:Disk) -Partitions @($script:Partition)).Number|Should -Be 7
        }
    }
    It 'rejects assigned letters and malformed values without coercion' {
        foreach($value in @('D',[char]'E',' ',"`0",0,$false,@(''),[pscustomobject]@{Letter=''})) {
            $script:Partition.DriveLetter=$value
            {Assert-WslDiskHardwareIdentity -Identity $script:Identity -Disks @($script:Disk) -Partitions @($script:Partition)}|Should -Throw
        }
    }
    It 'rejects serial substrings, wrong geometry and duplicate hardware matches' {
        $script:Disk.SerialNumber = 'other-serial-1'
        { Assert-WslDiskHardwareIdentity -Identity $script:Identity -Disks @($script:Disk) -Partitions @($script:Partition) } | Should -Throw
        $script:Disk.SerialNumber = 'serial-1'
        { Assert-WslDiskHardwareIdentity -Identity $script:Identity -Disks @($script:Disk, $script:Disk) -Partitions @($script:Partition) } | Should -Throw
        $script:Partition.Offset = 2048L
        { Assert-WslDiskHardwareIdentity -Identity $script:Identity -Disks @($script:Disk) -Partitions @($script:Partition) } | Should -Throw
    }
    It 'refuses a system disk or a different partition UUID' {
        $script:Disk.IsSystem = $true
        { Assert-WslDiskHardwareIdentity -Identity $script:Identity -Disks @($script:Disk) -Partitions @($script:Partition) } | Should -Throw
        $script:Disk.IsSystem = $false
        $script:Partition.Guid = '00000000-0000-0000-0000-000000000099'
        { Assert-WslDiskHardwareIdentity -Identity $script:Identity -Disks @($script:Disk) -Partitions @($script:Partition) } | Should -Throw
    }
}

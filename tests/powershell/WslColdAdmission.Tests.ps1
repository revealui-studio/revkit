#Requires -Version 7.0
BeforeAll {if(-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)){function Get-Disk {throw 'No native Windows storage provider'};function Get-Partition {throw 'No native Windows storage provider'}};. (Join-Path $PSScriptRoot '..' '..' 'scripts' 'lib' 'WslBackup.ps1');Initialize-WslColdWorkerProtocol}
Describe 'Operational controller admission precedes side effects' {
    It 'refuses invalid admission before registry, source or worker operations' {
        Mock Read-WslColdAdmission {throw 'signature refused'}
        Mock Assert-WslColdBindings {throw 'must not run'}
        Mock Invoke-WslColdFixedProcess {throw 'must not launch'}
        {Invoke-WslColdContainerOperation -Phase backup -PolicyPath 'not-opened' -ReviewedPolicySha256 ('a'*64) -AllowedSignersPath 'not-opened' -ReviewedSignersSha256 ('b'*64) -Execute}|Should -Throw -ExpectedMessage '*signature refused*'
        Should -Invoke Assert-WslColdBindings -Times 0
        Should -Invoke Invoke-WslColdFixedProcess -Times 0
    }
    It 'requires private caller capability before any source or worker access' {
        Mock Read-WslColdAdmission {return @{Value=@{operation='backup';transactionId='11111111-1111-4111-8111-111111111111'};Sha256=('a'*64)}}
        Mock Assert-WslColdBindings {throw 'must not observe source'}
        Mock Invoke-WslColdFixedProcess {throw 'must not launch'}
        {Invoke-WslColdContainerOperation -Phase backup -PolicyPath 'not-opened' -ReviewedPolicySha256 ('a'*64) -AllowedSignersPath 'not-opened' -ReviewedSignersSha256 ('b'*64) -Execute}|Should -Throw -ExpectedMessage '*Private caller*'
        Should -Invoke Assert-WslColdBindings -Times 0
        Should -Invoke Invoke-WslColdFixedProcess -Times 0
    }
    It 'has no native-host fallback that can open a real Windows source' -Skip:$IsWindows {
        {Read-WslColdAdmission -PolicyPath 'not-opened' -ReviewedPolicySha256 ('a'*64) -AllowedSignersPath 'not-opened' -ReviewedSignersSha256 ('b'*64)}|Should -Throw -ExpectedMessage '*actual Windows*'
    }
    It 'uses a selected root worker and an exact bounded noninteractive transient job' {
        $p=@{worker=@{distro='Synthetic-worker';interpreter='/usr/bin/python3.14'};budget=@{timeoutSeconds=120};transactionId='11111111-1111-4111-8111-111111111111'}
        $args=Get-WslColdWorkerArguments $p serve
        $args|Should -Contain '--user';$args|Should -Contain 'root'
        $args|Should -Contain '/usr/bin/systemd-run';$args|Should -Contain '--pipe'
        $args|Should -Contain '--property=KillMode=control-group'
        $args|Should -Contain '--property=RuntimeMaxSec=150s'
        $args|Should -Not -Contain 'bash';$args|Should -Not -Contain '--pty'
    }
    It 'retains custody when actual kernel reconciliation is unavailable' {
        $script:WslColdRetained=@{'11111111-1111-4111-8111-111111111111'=@{Policy=@{};Binding=('a'*64)}}
        Mock Invoke-WslColdFixedProcess {throw 'unreachable'}
        (Complete-WslColdCustody '11111111-1111-4111-8111-111111111111').CustodyRetained|Should -BeTrue
        $script:WslColdRetained.Count|Should -Be 1
        $script:WslColdRetained=@{}
    }
    It 'runs bounded control bytes without text pipelines and rejects output floods/timeouts' {
        $hostPath=(Get-Process -Id $PID).Path
        function ControlArgs([string]$Code){@('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code)))}
        $bytes=[Text.Encoding]::UTF8.GetBytes('public control probe')
        (Invoke-WslColdFixedProcess -FileName $hostPath -Arguments (ControlArgs '[Console]::OpenStandardInput().CopyTo([Console]::OpenStandardOutput())') -InputBytes $bytes)|Should -Be 'public control probe'
        foreach($case in @(@{Code='[Console]::Write([string]::new([char]65,131072));Start-Sleep 30';Timeout=5000},@{Code='Start-Sleep 30';Timeout=100})) {
            $failure=$null
            try {Invoke-WslColdFixedProcess -FileName $hostPath -Arguments (ControlArgs $case.Code) -TimeoutMilliseconds $case.Timeout} catch {$failure=$_.Exception.GetBaseException().Message}
            $failure|Should -Be 'Control command refused'
        }
    }
    It 'zeros private caller input when its owned memory stream closes' {
        $secret=ConvertTo-SecureString 'synthetic unit input' -AsPlainText -Force
        $input=[Revealfleet.Backup.ColdCommitGuard]::PrivateInput($secret)
        try {$input.Length|Should -Be 20;$input.CanRead|Should -BeTrue} finally {$input.Dispose();$secret.Dispose()}
        $input.CanRead|Should -BeFalse
        @($input.ToArray()|Where-Object {$_ -ne 0}).Count|Should -Be 0
    }
}

Describe 'Restore source unavailability on actual Windows only' {
    It 'excludes other readers as well as writers while the restore custody handle lives' -Skip:(-not $IsWindows) {
        $path=Join-Path $TestDrive 'synthetic-outage-source.bin';[IO.File]::WriteAllBytes($path,[byte[]]::new(32))
        $identity=[Revealfleet.Backup.ColdSourceLease]::InspectIdentityForReview($path)
        $lease=[Revealfleet.Backup.ColdSourceLease]::new($path,$identity,$true)
        try {
            {[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)}|Should -Throw
            $lease.ValidateUnchanged()
        } finally {$lease.Dispose()}
        $reader=[IO.File]::OpenRead($path)
        try {$reader.ReadByte()|Should -Be 0} finally {$reader.Dispose()}
    }
}

Describe 'Private data custody differs from public immutable code' {
    It 'rejects other-user read on private data while allowing public code read' {
        $entry=[pscustomobject]@{Sid='S-1-1-0';Rights=[Security.AccessControl.FileSystemRights]::ReadData;Allow=$true}
        {Assert-WslColdAclGrants -Entries @($entry) -Allowed @('S-1-5-18') -Leaf -PrivateData}|Should -Throw
        {Assert-WslColdAclGrants -Entries @($entry) -Allowed @('S-1-5-18') -Leaf}|Should -Not -Throw
    }
    It 'permits the explicit private owner but rejects mutation outside that principal set' {
        $entry=[pscustomobject]@{Sid='owner';Rights=[Security.AccessControl.FileSystemRights]::FullControl;Allow=$true}
        {Assert-WslColdAclGrants -Entries @($entry) -Allowed @('owner','S-1-5-18') -Leaf -PrivateData}|Should -Not -Throw
        {Assert-WslColdAclGrants -Entries @($entry) -Allowed @('S-1-5-18') -Leaf -PrivateData}|Should -Throw
    }
}

Describe 'Standard creator inheritance does not authorize another data reader' {
    It 'recognizes inheritance-only creator ownership but still rejects public child grants' {
        $creator=[pscustomobject]@{Sid='S-1-3-0';Rights=[Security.AccessControl.FileSystemRights]::FullControl;Allow=$true;InheritOnly=$true}
        {Assert-WslColdAclGrants -Entries @($creator) -Allowed @('owner') -Leaf -PrivateData}|Should -Not -Throw
        $public=[pscustomobject]@{Sid='S-1-1-0';Rights=[Security.AccessControl.FileSystemRights]::ReadData;Allow=$true;InheritOnly=$true}
        {Assert-WslColdAclGrants -Entries @($creator,$public) -Allowed @('owner') -Leaf -PrivateData}|Should -Throw
    }
}

Describe 'Exact filesystem capacity domains on MBR and GPT' {
    BeforeEach {
        $script:disk=[pscustomobject]@{PartitionStyle='MBR';SerialNumber='synthetic serial  ';FriendlyName='synthetic USB';Size=2000000000L;Signature=389383;LogicalSectorSize=512;PhysicalSectorSize=4096}
        $script:part=[pscustomobject]@{Offset=1048576L;Size=1900000000L;MbrType=7}
        $script:vol=[pscustomobject]@{UniqueId='\\?\Volume{0005f107-0000-0000-0000-100000000000}\';AllocationUnitSize=4096;FileSystem='NTFS'}
    }
    It 'accepts a fully observed MBR disk without a GPT GUID and shares the volume domain' {
        $expected=Get-WslColdVolumeIdentity $disk $part $vol
        $expected.diskId|Should -Be 389383
        $expected.Contains('partitionUuid')|Should -BeFalse
        (Assert-WslColdVolumeObservation $disk $part $vol $expected)|Should -Be '0005f107-0000-0000-0000-100000000000'
        $vol|Add-Member DriveLetter 'Z'
        (Assert-WslColdVolumeObservation $disk $part $vol $expected)|Should -Be $expected.volumeUuid
    }
    It 'rejects every changed hardware/geometry/filesystem field rather than accepting a capacity alias' {
        $expected=Get-WslColdVolumeIdentity $disk $part $vol
        foreach($field in @('serial','model','diskBytes','diskId','logicalSectorBytes','physicalSectorBytes','partitionOffsetBytes','partitionBytes','partitionType','volumeUuid','allocationUnitBytes')) {
            $changed=[ordered]@{};foreach($key in $expected.Keys){$changed[$key]=$expected[$key]}
            $changed[$field]=if($changed[$field] -is [string]){'different'}else{$changed[$field]+1}
            {Assert-WslColdVolumeObservation $disk $part $vol $changed}|Should -Throw
        }
        $disk.Signature=$null
        {Get-WslColdVolumeIdentity $disk $part $vol}|Should -Throw
    }
    It 'requires exact nonempty GPT disk, partition and type identities too' {
        $disk.PartitionStyle='GPT';$disk|Add-Member Guid '11111111-1111-4111-8111-111111111111'
        $part|Add-Member Guid '22222222-2222-4222-8222-222222222222';$part|Add-Member GptType 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7'
        $expected=Get-WslColdVolumeIdentity $disk $part $vol
        (Assert-WslColdVolumeObservation $disk $part $vol $expected)|Should -Be $expected.volumeUuid
        $part.Guid=[Guid]::Empty
        {Assert-WslColdVolumeObservation $disk $part $vol $expected}|Should -Throw
    }
    It 'observes Windows USB hardware independently of Linux serial echo' {
        Mock Get-Disk { @([pscustomobject]@{Number=7;SerialNumber='synthetic';FriendlyName='synthetic USB';Size=4096;BusType='USB';PartitionStyle='GPT';IsBoot=$false;IsSystem=$false}) }
        Mock Get-Partition { @([pscustomobject]@{DiskNumber=7;Offset=512;Size=2048;Guid='66666666-6666-4666-8666-666666666666';GptType='0fc63daf-8483-4772-8e79-3d69d8477de4';DriveLetter=[char]0}) }
        $repository=@{deviceSerial='synthetic';deviceModel='synthetic USB';deviceBytes=4096;partitionOffsetBytes=512;partitionBytes=2048;partitionUuid='66666666-6666-4666-8666-666666666666'}
        {Assert-WslColdRepositoryHardware $repository}|Should -Not -Throw
        $repository.deviceSerial='changed Windows device'
        {Assert-WslColdRepositoryHardware $repository}|Should -Throw
    }
}

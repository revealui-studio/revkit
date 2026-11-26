#Requires -Version 7.0
BeforeAll {. (Join-Path $PSScriptRoot '..' '..' 'scripts' 'lib' 'WslBackup.ps1');Initialize-WslColdWorkerProtocol}
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

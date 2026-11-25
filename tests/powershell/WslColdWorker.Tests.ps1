#Requires -Version 7.0
BeforeAll {
    . (Join-Path $PSScriptRoot '..' '..' 'scripts' 'lib' 'WslBackup.ps1')
    Initialize-WslColdWorkerProtocol
    function New-WireRequest {
        [Text.Encoding]::UTF8.GetBytes((@{protocol='revkit-cold-worker-v1';profile='cold-vhd-container-v1';
            transactionId='11111111-1111-4111-8111-111111111111';archiveId='11111111-1111-4111-8111-111111111111';
            phase='backup';bindingSha256=('a'*64);bytes=1;sha256=('b'*64)}|ConvertTo-Json -Compress))
    }
}
Describe 'Cold worker fixed protocol and closed launch admission' {
    It 'encodes bounded binary frames without text conversion' {
        $data=[byte[]]::new(65536);[Security.Cryptography.RandomNumberGenerator]::Fill($data)
        $frame=[Revealfleet.Backup.ColdProtocol]::Encode([byte][char]'D',$data)
        $stream=[IO.MemoryStream]::new($frame,$false)
        try {
            $read=[Revealfleet.Backup.ColdProtocol]::ReadAsync($stream,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
            $read.Item1|Should -Be ([byte][char]'D')
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($read.Item2))|Should -Be ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($data)))
        } finally {$stream.Dispose()}
    }
    It 'rejects excess and truncated framing' {
        {[Revealfleet.Backup.ColdProtocol]::Encode([byte][char]'D',[byte[]]::new(65537))}|Should -Throw
        foreach($bytes in @([byte[]]@(68,2,0,0,0,1),[byte[]]@(68,1,0))) {
            $stream=[IO.MemoryStream]::new($bytes,$false)
            try {{[Revealfleet.Backup.ColdProtocol]::ReadAsync($stream,[Threading.CancellationToken]::None).GetAwaiter().GetResult()}|Should -Throw}
            finally {$stream.Dispose()}
        }
    }
    It 'rejects duplicate or substituted request identities and profiles' {
        [Revealfleet.Backup.ColdProtocol]::ValidateRequest((New-WireRequest))
        $text=[Text.Encoding]::UTF8.GetString((New-WireRequest))
        foreach($changed in @($text.Replace('cold-vhd-container-v1','fixed64k-input-holes-v1'),$text.Insert(1,'"bytes":1,'))) {
            {[Revealfleet.Backup.ColdProtocol]::ValidateRequest([Text.Encoding]::UTF8.GetBytes($changed))}|Should -Throw
        }
    }
    It 'has a fixed shell-free plan and refuses source or protected worker aliases' {
        $args=@{WorkerDistro='Synthetic-worker';WorkerRegistrationId=[Guid]'22222222-2222-4222-8222-222222222222';
            SourceRegistrationId=[Guid]'11111111-1111-4111-8111-111111111111';ProtectedRegistrationId=[Guid]'33333333-3333-4333-8333-333333333333'}
        $plan=Get-WslColdWorkerLaunchPlan @args
        $plan.CanExecute|Should -BeFalse
        if(-not $IsWindows){{Resolve-WslColdRegistrationBinding -Distro 'Synthetic-worker' -ExpectedRegistrationId $args.WorkerRegistrationId}|Should -Throw}
        $plan.UseShellExecute|Should -BeFalse
        $plan.CreateNoWindow|Should -BeTrue
        $plan.ArgumentList[-1]|Should -Be '--serve'
        $args.WorkerRegistrationId=$args.ProtectedRegistrationId
        {Get-WslColdWorkerLaunchPlan @args}|Should -Throw
        $args.WorkerRegistrationId=$args.SourceRegistrationId
        {Get-WslColdWorkerLaunchPlan @args}|Should -Throw
    }
    It 'refuses an unsupported host or a noncanonical identity before opening a source' {
        $path=if($IsWindows){'not-a-local-source'}else{'X:\not-real\source.vhdx'}
        {[Revealfleet.Backup.ColdSourceLease]::new($path,'not-real')}|Should -Throw
    }
}
Describe 'New maintained lease mechanics on actual Windows synthetic NTFS only' {
    It 'excludes write/delete and validates exact final-handle identity through its lifetime' -Skip:(-not $IsWindows) {
        $path=Join-Path $TestDrive 'synthetic-source.bin'
        [IO.File]::WriteAllBytes($path,[byte[]]::new(8193))
        $id=[Revealfleet.Backup.ColdSourceLease]::InspectIdentityForReview($path)
        $lease=[Revealfleet.Backup.ColdSourceLease]::new($path,$id)
        try {
            $lease.ValidateUnchanged();$lease.Length|Should -Be 8193
            {[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)}|Should -Throw
            {[IO.File]::Delete($path)}|Should -Throw
            $lease.Bytes.ReadByte()|Should -Be 0
            $lease.ValidateUnchanged()
        } finally {$lease.Dispose()}
        $writer=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        try {$writer.CanWrite|Should -BeTrue} finally {$writer.Dispose()}
        {[Revealfleet.Backup.ColdSourceLease]::new($path,'wrong-file-id')}|Should -Throw
        $writer=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        try {
            $failure=$null
            try {[void][Revealfleet.Backup.ColdSourceLease]::new($path,$id)} catch {$failure=$_.Exception.GetBaseException()}
            $failure|Should -Not -BeNullOrEmpty
            ($failure.HResult -band 65535)|Should -Be 32
        } finally {$writer.Dispose()}
        $alias=Join-Path $TestDrive 'hardlink-alias.bin'
        [void](New-Item -ItemType HardLink -Path $alias -Target $path)
        {[Revealfleet.Backup.ColdSourceLease]::new($path,$id)}|Should -Throw
        {[Revealfleet.Backup.ColdSourceLease]::InspectIdentityForReview($alias)}|Should -Throw
    }
}

#Requires -Version 7.0
BeforeAll {
    . (Join-Path $PSScriptRoot '..' '..' 'scripts' 'lib' 'WslBackup.ps1')
    Initialize-WslBackupBinaryTransport
    # Test instrumentation only: a source read fault AFTER actual output is flushed.
    # Caller streams remain independently usable; no sleep/poll drives the fault.
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
namespace Revealfleet.Backup.Tests {
    public class BorrowedStream : Stream {
        protected readonly Stream Inner;
        bool disposed;
        public BorrowedStream(Stream inner) { Inner = inner; }
        protected void Check() { if (disposed) throw new ObjectDisposedException("probe"); }
        public override bool CanRead => !disposed && Inner.CanRead;
        public override bool CanWrite => !disposed && Inner.CanWrite;
        public override bool CanSeek => !disposed && Inner.CanSeek;
        public override long Length { get { Check(); return Inner.Length; } }
        public override long Position { get { Check(); return Inner.Position; } set { Check(); Inner.Position=value; } }
        public override void Flush() { Check(); Inner.Flush(); }
        public override int Read(byte[] b,int o,int n) { Check(); return Inner.Read(b,o,n); }
        public override void Write(byte[] b,int o,int n) { Check(); Inner.Write(b,o,n); }
        public override long Seek(long o,SeekOrigin from) { Check(); return Inner.Seek(o,from); }
        public override void SetLength(long n) { Check(); Inner.SetLength(n); }
        public override ValueTask<int> ReadAsync(Memory<byte> b,CancellationToken ct=default) { Check(); return Inner.ReadAsync(b,ct); }
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> b,CancellationToken ct=default) { Check(); return Inner.WriteAsync(b,ct); }
        protected override void Dispose(bool disposing) { disposed=true; base.Dispose(disposing); } // borrowed Inner stays caller-owned
    }
    public sealed class OutputProbe : BorrowedStream {
        public readonly TaskCompletionSource<bool> Written = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        public OutputProbe(Stream inner) : base(inner) { }
        public override async ValueTask WriteAsync(ReadOnlyMemory<byte> b,CancellationToken ct=default) {
            Check(); await Inner.WriteAsync(b,ct); await Inner.FlushAsync(ct);
            Written.TrySetResult(true);
        }
    }
    public sealed class ReadErrorProbe : BorrowedStream {
        readonly Task outputWritten;
        int reads;
        public bool FaultObserved { get; private set; }
        public ReadErrorProbe(Stream inner,Task written) : base(inner) { outputWritten=written; }
        public override async ValueTask<int> ReadAsync(Memory<byte> b,CancellationToken ct=default) {
            Check();
            if (++reads==2) {
                await outputWritten.WaitAsync(ct);
                FaultObserved=true;
                throw new IOException("synthetic source read error");
            }
            return await Inner.ReadAsync(b.Slice(0,Math.Min(b.Length,4096)),ct);
        }
    }
}
'@
    function New-ContainerRequest {
        @{
            schemaVersion=1;profile='cold-vhd-container-v1'
            source=@{distro='Synthetic-source';registrationId='11111111-1111-4111-8111-111111111111';vhdx='X:\source\ext4.vhdx';physicalDeviceId='source';containerBytes=637998727168L}
            worker=@{distro='Synthetic-worker';registrationId='22222222-2222-4222-8222-222222222222';sourceSha256=('a'*64);toolSha256=('b'*64);capacityDomain='target-volume';availableBytes=717235476229L}
            repository=@{path='Y:\repository';physicalDeviceId='backup';capacityDomain='backup-volume';availableBytes=943636373504L}
            restore=@{path='X:\fresh\restored.vhdx';physicalDeviceId='source';capacityDomain='target-volume';availableBytes=717235476229L;hardwareGuarantee='isolated-restore-test'}
            original=@{path='X:\protected\original.vhdx';physicalDeviceId='source'}
            budget=@{repositoryOverheadBytes=1GB;cacheWorkspaceBytes=1GB;restoreOverheadBytes=1GB;reserveBytes=64GB}
        }
    }
    function Get-RequestPlan($Value) {
        $path=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N')+'.json')
        $Value|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $path
        Get-WslColdContainerReadinessPlan -ConfigurationPath $path -ReviewedConfigurationSha256 (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
    }
    $script:Echo = '[Console]::OpenStandardInput().CopyTo([Console]::OpenStandardOutput())'
    function Invoke-TestBinary([string]$Code,[byte[]]$Data,[byte[]]$Expected,[int]$Timeout=10000,[switch]$Cancel,
        [switch]$ExpectFailure,[IO.Stream]$SourceStream,[IO.Stream]$DestinationStream,[scriptblock]$BeforeCleanup) {
        $psi=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $psi.UseShellExecute=$false
        $psi.CreateNoWindow=$true
        $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
        foreach($arg in @('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code)))) { $psi.ArgumentList.Add($arg) }
        $p=[Diagnostics.Process]::new();$p.StartInfo=$psi
        $incoming=if($null -ne $SourceStream){$SourceStream}else{[IO.MemoryStream]::new($Data,$false)}
        $outgoing=if($null -ne $DestinationStream){$DestinationStream}else{[IO.MemoryStream]::new()}
        $cts=[Threading.CancellationTokenSource]::new()
        if($Cancel){$cts.CancelAfter(100)}
        try {
            [void]$p.Start()
            $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Expected)).ToLowerInvariant()
            $inputHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Data)).ToLowerInvariant()
            $failure=$null;$result=$null
            $transport=[Revealfleet.Backup.BinaryTransport]::TransferAsync($p,$incoming,$outgoing,$Data.LongLength,$inputHash,$Expected.LongLength,$hash,$Timeout,$cts.Token)
            try {$result=$transport.GetAwaiter().GetResult()} catch {$failure=$_.Exception}
            # These assertions run BEFORE defensive finally, with no exit wait/grace/poll here.
            # Negative tests do not wrap this helper in Should -Throw: an assertion failure must fail the test.
            $transport.IsCompleted|Should -BeTrue
            $p.HasExited|Should -BeTrue -Because 'transport must finish its child before returning, not rely on test cleanup'
            $incoming.CanRead|Should -BeTrue
            $outgoing.CanWrite|Should -BeTrue
            if($ExpectFailure){
                $failure|Should -Not -BeNullOrEmpty
                $failure.GetBaseException().Message|Should -Be 'Binary transaction rejected; partial output must be retained'
            }else{if($null -ne $failure){throw $failure}}
            if($null -ne $BeforeCleanup){& $BeforeCleanup $p $incoming $outgoing $failure}
            if(-not $ExpectFailure){[pscustomobject]@{Receipt=$result;Bytes=$outgoing.ToArray()}}
        } finally {
            # Defensive only. Nothing here can satisfy the assertions above.
            if(-not $p.HasExited){$p.Kill($true);[void]$p.WaitForExit(5000)}
            if($null -eq $SourceStream){$incoming.Dispose()}
            if($null -eq $DestinationStream){$outgoing.Dispose()}
            $p.Dispose();$cts.Dispose()
        }
    }

}
Describe 'Opaque container planning is distinct and non-executing' {
    It 'requires explicit request and never treats sampled booleans as lease proof' {
        $p=Get-WslColdContainerReadinessPlan
        $p.CanExecute|Should -BeFalse
        $p.GuestFileCensusRequired|Should -BeFalse
        $p.RequestBindingsValid|Should -BeFalse
    }
    It 'blocks the wrapper before any real source or worker access' {
        $wrapper=Join-Path $PSScriptRoot '..' '..' 'scripts' 'weekly-wsl-backup.ps1'
        {& $wrapper -RecoveryBackend borg-container-readiness -Execute}|Should -Throw -ExpectedMessage '*production execution remains unavailable*'
        {& $wrapper -RecoveryBackend borg-container-readiness -IncrementalObservationPath 'not-a-lease.json'}|Should -Throw -ExpectedMessage '*Sampled operator booleans*'
    }
    It 'aggregates cache and dense restore capacity on the same filesystem without savings' {
        $p=Get-RequestPlan (New-ContainerRequest)
        $p.RequestBindingsValid|Should -BeTrue
        $p.CanExecute|Should -BeFalse
        $p.FullRestoreAccepted|Should -BeFalse
        $p.SharesSourceHardware|Should -BeTrue
        $target=@($p.Capacity|Where-Object Domain -EQ 'target-volume')[0]
        $target.RequiredBytes|Should -Be (637998727168L+64GB+2GB)
        $target.SavingsCreditBytes|Should -Be 0
    }
    It 'refuses an apparent fit once measured overhead consumes the narrow target margin' {
        $c=New-ContainerRequest;$c.budget.cacheWorkspaceBytes=11GB
        $p=Get-RequestPlan $c
        @($p.Capacity|Where-Object { -not $_.ConditionalFit }).Count|Should -Be 1
        $p.CanExecute|Should -BeFalse
    }
    It 'refuses same worker, false third-hardware guarantee and shared repository hardware' {
        $c=New-ContainerRequest;$c.worker.registrationId=$c.source.registrationId
        {Get-RequestPlan $c}|Should -Throw
        $c=New-ContainerRequest;$c.restore.hardwareGuarantee='third-hardware-copy'
        {Get-RequestPlan $c}|Should -Throw
        $c=New-ContainerRequest;$c.repository.physicalDeviceId='source'
        {Get-RequestPlan $c}|Should -Throw
    }
    It 'refuses aliases, missing overhead, profile substitutions and inconsistent free-space domains' {
        $c=New-ContainerRequest;$c.restore.path='x:\SOURCE\ext4.vhdx'
        {Get-RequestPlan $c}|Should -Throw
        $c=New-ContainerRequest;$c.budget.repositoryOverheadBytes=0
        {Get-RequestPlan $c}|Should -Throw
        $c=New-ContainerRequest;$c.profile='fixed64k-input-holes-v1'
        {Get-RequestPlan $c}|Should -Throw
        $c=New-ContainerRequest;$c.worker.availableBytes--
        {Get-RequestPlan $c}|Should -Throw
    }
}
Describe 'Maintained simultaneous binary process mechanics (host-specific receipt required)' {
    BeforeEach {$script:Data=[byte[]]::new(262147);[Security.Cryptography.RandomNumberGenerator]::Fill($script:Data)}
    It 'round trips arbitrary binary including NUL and invalid UTF8 without text conversion' {
        $r=Invoke-TestBinary $script:Echo $script:Data $script:Data
        $r.Receipt.ExitCode|Should -Be 0
        $r.Receipt.InputBytes|Should -Be $script:Data.LongLength
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($r.Bytes))|Should -Be ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($script:Data)))
    }
    It 'drains output while input is blocked by a full pipe' {
        $code='$o=[Console]::OpenStandardOutput();$o.Write([byte[]]::new(1048576));$o.Flush();[Console]::OpenStandardInput().CopyTo($o)'
        $expected=[byte[]]::new(1048576+$script:Data.Length);[Array]::Copy($script:Data,0,$expected,1048576,$script:Data.Length)
        (Invoke-TestBinary $code $script:Data $expected).Receipt.OutputBytes|Should -Be $expected.LongLength
    }
    It 'rejects deliberate truncation even with exit zero and retains caller custody' {
        $code='$i=[Console]::OpenStandardInput();$m=[IO.MemoryStream]::new();$i.CopyTo($m);$d=$m.ToArray();[Console]::OpenStandardOutput().Write($d,0,[int]($d.Length/2))'
        Invoke-TestBinary $code $script:Data $script:Data -ExpectFailure -BeforeCleanup {
            param($child,$inputStream,$outputStream,$failure)
            $outputStream.Length|Should -Be ([int]($script:Data.Length/2))
            $inputStream.Position=0;$inputStream.ReadByte()|Should -Be $script:Data[0]
            $outputStream.Position=0;$outputStream.ReadByte()|Should -Be $script:Data[0]
            $length=$outputStream.Length;$outputStream.Position=$length;$outputStream.WriteByte(90)
            $outputStream.Length|Should -Be ($length+1)
        }
    }
    It 'rejects wrong digest and extra bytes' {
        $wrong=[byte[]]::new($script:Data.Length)
        Invoke-TestBinary $script:Echo $script:Data $wrong -ExpectFailure
        Invoke-TestBinary ($script:Echo+';[Console]::OpenStandardOutput().WriteByte(1)') $script:Data $script:Data -ExpectFailure
    }
    It 'rejects nonzero exit and bounded or overflowing diagnostics' {
        Invoke-TestBinary 'exit 7' $script:Data $script:Data -ExpectFailure
        Invoke-TestBinary ($script:Echo+';[Console]::Error.Write("synthetic diagnostics")') $script:Data $script:Data -ExpectFailure
        Invoke-TestBinary '[Console]::OpenStandardError().Write([byte[]]::new(131072));Start-Sleep 30' $script:Data $script:Data -ExpectFailure
    }
    It 'retains usable caller file streams and flushed partial bytes after a source read error' {
        $sourcePath=Join-Path $TestDrive 'read-error-source.bin'
        $targetPath=Join-Path $TestDrive 'read-error-partial.bin'
        $data=[byte[]]::new(8192);[Security.Cryptography.RandomNumberGenerator]::Fill($data)
        [IO.File]::WriteAllBytes($sourcePath,$data)
        $source=[IO.File]::Open($sourcePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $target=[IO.File]::Open($targetPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
        $observed=[Revealfleet.Backup.Tests.OutputProbe]::new($target)
        $fault=[Revealfleet.Backup.Tests.ReadErrorProbe]::new($source,$observed.Written.Task)
        try {
            Invoke-TestBinary $script:Echo $data $data -SourceStream $fault -DestinationStream $observed -ExpectFailure -BeforeCleanup {
                param($child,$inputStream,$outputStream,$failure)
                $fault.FaultObserved|Should -BeTrue
                $source.SafeFileHandle.IsClosed|Should -BeFalse
                $target.SafeFileHandle.IsClosed|Should -BeFalse
                [IO.File]::Exists($sourcePath)|Should -BeTrue
                [IO.File]::Exists($targetPath)|Should -BeTrue
                $outputStream.Length|Should -Be 4096
                $prefix=[byte[]]::new(4096);[Array]::Copy($data,$prefix,4096)
                # This independent reader must permit the still-owned write handle on Windows.
                $reader=[IO.File]::Open($targetPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
                try {$partialHash=[Security.Cryptography.SHA256]::HashData($reader)} finally {$reader.Dispose()}
                [Convert]::ToHexString($partialHash)|Should -Be ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($prefix)))
                $inputStream.Position=0;$inputStream.ReadByte()|Should -Be $data[0]
                $outputStream.Position=0;$outputStream.ReadByte()|Should -Be $data[0]
                $outputStream.Position=4096;$outputStream.WriteByte(90);$outputStream.Flush()
                (Get-Item -LiteralPath $targetPath).Length|Should -Be 4097
            }
        } finally {$fault.Dispose();$observed.Dispose();$source.Dispose();$target.Dispose()}
    }
    It 'finishes its child before returning timeout and cancellation failures' {
        Invoke-TestBinary 'Start-Sleep 30' ([byte[]]::new(0)) ([byte[]]::new(0)) -Timeout 100 -ExpectFailure
        Invoke-TestBinary 'Start-Sleep 30' ([byte[]]::new(0)) ([byte[]]::new(0)) -Cancel -ExpectFailure
    }
}
Describe 'Actual Windows synthetic writer-delete exclusion (never a real VHD)' -Skip:(-not $IsWindows) {
    It 'refuses an existing writer then excludes write/delete until held read handle release' {
        $path=Join-Path $TestDrive 'synthetic-container.bin'
        [IO.File]::WriteAllBytes($path,[byte[]]::new(8192))
        $writer=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)
        function Assert-SharingViolation([scriptblock]$Action) {
            $observed=$null
            try {& $Action} catch {$observed=$_.Exception}
            $observed|Should -Not -BeNullOrEmpty
            while($null -ne $observed.InnerException){$observed=$observed.InnerException}
            ($observed.HResult -band 65535)|Should -Be 32
        }
        try {Assert-SharingViolation {[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)}}finally{$writer.Dispose()}
        $lease=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            Assert-SharingViolation {[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite)}
            Assert-SharingViolation {[IO.File]::Delete($path)}
            $destination=Join-Path $TestDrive 'synthetic-restored-dense.bin'
            $output=[IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $psi=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
            foreach($a in @('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script:Echo)))){$psi.ArgumentList.Add($a)}
            $child=[Diagnostics.Process]::new();$child.StartInfo=$psi
            try {
                [void]$child.Start()
                $hash=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
                $receipt=[Revealfleet.Backup.BinaryTransport]::TransferAsync($child,$lease,$output,8192,$hash,8192,$hash,10000,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
                $child.HasExited|Should -BeTrue
                $lease.CanRead|Should -BeTrue
                $output.CanWrite|Should -BeTrue
                $output.Flush($true)
                $receipt.OutputBytes|Should -Be 8192
                Assert-SharingViolation {[IO.File]::Delete($path)}
            } finally {
                if(-not $child.HasExited){$child.Kill($true)}
                $child.Dispose();$output.Dispose()
            }
            (Get-FileHash -LiteralPath $destination).Hash|Should -Be (Get-FileHash -LiteralPath $path).Hash
            ((Get-Item -LiteralPath $destination).Attributes -band [IO.FileAttributes]::SparseFile)|Should -Be 0
            $lease.Length|Should -Be 8192
        } finally {$lease.Dispose()}
        $writer=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::ReadWrite);$writer.Dispose()
    }
}

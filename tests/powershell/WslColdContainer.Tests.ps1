#Requires -Version 7.0
BeforeAll {
    . (Join-Path $PSScriptRoot '..' '..' 'scripts' 'lib' 'WslBackup.ps1')
    Initialize-WslBackupBinaryTransport
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
    function Invoke-TestBinary([string]$Code,[byte[]]$Data,[byte[]]$Expected,[int]$Timeout=10000,[switch]$Cancel) {
        $psi=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        $psi.UseShellExecute=$false
        $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
        foreach($arg in @('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code)))) { $psi.ArgumentList.Add($arg) }
        $p=[Diagnostics.Process]::new();$p.StartInfo=$psi
        $incoming=[IO.MemoryStream]::new($Data,$false);$outgoing=[IO.MemoryStream]::new()
        $cts=[Threading.CancellationTokenSource]::new()
        if($Cancel){$cts.CancelAfter(100)}
        try {
            [void]$p.Start()
            $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Expected)).ToLowerInvariant()
            $inputHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Data)).ToLowerInvariant()
            $result=[Revealfleet.Backup.BinaryTransport]::TransferAsync($p,$incoming,$outgoing,$Data.LongLength,$inputHash,$Expected.LongLength,$hash,$Timeout,$cts.Token).GetAwaiter().GetResult()
            [pscustomobject]@{Receipt=$result;Bytes=$outgoing.ToArray()}
        } finally {
            if(-not $p.HasExited){$p.Kill($true);[void]$p.WaitForExit(5000)}
            $incoming.Dispose();$outgoing.Dispose();$p.Dispose();$cts.Dispose()
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
        {Invoke-TestBinary $code $script:Data $script:Data}|Should -Throw
    }
    It 'rejects wrong digest and extra bytes' {
        $wrong=[byte[]]::new($script:Data.Length)
        {Invoke-TestBinary $script:Echo $script:Data $wrong}|Should -Throw
        {Invoke-TestBinary ($script:Echo+';[Console]::OpenStandardOutput().WriteByte(1)') $script:Data $script:Data}|Should -Throw
    }
    It 'rejects nonzero exit and bounded or overflowing diagnostics' {
        {Invoke-TestBinary 'exit 7' $script:Data $script:Data}|Should -Throw
        {Invoke-TestBinary ($script:Echo+';[Console]::Error.Write("synthetic diagnostics")') $script:Data $script:Data}|Should -Throw
        {Invoke-TestBinary '[Console]::OpenStandardError().Write([byte[]]::new(131072));Start-Sleep 30' $script:Data $script:Data}|Should -Throw
    }
    It 'cancels and times out without orphaning its test child' {
        {Invoke-TestBinary 'Start-Sleep 30' ([byte[]]::new(0)) ([byte[]]::new(0)) -Timeout 100}|Should -Throw
        {Invoke-TestBinary 'Start-Sleep 30' ([byte[]]::new(0)) ([byte[]]::new(0)) -Cancel}|Should -Throw
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
            $psi.UseShellExecute=$false;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
            foreach($a in @('-NoProfile','-NonInteractive','-EncodedCommand',[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script:Echo)))){$psi.ArgumentList.Add($a)}
            $child=[Diagnostics.Process]::new();$child.StartInfo=$psi
            try {
                [void]$child.Start()
                $hash=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
                $receipt=[Revealfleet.Backup.BinaryTransport]::TransferAsync($child,$lease,$output,8192,$hash,8192,$hash,10000,[Threading.CancellationToken]::None).GetAwaiter().GetResult()
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

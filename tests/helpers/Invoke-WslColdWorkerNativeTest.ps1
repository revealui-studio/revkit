# Test only: Linux .NET-to-Python integration. Never a production dependency.
#Requires -Version 7.0
param([Parameter(Mandatory)][string]$FixtureRoot,[Parameter(Mandatory)][string]$SourceRoot,[ValidateSet('roundtrip','cancel','timeout')][string]$Mode='roundtrip')
$ErrorActionPreference='Stop'
if(-not $IsLinux){throw 'This receipt covers native Linux only.'}
. (Join-Path $SourceRoot 'scripts/lib/WslBackup.ps1')
Initialize-WslColdWorkerProtocol
$psi=[Diagnostics.ProcessStartInfo]::new('/usr/bin/python3')
$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
foreach($arg in @('-I','-B',(Join-Path $SourceRoot 'tests/helpers/wsl-cold-worker-child.py'),'--synthetic-context',
    (Join-Path $FixtureRoot 'synthetic-worker-context.json'))){$psi.ArgumentList.Add($arg)}
$child=[Diagnostics.Process]::new();$child.StartInfo=$psi
$source=[IO.File]::OpenRead((Join-Path $FixtureRoot 'source.bin'))
$secret=[IO.File]::OpenRead((Join-Path $FixtureRoot 'secure-input'))
$output=[IO.File]::Open((Join-Path $FixtureRoot 'partial.bin'),[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
$request=[IO.File]::ReadAllBytes((Join-Path $FixtureRoot 'request.json'))
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
public sealed class ColdBlockedTestSource : Stream {
    readonly Stream inner; readonly CancellationTokenSource trigger; readonly bool cancel;
    public ColdBlockedTestSource(Stream source,CancellationTokenSource owner,bool cancelAtRead) { inner=source;trigger=owner;cancel=cancelAtRead; }
    public override bool CanRead=>inner.CanRead; public override bool CanSeek=>inner.CanSeek; public override bool CanWrite=>false;
    public override long Length=>inner.Length; public override long Position { get=>inner.Position; set=>inner.Position=value; }
    public override int Read(byte[] b,int o,int n)=>inner.Read(b,o,n);
    public override long Seek(long o,SeekOrigin origin)=>inner.Seek(o,origin);
    public override void Flush()=>inner.Flush(); public override void SetLength(long n)=>throw new NotSupportedException();
    public override void Write(byte[] b,int o,int n)=>throw new NotSupportedException();
    public override async ValueTask<int> ReadAsync(Memory<byte> b,CancellationToken token=default) {
        // This is reached only AFTER the complete request and secure frame writes.
        if(cancel) trigger.Cancel();
        await Task.Delay(Timeout.Infinite,token);
        return 0;
    }
}
'@
$cts=[Threading.CancellationTokenSource]::new()
try {
    [void]$child.Start()
    $deadline=if($Mode -eq 'timeout'){3000}else{30000}
    $incoming=if($Mode -eq 'roundtrip'){$source}else{[ColdBlockedTestSource]::new($source,$cts,($Mode -eq 'cancel'))}
    $failure=$null;$receipt=$null
    try {$receipt=[Revealfleet.Backup.ColdProtocol]::ExchangeAsync($child,$incoming,$output,$secret,$request,$deadline,$cts.Token).GetAwaiter().GetResult()} catch {$failure=$_.Exception.GetBaseException().Message}
    if(-not $child.HasExited -or -not $source.CanRead -or -not $output.CanWrite){throw 'Lifetime/custody failed before cleanup'}
    if($Mode -ne 'roundtrip'){
        if($failure -ne 'Cold transaction rejected; worker acknowledged teardown; retain partial custody'){throw 'Expected actual Linux teardown ACK before cleanup'}
        [IO.File]::WriteAllText((Join-Path $FixtureRoot 'dotnet-negative.json'),($Mode+' acknowledged'))
        return
    }
    if($null -ne $failure){throw $failure}
    $output.Flush($true)
    $source.Position=0;$output.Position=0
    if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($source)) -cne [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($output))){throw 'Independent all-byte hash mismatch'}
    [IO.File]::WriteAllBytes((Join-Path $FixtureRoot 'dotnet-receipt.json'),$receipt)
} finally {
    # Defensive only; success assertions above must already have proved exit/custody.
    if(-not $child.HasExited){$child.Kill($true);[void]$child.WaitForExit(5000)}
    $source.Dispose();$secret.Dispose();$output.Dispose();$child.Dispose();$cts.Dispose()
}

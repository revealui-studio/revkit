// Framed selected-worker mechanics. No discovery, process launch or production admission.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Revealfleet.Backup {
    public static class ColdProtocol {
        static readonly System.Collections.Concurrent.ConcurrentDictionary<string,Task> unsettled = new System.Collections.Concurrent.ConcurrentDictionary<string,Task>();
        public static bool CallerIoSettled(string transaction) => !unsettled.TryGetValue(transaction,out var task) || task.IsCompleted;
        public const string ControlStart = "revkit-cold-control-started-v1\n";
        static void ControlBudgets(int startup,int operation,int teardown,bool selected) {
            if(operation<1 || operation>(selected ? 60000 : 30000) || teardown<1 || teardown>10000 ||
                (selected && (startup<1 || startup>180000))) throw new ArgumentException("Control bounds");
        }
        public static async Task<string> RunControlAsync(string file,string[] args,byte[] input,int timeout) {
            if(input.Length>1048576)throw new ArgumentException("Control input bound");
            ControlBudgets(0,timeout,5000,false);
            using var child=StartControl(file,args);
            return await ControlOnProcessAsync(child,input,0,timeout,5000,false).ConfigureAwait(false);
        }
        public static async Task<string> RunSelectedWorkerControlAsync(string file,string[] args,byte[] input,int startup,int operation,int teardown) {
            if(input.Length>1048576)throw new ArgumentException("Control input bound");
            ControlBudgets(startup,operation,teardown,true);
            using var child=StartControl(file,args);
            return await RunSelectedControlOnProcessAsync(child,input,startup,operation,teardown).ConfigureAwait(false);
        }
        static Process StartControl(string file,string[] args) {
            var psi=new ProcessStartInfo(file) {UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true};
            foreach(var arg in args)psi.ArgumentList.Add(arg);
            return Process.Start(psi);
        }
        public static Task<string> RunSelectedControlOnProcessAsync(Process child,byte[] input,int startup,int operation,int teardown) {
            ControlBudgets(startup,operation,teardown,true);
            return ControlOnProcessAsync(child,input,startup,operation,teardown,true);
        }
        static async Task<string> ControlOnProcessAsync(Process child,byte[] input,int startup,int operation,int teardown,bool selected) {
            if(input.Length>1048576)throw new ArgumentException("Control input bound");
            using var stop=new CancellationTokenSource(selected ? startup : operation);
            async Task<byte[]> Drain(Stream stream,bool error) {
                using var output=new MemoryStream();var buffer=new byte[4096];int n;
                try {
                    // Only the selected immutable worker emits this fixed prefix.
                    // It means Python/bootstrap entered, NEVER policy admission.
                    if(selected && !error) {
                        var marker=Encoding.ASCII.GetBytes(ControlStart);var actual=new byte[marker.Length];
                        await stream.ReadExactlyAsync(actual,stop.Token).ConfigureAwait(false);
                        if(!actual.AsSpan().SequenceEqual(marker))throw new InvalidDataException("Worker start marker refused");
                        stop.CancelAfter(operation);
                    }
                    while((n=await stream.ReadAsync(buffer,stop.Token).ConfigureAwait(false))!=0) {
                        if(output.Length+n>65536)throw new InvalidDataException("Control output bound");
                        output.Write(buffer,0,n);
                        if(selected && error)throw new InvalidDataException("Selected worker diagnostics refused");
                    }
                    return output.ToArray();
                } catch {stop.Cancel();throw;}
            }
            async Task Send() {
                try {await child.StandardInput.BaseStream.WriteAsync(input,stop.Token).ConfigureAwait(false);child.StandardInput.Close();}
                catch {stop.Cancel();throw;}
            }
            var tasks=new List<Task>();Task all=Task.CompletedTask;
            try {
                var send=Send();tasks.Add(send);
                var stdout=Drain(child.StandardOutput.BaseStream,false);tasks.Add(stdout);
                var stderr=Drain(child.StandardError.BaseStream,true);tasks.Add(stderr);
                var exit=child.WaitForExitAsync(stop.Token);tasks.Add(exit);
                all=Task.WhenAll(tasks);
                await all.WaitAsync(stop.Token).ConfigureAwait(false);
                if(child.ExitCode!=0)throw new InvalidDataException("Control exit refused");
                var data=await stdout.ConfigureAwait(false);
                return (Array.IndexOf(data,(byte)0)>=0 ? new UnicodeEncoding(false,false,true).GetString(data) : Utf8.GetString(data)).TrimStart('\ufeff');
            } catch {
                stop.Cancel();all=Task.WhenAll(tasks);using var shutdown=new CancellationTokenSource(teardown);
                try {
                    if(!child.HasExited)child.Kill(true);
                    await child.WaitForExitAsync(shutdown.Token).ConfigureAwait(false);
                    try {await all.WaitAsync(shutdown.Token).ConfigureAwait(false);}catch when(all.IsCompleted) { }
                } catch {throw new IOException("Control command teardown unconfirmed");}
                // A settled Windows frontend is NOT Linux descendant proof.
                throw new IOException("Control command refused");
            }
        }
        public const string Protocol = "revkit-cold-worker-v1";
        public const string Profile = "cold-vhd-container-v1";
        static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
        static int Limit(byte kind) => kind == 'D' || kind == 'Y' ? 65536 : kind == 'S' ? 1024 :
            kind == 'H' || kind == 'C' ? 0 : "REKAZFB".IndexOf((char)kind) >= 0 ? 16384 : -1;
        public static byte[] Encode(byte kind, byte[] payload) {
            int limit = Limit(kind);
            if (limit < 0 || payload.Length > limit) throw new InvalidDataException("Frame bound");
            var result = new byte[5+payload.Length]; result[0] = kind;
            System.Buffers.Binary.BinaryPrimitives.WriteInt32LittleEndian(result.AsSpan(1,4), payload.Length);
            payload.CopyTo(result,5); return result;
        }
        public static async Task<(byte,byte[])> ReadAsync(Stream stream, CancellationToken token) {
            var header = new byte[5]; await stream.ReadExactlyAsync(header,token).ConfigureAwait(false);
            int size = System.Buffers.Binary.BinaryPrimitives.ReadInt32LittleEndian(header.AsSpan(1,4));
            if (size < 0 || Limit(header[0]) < 0 || size > Limit(header[0])) throw new InvalidDataException("Frame bound");
            var payload = new byte[size]; await stream.ReadExactlyAsync(payload,token).ConfigureAwait(false);
            return (header[0],payload);
        }
        static Dictionary<string,JsonElement> Object(byte[] data, params string[] fields) {
            using var doc = JsonDocument.Parse(Utf8.GetString(data),new JsonDocumentOptions { MaxDepth=8 });
            if (doc.RootElement.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Control object");
            var result = new Dictionary<string,JsonElement>(StringComparer.Ordinal);
            foreach (var property in doc.RootElement.EnumerateObject()) {
                if (!result.TryAdd(property.Name, property.Value.Clone())) throw new InvalidDataException("Duplicate control field");
            }
            if (result.Count != fields.Length) throw new InvalidDataException("Control fields");
            foreach(var field in fields) if (!result.ContainsKey(field)) throw new InvalidDataException("Control fields");
            return result;
        }
        static bool Hash(string value) {
            if (value == null || value.Length != 64) return false;
            foreach(char c in value) if (!(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f')) return false;
            return true;
        }
        static string Digest(byte[] value) => Convert.ToHexString(SHA256.HashData(value)).ToLowerInvariant();
        public static void ValidateRequest(byte[] data) {
            var r = Object(data,"protocol","profile","transactionId","archiveId","phase","bindingSha256","bytes","sha256");
            foreach(var key in new[]{"transactionId","archiveId"}) {
                string id=r[key].GetString();
                if (!Guid.TryParseExact(id,"D",out var parsed) || parsed.ToString("D") != id) throw new InvalidDataException("Transaction UUID");
            }
            string phase=r["phase"].GetString();
            if (r["protocol"].GetString()!=Protocol || r["profile"].GetString()!=Profile ||
                (phase!="backup" && phase!="restore") || (phase=="backup" && r["archiveId"].GetString()!=r["transactionId"].GetString()) ||
                !Hash(r["bindingSha256"].GetString()) || !Hash(r["sha256"].GetString()) || r["bytes"].GetInt64()<=0)
                throw new InvalidDataException("Request binding");
        }
        static void Receipt(byte[] data, Dictionary<string,JsonElement> request, bool requireNative) {
            var fields=new System.Collections.Generic.List<string>(new[]{"protocol","profile","transactionId","archiveId","phase","bindingSha256","bytes","sha256",
                "toolSha256","linuxChildrenExited","savingsCreditBytes","productionAccepted"});
            if(requireNative)fields.Add("nativeArchiveId");
            var r=Object(data,fields.ToArray());
            if(requireNative && !Hash(r["nativeArchiveId"].GetString()))throw new InvalidDataException("Native archive identity");
            foreach(var key in new[]{"protocol","profile","transactionId","archiveId","phase","bindingSha256","sha256"})
                if(r[key].GetString()!=request[key].GetString()) throw new InvalidDataException("Receipt binding");
            if(r["bytes"].GetInt64()!=request["bytes"].GetInt64() || !r["linuxChildrenExited"].GetBoolean() ||
                r["savingsCreditBytes"].GetInt64()!=0 || r["productionAccepted"].GetBoolean() ||
                r["toolSha256"].GetString()!="c8457f70660064d0f45b38283ab4cc65b342970012013201d3aec713a75898fb")
                throw new InvalidDataException("Receipt policy");
        }
        // Caller retains source lease and partial destination. Neither is disposed here.
        // Secure input is a private caller stream, not args, environment or diagnostic text.
        public static async Task<byte[]> ExchangeAsync(Process child, Stream source, Stream output, Stream secureInput,
            byte[] requestBytes, int timeoutMilliseconds, CancellationToken cancellation,
            Func<CancellationToken,Task> verifyBeforeCommit=null, Stream independentKey=null) {
            ValidateRequest(requestBytes);
            var request=Object(requestBytes,"protocol","profile","transactionId","archiveId","phase","bindingSha256","bytes","sha256");
            if(timeoutMilliseconds<1 || timeoutMilliseconds>86400000 || child.StartInfo.UseShellExecute ||
                !child.StartInfo.RedirectStandardInput || !child.StartInfo.RedirectStandardOutput || !child.StartInfo.RedirectStandardError ||
                !source.CanRead || !output.CanWrite || !secureInput.CanRead) throw new ArgumentException("Bounded binary process/streams required");
            if(request["phase"].GetString()=="restore" && verifyBeforeCommit==null)
                throw new ArgumentException("Restore requires caller durable dense-file rehash before commit");
            using var stop=CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            stop.CancelAfter(timeoutMilliseconds);
            using var writer=new SemaphoreSlim(1,1);
            var token=stop.Token;
            var input=child.StandardInput.BaseStream; var incoming=child.StandardOutput.BaseStream;
            long diagnosticBytes=0;
            async Task Send(byte kind, byte[] data, CancellationToken ct) {
                var frame=Encode(kind,data); await writer.WaitAsync(ct).ConfigureAwait(false);
                try { await input.WriteAsync(frame,ct).ConfigureAwait(false); await input.FlushAsync(ct).ConfigureAwait(false); }
                finally { if(kind=='S' || kind=='Y') { CryptographicOperations.ZeroMemory(frame); CryptographicOperations.ZeroMemory(data); } writer.Release(); }
            }
            async Task Diagnostics() {
                var buffer=new byte[4096]; int n;
                while((n=await child.StandardError.BaseStream.ReadAsync(buffer,token).ConfigureAwait(false))!=0) {
                    diagnosticBytes+=n; if(diagnosticBytes>65536) { stop.Cancel(); throw new InvalidDataException("Diagnostic bound"); }
                }
            }
            async Task Heartbeat() {
                try { while(true) { await Task.Delay(1000,token).ConfigureAwait(false); await Send((byte)'H',Array.Empty<byte>(),token).ConfigureAwait(false); } }
                catch(OperationCanceledException) when(token.IsCancellationRequested) { }
            }
            Task heartbeat=Task.CompletedTask; Task produce=Task.CompletedTask; Task consume=Task.CompletedTask; var diagnostics=Diagnostics();
            bool workerAcknowledged=false;
            try {
                await Send((byte)'R',requestBytes,token).ConfigureAwait(false);
                var secret=new byte[1025]; int length=0,n;
                try {
                    while((n=await secureInput.ReadAsync(secret.AsMemory(length),token).ConfigureAwait(false))!=0) {
                        length+=n; if(length>1024) throw new InvalidDataException("Secure input bound");
                    }
                    if(length==0) throw new InvalidDataException("Secure input empty");
                    foreach(byte b in secret.AsSpan(0,length)) if(b==0 || b==10 || b==13) throw new InvalidDataException("Secure input format");
                    await Send((byte)'S',secret.AsSpan(0,length).ToArray(),token).ConfigureAwait(false);
                } finally { CryptographicOperations.ZeroMemory(secret); }
                heartbeat=Heartbeat();
                if(independentKey!=null) {
                    var key=new byte[65537]; int used=0,read;
                    try {
                        while((read=await independentKey.ReadAsync(key.AsMemory(used),token).ConfigureAwait(false))!=0) {
                            used+=read; if(used>65536) throw new InvalidDataException("Independent key bound");
                        }
                        if(used==0) throw new InvalidDataException("Independent key absent");
                        await Send((byte)'Y',key.AsSpan(0,used).ToArray(),token).ConfigureAwait(false);
                    } finally { CryptographicOperations.ZeroMemory(key); }
                    var ready=await ReadAsync(incoming,token).ConfigureAwait(false);
                    if(ready.Item1=='F') {
                        var failure=Object(ready.Item2,"protocol","transactionId","bindingSha256","code","linuxChildrenExited","productionAccepted");
                        workerAcknowledged=failure["protocol"].GetString()==Protocol && failure["transactionId"].GetString()==request["transactionId"].GetString() && failure["bindingSha256"].GetString()==request["bindingSha256"].GetString() && failure["linuxChildrenExited"].GetBoolean();
                        throw new InvalidDataException("Independent key preparation refused");
                    }
                    if(ready.Item1!='B') throw new InvalidDataException("Independent key preparation refused");
                    var binding=Object(ready.Item2,"protocol","transactionId","bindingSha256");
                    foreach(var name in new[]{"protocol","transactionId","bindingSha256"})
                        if(binding[name].GetString()!=request[name].GetString()) throw new InvalidDataException("Prepared binding");
                }
                async Task Produce() {
                    using var hash=IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                    var buffer=new byte[65536]; long count=0; int read;
                    long expected=request["phase"].GetString()=="backup" ? request["bytes"].GetInt64() : 0;
                    while((read=await source.ReadAsync(buffer,token).ConfigureAwait(false))!=0) {
                        count+=read; if(count>expected) throw new InvalidDataException("Source excess");
                        hash.AppendData(buffer,0,read); await Send((byte)'D',buffer.AsSpan(0,read).ToArray(),token).ConfigureAwait(false);
                    }
                    string digest=Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
                    if(count!=expected || (expected!=0 && digest!=request["sha256"].GetString())) throw new InvalidDataException("Source count/hash");
                    await Send((byte)'E',JsonSerializer.SerializeToUtf8Bytes(new { bytes=count,sha256=digest }),token).ConfigureAwait(false);
                }
                produce=Produce();
                async Task<byte[]> Consume() {
                    using var hash=IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                    long count=0; byte[] candidate=null;
                    while(true) {
                        var frame=await ReadAsync(incoming,token).ConfigureAwait(false);
                        if(frame.Item1=='F') {
                            var f=Object(frame.Item2,"protocol","transactionId","bindingSha256","code","linuxChildrenExited","productionAccepted");
                            workerAcknowledged=f["protocol"].GetString()==Protocol && f["transactionId"].GetString()==request["transactionId"].GetString() &&
                                f["bindingSha256"].GetString()==request["bindingSha256"].GetString() && f["linuxChildrenExited"].GetBoolean();
                            throw new InvalidDataException("Worker rejected transaction");
                        }
                        if(frame.Item1=='D' && candidate==null) {
                            count+=frame.Item2.Length;
                            if(count>request["bytes"].GetInt64()) throw new InvalidDataException("Restored excess");
                            hash.AppendData(frame.Item2); await output.WriteAsync(frame.Item2,token).ConfigureAwait(false); continue;
                        }
                        if(frame.Item1=='A' && candidate==null) {
                            Receipt(frame.Item2,request,independentKey!=null);
                            if(count!=request["bytes"].GetInt64() || Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant()!=request["sha256"].GetString())
                                throw new InvalidDataException("Readback count/hash");
                            await produce.ConfigureAwait(false); await output.FlushAsync(token).ConfigureAwait(false);
                            if(verifyBeforeCommit!=null) await verifyBeforeCommit(token).ConfigureAwait(false);
                            candidate=frame.Item2;
                            await Send((byte)'K',JsonSerializer.SerializeToUtf8Bytes(new { receiptSha256=Digest(candidate) }),token).ConfigureAwait(false); continue;
                        }
                        if(frame.Item1=='Z' && candidate!=null) {
                            Receipt(frame.Item2,request,independentKey!=null);
                            if(!frame.Item2.AsSpan().SequenceEqual(candidate)) throw new InvalidDataException("Final receipt changed");
                            workerAcknowledged=true;
                            // Final acknowledgment + EOF + process exit are all necessary.
                            var one=new byte[1];
                            if(await incoming.ReadAsync(one,token).ConfigureAwait(false)!=0) throw new InvalidDataException("Trailing worker output");
                            return frame.Item2;
                        }
                        throw new InvalidDataException("Worker frame order");
                    }
                }
                var result=Consume(); consume=result;
                // Fail promptly on either direction; never await blocked producer after worker failure.
                var first=await Task.WhenAny(produce,consume).WaitAsync(token).ConfigureAwait(false);
                await first.ConfigureAwait(false);
                await Task.WhenAll(produce,consume).WaitAsync(token).ConfigureAwait(false);
                await child.WaitForExitAsync(token).ConfigureAwait(false);
                await diagnostics.ConfigureAwait(false);
                if(child.ExitCode!=0 || diagnosticBytes!=0) throw new InvalidDataException("Worker exit/diagnostics");
                return await result.ConfigureAwait(false);
            } catch {
                stop.Cancel();
                using var shutdown=new CancellationTokenSource(TimeSpan.FromSeconds(7));
                bool settled=false;
                var io=Task.WhenAll(produce,consume,heartbeat,diagnostics);
                try { await io.WaitAsync(shutdown.Token).ConfigureAwait(false); }
                catch when(io.IsCompleted) { }
                settled=io.IsCompleted;
                if(settled && !workerAcknowledged) {
                    try {
                        await Send((byte)'C',Array.Empty<byte>(),shutdown.Token).ConfigureAwait(false);
                        while(true) {
                            var frame=await ReadAsync(incoming,shutdown.Token).ConfigureAwait(false);
                            if(frame.Item1=='D') continue; // bounded frame, bounded teardown deadline
                            if(frame.Item1!='F') break;
                            var f=Object(frame.Item2,"protocol","transactionId","bindingSha256","code","linuxChildrenExited","productionAccepted");
                            workerAcknowledged=f["protocol"].GetString()==Protocol && f["transactionId"].GetString()==request["transactionId"].GetString() &&
                                f["bindingSha256"].GetString()==request["bindingSha256"].GetString() && f["linuxChildrenExited"].GetBoolean();
                            break;
                        }
                    } catch { }
                }
                if(workerAcknowledged) {
                    try { await child.WaitForExitAsync(shutdown.Token).ConfigureAwait(false); }
                    catch { workerAcknowledged=false; }
                }
                if(!settled) { unsettled[request["transactionId"].GetString()]=io; throw new InvalidDataException("Cold transaction rejected; stream tasks unsettled; retain caller custody"); }
                // A killed wsl.exe is NOT an acknowledgment from Linux. Closing the pipe
                // triggers worker EOF/idle watchdog, but missing F/Z remains unconfirmed.
                throw new InvalidDataException(workerAcknowledged ?
                    "Cold transaction rejected; worker acknowledged teardown; retain partial custody" :
                    "Cold transaction rejected; Linux lifetime unconfirmed; retain lease and reconcile journal");
            } finally {
                stop.Cancel();
                try { await heartbeat.ConfigureAwait(false); } catch { }
                // No caller stream disposal, child kill or partial deletion. The caller must
                // reconcile an unconfirmed Linux lifetime; parent cleanup cannot certify it.
            }
        }
    }
}

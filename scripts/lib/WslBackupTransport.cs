// Binary mechanics only. No source discovery, process launch, key custody or admission.
using System;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

namespace Revealfleet.Backup {
    public sealed class BinaryReceipt {
        public long InputBytes { get; set; }
        public long OutputBytes { get; set; }
        public string InputSha256 { get; set; }
        public string OutputSha256 { get; set; }
        public int ExitCode { get; set; }
    }
    public static class BinaryTransport {
        public static async Task<BinaryReceipt> TransferAsync(Process child, Stream input, Stream output,
            long inputBytes, string inputSha256, long outputBytes, string outputSha256,
            int timeoutMilliseconds, CancellationToken cancellation) {
            if (inputBytes < 0 || outputBytes < 0 || timeoutMilliseconds < 1 || timeoutMilliseconds > 86400000)
                throw new ArgumentException("Bounded byte counts and timeout required");
            if (!input.CanRead || !output.CanWrite || !child.StartInfo.RedirectStandardInput ||
                !child.StartInfo.RedirectStandardOutput || !child.StartInfo.RedirectStandardError || child.StartInfo.UseShellExecute)
                throw new ArgumentException("Already-started shell-free redirected binary process required");
            // Caller owns streams, including any OS exclusion handle, for the WHOLE transaction.
            using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            stop.CancelAfter(timeoutMilliseconds);
            var token = stop.Token;
            long errors = 0;
            async Task<(long, string)> Copy(Stream from, Stream to, long expected) {
                try {
                    var buffer = new byte[65536];
                    long count = 0;
                    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                    while (true) {
                        int n = await from.ReadAsync(buffer.AsMemory(), token).ConfigureAwait(false);
                        if (n == 0) break;
                        if (n > expected - count) throw new InvalidDataException("Binary stream exceeds bound");
                        await to.WriteAsync(buffer.AsMemory(0,n), token).ConfigureAwait(false);
                        hash.AppendData(buffer,0,n); count += n;
                    }
                    if (count != expected) throw new InvalidDataException("Binary stream truncated");
                    await to.FlushAsync(token).ConfigureAwait(false);
                    return (count, Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant());
                } catch { stop.Cancel(); throw; }
            }
            async Task<(long, string)> Send() {
                try { return await Copy(input, child.StandardInput.BaseStream, inputBytes).ConfigureAwait(false); }
                finally { child.StandardInput.Close(); }
            }
            async Task DrainErrors() {
                try {
                    var buffer = new byte[4096];
                    int n;
                    while ((n = await child.StandardError.BaseStream.ReadAsync(buffer.AsMemory(), token).ConfigureAwait(false)) != 0) {
                        errors += n;
                        if (errors > 65536) throw new InvalidDataException("Backend diagnostics exceed bound");
                    }
                } catch { stop.Cancel(); throw; }
            }
            async Task Exit() {
                try {
                    await child.WaitForExitAsync(token).ConfigureAwait(false);
                    if (child.ExitCode != 0) throw new InvalidDataException("Backend exit rejected");
                } catch { stop.Cancel(); throw; }
            }
            var send = Send();
            var receive = Copy(child.StandardOutput.BaseStream, output, outputBytes);
            var diagnostics = DrainErrors();
            var exit = Exit();
            var all = Task.WhenAll(send, receive, diagnostics, exit);
            try {
                await all.WaitAsync(token).ConfigureAwait(false);
                var sent = await send.ConfigureAwait(false);
                var received = await receive.ConfigureAwait(false);
                if (errors != 0 ||
                    (inputSha256 != null && !String.Equals(sent.Item2,inputSha256,StringComparison.OrdinalIgnoreCase)) ||
                    !String.Equals(received.Item2,outputSha256,StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("Binary digest or diagnostics rejected");
                return new BinaryReceipt { InputBytes=sent.Item1, OutputBytes=received.Item1,
                    InputSha256=sent.Item2, OutputSha256=received.Item2, ExitCode=child.ExitCode };
            } catch {
                stop.Cancel();
                try { if (!child.HasExited) child.Kill(true); } catch (InvalidOperationException) { }
                try { await all.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false); } catch { }
                // No backend text, bytes, secret values or process arguments escape this boundary.
                throw new InvalidDataException("Binary transaction rejected; partial output must be retained");
            }
        }
    }
}

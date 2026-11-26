// Windows-only mechanics. Caller must supply authoritative reviewed registry binding.
// Construction opens a source: it must occur ONLY after production admission.
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Security;
using System.Security.Cryptography;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
namespace Revealfleet.Backup {
    public sealed class ColdSourceLease : IDisposable {
        [StructLayout(LayoutKind.Sequential)] struct Info {
            public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created,Accessed,Written;
            public uint Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;
        }
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle h,out Info value);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandleW(SafeFileHandle h,StringBuilder name,uint length,uint flags);
        readonly FileStream stream;
        readonly string path;
        readonly Info identity;
        bool disposed;
        public Stream Bytes { get { if(disposed) throw new ObjectDisposedException("lease"); return stream; } }
        public long Length => ((long)identity.SizeHigh<<32)|identity.SizeLow;
        public string FileIdentity => identity.Volume.ToString("x8")+":"+identity.IndexHigh.ToString("x8")+identity.IndexLow.ToString("x8");
        public string CanonicalPath => path;
        static string Final(SafeFileHandle h) {
            var text=new StringBuilder(32768);
            uint count=GetFinalPathNameByHandleW(h,text,(uint)text.Capacity,0);
            if(count==0 || count>=text.Capacity) throw new IOException("Final handle path unavailable");
            string result=text.ToString();
            if(!result.StartsWith(@"\\?\",StringComparison.Ordinal) || result.StartsWith(@"\\?\UNC\",StringComparison.OrdinalIgnoreCase))
                throw new IOException("Local canonical volume path required");
            return result.Substring(4);
        }
        static void NoReparse(string value) {
            for(string item=value; item!=null; item=Path.GetDirectoryName(item)) {
                if((File.GetAttributes(item)&FileAttributes.ReparsePoint)!=0) throw new IOException("Reparse source path refused");
                if(item==Path.GetPathRoot(item)) break;
            }
        }
        // Review-only inspection opens a read exclusion handle; it is not cold proof.
        // Production code must bind this observation to authoritative registration
        // and revalidate on the continuously held transaction handle.
        public static string InspectIdentityForReview(string canonicalPath) {
            if(!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Windows source identity required");
            NoReparse(canonicalPath);
            using var handle=new FileStream(canonicalPath,FileMode.Open,FileAccess.Read,FileShare.Read);
            if(!GetFileInformationByHandle(handle.SafeFileHandle,out var info) || info.Links!=1 ||
                !String.Equals(Final(handle.SafeFileHandle),canonicalPath,StringComparison.OrdinalIgnoreCase)) throw new IOException("Review handle identity refused");
            return info.Volume.ToString("x8")+":"+info.IndexHigh.ToString("x8")+info.IndexLow.ToString("x8");
        }
        public ColdSourceLease(string reviewedCanonicalPath,string reviewedFileIdentity,bool denyOtherReaders=false) {
            if(!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Windows source lease required");
            if(String.IsNullOrWhiteSpace(reviewedCanonicalPath) || reviewedCanonicalPath.Length<4 ||
                reviewedCanonicalPath[1]!=':' || reviewedCanonicalPath[2]!='\\' ||
                !String.Equals(Path.GetFullPath(reviewedCanonicalPath),reviewedCanonicalPath,StringComparison.OrdinalIgnoreCase) ||
                reviewedCanonicalPath.IndexOf(':',2)>=0 || String.IsNullOrWhiteSpace(reviewedFileIdentity))
                throw new ArgumentException("Reviewed local canonical path and file identity required");
            if(!String.Equals(new DriveInfo(Path.GetPathRoot(reviewedCanonicalPath)).DriveFormat,"NTFS",StringComparison.OrdinalIgnoreCase))
                throw new IOException("NTFS source required");
            path=reviewedCanonicalPath; NoReparse(path);
            stream=new FileStream(path,FileMode.Open,FileAccess.Read,denyOtherReaders ? FileShare.None : FileShare.Read,65536,FileOptions.Asynchronous|FileOptions.SequentialScan);
            try {
                if(!GetFileInformationByHandle(stream.SafeFileHandle,out identity)) throw new Win32Exception(Marshal.GetLastWin32Error());
                if((identity.Attributes & (uint)(FileAttributes.Directory|FileAttributes.ReparsePoint))!=0 || identity.Links!=1 || Length<=0 ||
                    !String.Equals(Final(stream.SafeFileHandle),path,StringComparison.OrdinalIgnoreCase) ||
                    !String.Equals(FileIdentity,reviewedFileIdentity,StringComparison.Ordinal)) throw new IOException("Source handle identity mismatch");
                NoReparse(path);
            } catch { stream.Dispose(); throw; }
        }
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateDirectoryW(string path,IntPtr security);
        // Atomic NEW namespace with its descriptor at creation. Existing paths
        // fail ERROR_ALREADY_EXISTS; no create-then-ACL replacement window.
        [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public uint Length; public IntPtr Descriptor; public int Inherit; }
        public static void CreateProtectedDirectory(string path,byte[] descriptor) {
            if(!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
            IntPtr sd=Marshal.AllocHGlobal(descriptor.Length),attributes=IntPtr.Zero;
            try {
                Marshal.Copy(descriptor,0,sd,descriptor.Length);
                var value=new SecurityAttributes { Length=(uint)Marshal.SizeOf<SecurityAttributes>(),Descriptor=sd,Inherit=0 };
                attributes=Marshal.AllocHGlobal((int)value.Length);Marshal.StructureToPtr(value,attributes,false);
                if(!CreateDirectoryW(path,attributes)) throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally { if(attributes!=IntPtr.Zero)Marshal.FreeHGlobal(attributes);Marshal.FreeHGlobal(sd); }
        }
        public static void CreateTransactionDirectory(string path) {
            if(!CreateDirectoryW(path,IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        public static void ValidateDenseDestination(FileStream held,string canonicalPath,long expected) {
            if(!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
            NoReparse(canonicalPath);
            if(!GetFileInformationByHandle(held.SafeFileHandle,out var info) || info.Links!=1 ||
                (info.Attributes & (uint)(FileAttributes.SparseFile|FileAttributes.ReparsePoint|FileAttributes.Directory))!=0 ||
                (((long)info.SizeHigh<<32)|info.SizeLow)!=expected ||
                !String.Equals(Final(held.SafeFileHandle),canonicalPath,StringComparison.OrdinalIgnoreCase) ||
                !String.Equals(new DriveInfo(Path.GetPathRoot(canonicalPath)).DriveFormat,"NTFS",StringComparison.OrdinalIgnoreCase)) throw new IOException("Dense destination identity/length refused");
        }
        public void ValidateUnchanged() {
            if(disposed) throw new ObjectDisposedException("lease");
            NoReparse(path);
            if(!GetFileInformationByHandle(stream.SafeFileHandle,out var now) ||
                now.Volume!=identity.Volume || now.IndexHigh!=identity.IndexHigh || now.IndexLow!=identity.IndexLow ||
                now.SizeHigh!=identity.SizeHigh || now.SizeLow!=identity.SizeLow || now.Links!=1 || now.Attributes!=identity.Attributes ||
                now.Written.dwHighDateTime!=identity.Written.dwHighDateTime || now.Written.dwLowDateTime!=identity.Written.dwLowDateTime ||
                !String.Equals(Final(stream.SafeFileHandle),path,StringComparison.OrdinalIgnoreCase)) throw new IOException("Source lease continuity changed");
        }
        public void Dispose() { if(!disposed) { disposed=true; stream.Dispose(); } }
    }
    public sealed class ColdCommitGuard : IDisposable {
        readonly ColdSourceLease source; readonly FileStream target; readonly string targetPath,expectedHash;
        readonly JsonDocument policy; readonly EventWaitHandle changed=new EventWaitHandle(false,EventResetMode.ManualReset);
        readonly RegistryKey[] keys=new RegistryKey[3];
        readonly CancellationTokenSource cancellation;
        Task monitor; bool disposed;
        string hardwareHost,hardwareScript,hardwarePolicy,hardwareDigest;
        [DllImport("advapi32.dll",SetLastError=true)] static extern int RegNotifyChangeKeyValue(SafeRegistryHandle key,bool subtree,uint filter,SafeWaitHandle signal,bool asynchronous);
        public ColdCommitGuard(ColdSourceLease heldSource,FileStream destination,string path,string sha,byte[] policyBytes,CancellationTokenSource stop) {
            source=heldSource; target=destination; targetPath=path; expectedHash=sha; cancellation=stop;
            policy=JsonDocument.Parse(policyBytes);
            var root=policy.RootElement; var controller=root.GetProperty("controller");
            var ids=new[]{controller.GetProperty("source").GetProperty("registrationId").GetString(),
                controller.GetProperty("protected").GetProperty("registrationId").GetString(),root.GetProperty("worker").GetProperty("registrationId").GetString()};
            try {
                for(int i=0;i<ids.Length;i++) {
                    keys[i]=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Lxss\{"+ids[i]+"}",false);
                    if(keys[i]==null || RegNotifyChangeKeyValue(keys[i].Handle,true,1|4,changed.SafeWaitHandle,true)!=0)
                        throw new IOException("Registration continuity watch unavailable");
                }
                Validate();
            } catch { Dispose(); throw; }
        }
        void Validate() {
            if(disposed || changed.WaitOne(0)) throw new IOException("Registration changed during custody");
            source.ValidateUnchanged();
            if(DateTimeOffset.UtcNow.ToUnixTimeSeconds()>=policy.RootElement.GetProperty("expiresAt").GetInt64()) throw new IOException("Live policy expired");
        }
        public void ConfigureHardwareProbe(string host,string script,string path,string digest) {
            if(monitor!=null || hardwareHost!=null) throw new InvalidOperationException("Hardware observer already bound");
            hardwareHost=host;hardwareScript=script;hardwarePolicy=path;hardwareDigest=digest;
        }
        async Task HardwareAsync() {
            if(hardwareHost==null) throw new IOException("Continuous Windows hardware observer required");
            var result=await ColdProtocol.RunControlAsync(hardwareHost,new[]{"-NoLogo","-NoProfile","-NonInteractive","-File",hardwareScript,"-PolicyPath",hardwarePolicy,"-ReviewedPolicySha256",hardwareDigest},Array.Empty<byte>(),15000).ConfigureAwait(false);
            if(result!="windows-hardware-bound-v1") throw new IOException("Windows hardware continuity refused");
        }
        public void StartMonitor() {
            monitor=Task.Run(async ()=>{
                try { while(!cancellation.IsCancellationRequested) { Validate(); Capacity(); await HardwareAsync().ConfigureAwait(false); await Task.Delay(1000,cancellation.Token).ConfigureAwait(false); } }
                catch(OperationCanceledException) when(cancellation.IsCancellationRequested) { }
                catch { cancellation.Cancel(); }
            });
        }
        void Capacity() {
            var p=policy.RootElement; var c=p.GetProperty("controller");
            long reserve=p.GetProperty("budget").GetProperty("reserveBytes").GetInt64();
            long remaining=c.GetProperty("restore").GetProperty("imageBytes").GetInt64();
            if(target!=null) remaining=Math.Max(0,remaining-target.Length);
            string restoreRoot=Path.GetPathRoot(c.GetProperty("restore").GetProperty("path").GetString());
            string workerRoot=Path.GetPathRoot(c.GetProperty("workerVhdx").GetProperty("path").GetString());
            long restoreOverhead=c.GetProperty("restore").GetProperty("overheadBytes").GetInt64();
            long workspace=p.GetProperty("budget").GetProperty("workspaceAdditionalBytes").GetInt64();
            if(String.Equals(c.GetProperty("restore").GetProperty("hardware").GetProperty("volumeUuid").GetString(),c.GetProperty("workerVhdx").GetProperty("hardware").GetProperty("volumeUuid").GetString(),StringComparison.Ordinal)) {
                if(new DriveInfo(restoreRoot).AvailableFreeSpace < checked(remaining+restoreOverhead+workspace+reserve)) throw new IOException("Live shared-volume reserve refused");
            } else {
                if(new DriveInfo(restoreRoot).AvailableFreeSpace < checked(remaining+restoreOverhead+reserve) ||
                    new DriveInfo(workerRoot).AvailableFreeSpace < checked(workspace+reserve)) throw new IOException("Live volume reserve refused");
            }
        }
        public Func<CancellationToken,Task> Callback() => VerifyAsync;
        public async Task VerifyAsync(CancellationToken token) {
            Validate(); Capacity();
            var start=new System.Diagnostics.ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"System32","wsl.exe"));
            start.UseShellExecute=false;start.CreateNoWindow=true;start.RedirectStandardOutput=true;start.RedirectStandardError=true;
            start.StandardOutputEncoding=Encoding.Unicode;
            foreach(var arg in new[]{"--list","--running","--quiet"}) start.ArgumentList.Add(arg);
            using var child=System.Diagnostics.Process.Start(start);
            using var timeout=CancellationTokenSource.CreateLinkedTokenSource(token);timeout.CancelAfter(15000);
            try {
                var output=child.StandardOutput.ReadToEndAsync(timeout.Token);var error=child.StandardError.ReadToEndAsync(timeout.Token);
                await child.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
                string names=await output.ConfigureAwait(false);string diagnostics=await error.ConfigureAwait(false);
                if(child.ExitCode!=0 || names.Length>65536 || diagnostics.Length>65536) throw new IOException("Cold state observation failed");
                var c=policy.RootElement.GetProperty("controller");
                foreach(var name in names.Replace("\0","").Split('\n'))
                    if(name.Trim().TrimStart('\ufeff')==c.GetProperty("source").GetProperty("distro").GetString() || name.Trim().TrimStart('\ufeff')==c.GetProperty("protected").GetProperty("distro").GetString()) throw new IOException("Source/recovery started during custody");
            } catch { using var shutdown=new CancellationTokenSource(5000); if(!child.HasExited) { child.Kill(true); await child.WaitForExitAsync(shutdown.Token).ConfigureAwait(false); } throw; }
            if(target!=null) {
                await target.FlushAsync(token).ConfigureAwait(false); target.Flush(true);
                long expected=policy.RootElement.GetProperty("controller").GetProperty("restore").GetProperty("imageBytes").GetInt64();
                ColdSourceLease.ValidateDenseDestination(target,targetPath,expected);
                target.Position=0;
                string actual=Convert.ToHexString(await SHA256.HashDataAsync(target,token).ConfigureAwait(false)).ToLowerInvariant();
                if(actual!=expectedHash) throw new IOException("Independent dense target rehash refused");
                target.Position=expected;
                ColdSourceLease.ValidateDenseDestination(target,targetPath,expected);
            }
            await HardwareAsync().ConfigureAwait(false); Validate(); Capacity();
        }
        public async Task StopAsync() { cancellation.Cancel(); if(monitor!=null) await monitor.ConfigureAwait(false); }
        public void Dispose() {
            if(disposed)return;disposed=true;
            foreach(var key in keys) key?.Dispose();changed.Dispose();policy.Dispose();
        }
        sealed class PrivateBufferStream : MemoryStream {
            readonly byte[] buffer;
            public PrivateBufferStream(byte[] bytes) : base(bytes,false) { buffer=bytes; }
            protected override void Dispose(bool disposing) { CryptographicOperations.ZeroMemory(buffer);base.Dispose(disposing); }
        }
        public static MemoryStream PrivateInput(SecureString value) {
            if(value==null || value.Length==0) throw new ArgumentException("Explicit private caller input required");
            IntPtr ptr=Marshal.SecureStringToGlobalAllocUnicode(value);
            char[] characters=new char[value.Length]; byte[] bytes=null;
            try {
                Marshal.Copy(ptr,characters,0,characters.Length);
                bytes=new UTF8Encoding(false,true).GetBytes(characters);
                if(bytes.Length>1024 || Array.IndexOf(bytes,(byte)0)>=0 || Array.IndexOf(bytes,(byte)10)>=0 || Array.IndexOf(bytes,(byte)13)>=0) throw new ArgumentException("Private input format");
                return new PrivateBufferStream(bytes);
            } catch { if(bytes!=null) CryptographicOperations.ZeroMemory(bytes);throw; }
            finally { Array.Clear(characters);Marshal.ZeroFreeGlobalAllocUnicode(ptr); }
        }
    }

}

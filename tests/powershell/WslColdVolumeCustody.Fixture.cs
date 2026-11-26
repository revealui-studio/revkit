// Windows test-only filtered caller. NEVER a production runtime dependency.
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
namespace Revealfleet.Tests {
    public sealed class OrdinaryCaller : IDisposable {
        [StructLayout(LayoutKind.Sequential)] struct SidAttributes {public IntPtr Sid;public uint Attributes;}
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool CreateRestrictedToken(IntPtr token,uint flags,uint disabled,ref SidAttributes sid,uint deleted,IntPtr privileges,uint restricted,IntPtr sids,out IntPtr result);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool ImpersonateLoggedOnUser(IntPtr token);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool RevertToSelf();
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
        readonly IntPtr token;bool active;
        public OrdinaryCaller() {
            IntPtr original=IntPtr.Zero,buffer=IntPtr.Zero;
            try {
                if(!OpenProcessToken(GetCurrentProcess(),10,out original))throw new Win32Exception(Marshal.GetLastWin32Error());
                var admin=new SecurityIdentifier("S-1-5-32-544");byte[] bytes=new byte[admin.BinaryLength];admin.GetBinaryForm(bytes,0);
                buffer=Marshal.AllocHGlobal(bytes.Length);Marshal.Copy(bytes,0,buffer,bytes.Length);
                var disabled=new SidAttributes {Sid=buffer,Attributes=0};
                // Disable all privileges except traversal and mark Admin SID
                // deny-only. This is a thread-local duplicate of the caller.
                if(!CreateRestrictedToken(original,1,1,ref disabled,0,IntPtr.Zero,0,IntPtr.Zero,out token))throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally {if(original!=IntPtr.Zero)CloseHandle(original);if(buffer!=IntPtr.Zero)Marshal.FreeHGlobal(buffer);}
        }
        public void Enter() {if(!ImpersonateLoggedOnUser(token))throw new Win32Exception(Marshal.GetLastWin32Error());active=true;}
        public static bool CanOpen(string path,uint access) {
            using var handle=CreateFileW(path,access,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
            if(handle.IsInvalid) {int error=Marshal.GetLastWin32Error();if(error!=5)throw new Win32Exception(error);return false;}
            return true;
        }
        public static void CreateChildren(string root) {
            Directory.CreateDirectory(Path.Combine(root,"ordinary-created-directory"));
            File.WriteAllText(Path.Combine(root,"ordinary-created-file"),"ordinary synthetic bytes");
        }
        public void Dispose(){if(active && !RevertToSelf())throw new Win32Exception(Marshal.GetLastWin32Error());active=false;CloseHandle(token);}
    }
}

// Bounded native-API laboratory ONLY. This type is not in the runtime package.
// It can mutate only UUID trees it has exclusively created in this process.
namespace Revealfleet.Tests {
    public static class SyntheticSecurityLab {
        static readonly System.Collections.Generic.HashSet<string> roots=new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
        [StructLayout(LayoutKind.Sequential)] struct Attributes {public uint Length;public IntPtr Descriptor;public int Inherit;}
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateDirectoryW(string path,IntPtr attributes);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle,System.Text.StringBuilder name,uint size,uint flags);
        [DllImport("ntdll.dll",ExactSpelling=true)] static extern int NtSetSecurityObject(SafeFileHandle handle,uint selection,IntPtr descriptor);
        [DllImport("ntdll.dll",ExactSpelling=true)] static extern uint RtlNtStatusToDosError(int status);
        [StructLayout(LayoutKind.Sequential)] struct Info {
            public uint Attributes;public System.Runtime.InteropServices.ComTypes.FILETIME Created,Accessed,Written;
            public uint Volume,High,Low,Links,IndexHigh,IndexLow;
        }
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle handle,out Info info);
        public static long[] Metadata(string path) {
            using var handle=CreateFileW(path,0x80,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
            if(handle.IsInvalid || !GetFileInformationByHandle(handle,out var info))throw new Win32Exception(Marshal.GetLastWin32Error());
            long Time(System.Runtime.InteropServices.ComTypes.FILETIME value)=>(long)(((ulong)(uint)value.dwHighDateTime<<32)|(uint)value.dwLowDateTime);
            return new long[] {info.Attributes,Time(info.Created),Time(info.Written)};
        }
        public static string CreateRoot(string parent,byte[] descriptor) {
            if(!OperatingSystem.IsWindows())throw new PlatformNotSupportedException();
            parent=Path.GetFullPath(parent);
            if(parent==Path.GetPathRoot(parent) || !Directory.Exists(parent))throw new IOException("Synthetic non-root existing parent required");
            for(string current=parent;current!=null;current=Path.GetDirectoryName(current)) {
                if((File.GetAttributes(current)&FileAttributes.ReparsePoint)!=0 || File.Exists(Path.Combine(current,".git")) || Directory.Exists(Path.Combine(current,".git")))throw new IOException("Synthetic parent reparse/Git refused");
            }
            string root=Path.Combine(parent,Guid.NewGuid().ToString("N"));
            IntPtr sd=Marshal.AllocHGlobal(descriptor.Length),attributes=IntPtr.Zero;
            try {
                Marshal.Copy(descriptor,0,sd,descriptor.Length);var value=new Attributes {Length=(uint)Marshal.SizeOf<Attributes>(),Descriptor=sd};
                attributes=Marshal.AllocHGlobal((int)value.Length);Marshal.StructureToPtr(value,attributes,false);
                if(!CreateDirectoryW(root,attributes))throw new Win32Exception(Marshal.GetLastWin32Error());
                roots.Add(root);return root;
            } finally {if(attributes!=IntPtr.Zero)Marshal.FreeHGlobal(attributes);Marshal.FreeHGlobal(sd);}
        }
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool DuplicateHandle(IntPtr source,SafeFileHandle handle,IntPtr target,out SafeFileHandle copy,uint access,bool inherit,uint options);
        public sealed class CandidateTransaction : IDisposable {
            readonly object lease;readonly Type type;readonly SafeFileHandle handle;readonly string path,identity;
            public int MutationCalls {get;private set;}
            public bool IsClosed => handle.IsClosed;
            internal CandidateTransaction(object original) {
                if(!OperatingSystem.IsWindows())throw new PlatformNotSupportedException();
                type=original?.GetType();
                if(type?.FullName!="Revealfleet.Backup.ColdDirectorySecurityLease")throw new IOException("Exact owning lease required");
                lease=original;path=(string)type.GetProperty("CanonicalPath").GetValue(lease);
                bool owned=false;foreach(string root in roots)if(path==root || path.StartsWith(root+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase))owned=true;
                if(!owned)throw new IOException("Only newly created synthetic trees may use candidate API");
                // TEST-ONLY reflection keeps the runtime authority surface
                // closed. Duplicate the ORIGINAL open description, with SAME
                // access and no inheritance, never re-request revoked rights.
                var source=(SafeFileHandle)type.GetField("handle",System.Reflection.BindingFlags.NonPublic|System.Reflection.BindingFlags.Instance).GetValue(lease);
                if(!DuplicateHandle(GetCurrentProcess(),source,GetCurrentProcess(),out handle,0,false,2))throw new Win32Exception(Marshal.GetLastWin32Error());
                identity=(string)type.GetProperty("FileIdentity").GetValue(lease);
                try {Validate();}catch {handle.Dispose();throw;}
            }
            void Validate() {
                if(handle.IsClosed)throw new ObjectDisposedException("Synthetic transaction");
                type.GetMethod("ValidateIdentity").Invoke(lease,null);
                var name=new System.Text.StringBuilder(32768);
                if(!GetFileInformationByHandle(handle,out var info) || info.Volume.ToString("x8")+":"+info.IndexHigh.ToString("x8")+info.IndexLow.ToString("x8")!=identity ||
                   (info.Attributes&0x410)!=0x10 || GetFinalPathNameByHandleW(handle,name,(uint)name.Capacity,0)==0 || name.ToString()!=@"\\?\"+path)
                    throw new IOException("Synthetic retained handle identity/name refused");
            }
            public void Replace(string expected,byte[] descriptor) {
                Validate();
                var before=type.GetMethod("Read").Invoke(lease,null);var snapshot=before.GetType();
                if((string)snapshot.GetProperty("Sha256").GetValue(before)!=expected)throw new IOException("Synthetic descriptor drift");
                var target=Activator.CreateInstance(snapshot,new object[]{descriptor});
                // Reuse the owning versioned scope validator, not a parallel
                // looser test policy. Any changed template fails before Nt.
                snapshot.GetMethod("RequireReplacementScope").Invoke(before,new[]{target});
                IntPtr buffer=Marshal.AllocHGlobal(descriptor.Length);
                try {
                    Marshal.Copy(descriptor,0,buffer,descriptor.Length);MutationCalls++;
                    int status=NtSetSecurityObject(handle,5,buffer);
                    if(status<0)throw new Win32Exception((int)RtlNtStatusToDosError(status));
                } finally {Marshal.FreeHGlobal(buffer);}
                Validate();
                var after=type.GetMethod("Read").Invoke(lease,null);
                if((string)snapshot.GetProperty("Sha256").GetValue(after)!=(string)snapshot.GetProperty("Sha256").GetValue(target))throw new IOException("Synthetic exact descriptor verification failed");
            }
            public void Dispose(){handle.Dispose();}
        }
        public static CandidateTransaction OpenCandidate(object owningLease) => new CandidateTransaction(owningLease);
    }
}

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
        [StructLayout(LayoutKind.Sequential)] struct GenericMapping {public uint Read,Write,Execute,All;}
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool DuplicateToken(IntPtr existing,int level,out IntPtr copy);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool AccessCheck(IntPtr descriptor,IntPtr token,uint access,ref GenericMapping mapping,IntPtr privileges,ref uint bytes,out uint granted,out bool allowed);
        public bool AllowedByDacl(byte[] descriptor,uint access) {
            if(!active || descriptor==null || descriptor.Length<20 || descriptor.Length>65536 || access==0 || (access&~0x1f01ffu)!=0)throw new IOException("Active restricted token and bounded specific filesystem access required");
            IntPtr copy=IntPtr.Zero,sd=IntPtr.Zero,privileges=IntPtr.Zero;
            try {
                if(!DuplicateToken(token,2,out copy))throw new Win32Exception(Marshal.GetLastWin32Error());
                sd=Marshal.AllocHGlobal(descriptor.Length);Marshal.Copy(descriptor,0,sd,descriptor.Length);
                uint bytes=1024;privileges=Marshal.AllocHGlobal((int)bytes);
                var mapping=new GenericMapping {Read=0x120089,Write=0x120116,Execute=0x1200a0,All=0x1f01ff};
                if(!AccessCheck(sd,copy,access,ref mapping,privileges,ref bytes,out var granted,out var allowed))throw new Win32Exception(Marshal.GetLastWin32Error());
                return allowed && (granted&access)==access;
            } finally {if(copy!=IntPtr.Zero)CloseHandle(copy);if(privileges!=IntPtr.Zero)Marshal.FreeHGlobal(privileges);if(sd!=IntPtr.Zero)Marshal.FreeHGlobal(sd);}
        }
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

// Test-only readonly metadata observation. Constrained mutation and fresh
// synthetic authority now live in the maintained owning runtime primitive.
namespace Revealfleet.Tests {
    public static class SyntheticSecurityLab {
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
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
    }
}

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

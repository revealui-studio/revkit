// Windows-only mechanics. Caller must supply authoritative reviewed registry binding.
// Construction opens a source: it must occur ONLY after production admission.
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
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
        public ColdSourceLease(string reviewedCanonicalPath,string reviewedFileIdentity) {
            if(!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Windows source lease required");
            if(String.IsNullOrWhiteSpace(reviewedCanonicalPath) || reviewedCanonicalPath.Length<4 ||
                reviewedCanonicalPath[1]!=':' || reviewedCanonicalPath[2]!='\\' ||
                !String.Equals(Path.GetFullPath(reviewedCanonicalPath),reviewedCanonicalPath,StringComparison.OrdinalIgnoreCase) ||
                reviewedCanonicalPath.IndexOf(':',2)>=0 || String.IsNullOrWhiteSpace(reviewedFileIdentity))
                throw new ArgumentException("Reviewed local canonical path and file identity required");
            if(!String.Equals(new DriveInfo(Path.GetPathRoot(reviewedCanonicalPath)).DriveFormat,"NTFS",StringComparison.OrdinalIgnoreCase))
                throw new IOException("NTFS source required");
            path=reviewedCanonicalPath; NoReparse(path);
            stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read,65536,FileOptions.Asynchronous|FileOptions.SequentialScan);
            try {
                if(!GetFileInformationByHandle(stream.SafeFileHandle,out identity)) throw new Win32Exception(Marshal.GetLastWin32Error());
                if((identity.Attributes & (uint)(FileAttributes.Directory|FileAttributes.ReparsePoint))!=0 || identity.Links!=1 || Length<=0 ||
                    !String.Equals(Final(stream.SafeFileHandle),path,StringComparison.OrdinalIgnoreCase) ||
                    !String.Equals(FileIdentity,reviewedFileIdentity,StringComparison.Ordinal)) throw new IOException("Source handle identity mismatch");
                NoReparse(path);
            } catch { stream.Dispose(); throw; }
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
}

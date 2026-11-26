// Root OWNER+DACL transaction primitives. No discovery, traversal or activation.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace Revealfleet.Backup {
    public sealed class ColdRootGrant {
        public string Sid {get;set;}
        public uint Mask {get;set;}
        public byte Flags {get;set;}
        public ColdRootGrant(string sid,uint mask,byte flags) {Sid=sid;Mask=mask;Flags=flags;}
    }
    public static class ColdRootPolicy {
        public const uint Full=0x1f01ff, SafeRoot=0x1200af, Dangerous=0xd0040;
        public static ColdRootGrant[] Restrict(ColdRootGrant[] grants,string user) {
            if(grants==null || grants.Length==0 || grants.Length>64 || String.IsNullOrWhiteSpace(user)) throw new ArgumentException("Bounded explicit root ACL required");
            var result=new List<ColdRootGrant>();
            foreach(var g in grants) {
                if(g==null || (g.Flags & ~11)!=0 || ((g.Flags&8)!=0 && (g.Flags&3)==0) || g.Mask==0 || (g.Mask & ~Full)!=0 ||
                   (g.Sid!="S-1-1-0" && g.Sid!="S-1-3-0" && g.Sid!="S-1-5-18" && g.Sid!="S-1-5-32-544" && g.Sid!=user))
                    throw new ArgumentException("Unknown root ACE form/principal/rights");
                if(g.Sid=="S-1-3-0") {
                    if((g.Flags&3)==0)throw new ArgumentException("CREATOR OWNER must be an inheritance template");
                    // The generic SID maps on inheritance. Preserve that exact
                    // template; the new concrete Admin owner has its own grant.
                    result.Add(new ColdRootGrant(g.Sid,g.Mask,(byte)(g.Flags|8)));continue;
                }
                if((g.Flags&8)!=0 || g.Sid=="S-1-5-18" || g.Sid=="S-1-5-32-544") result.Add(new ColdRootGrant(g.Sid,g.Mask,g.Flags));
                else {
                    if((g.Flags&3)!=0) result.Add(new ColdRootGrant(g.Sid,g.Mask,(byte)(g.Flags|8)));
                    uint effective=g.Mask & SafeRoot;
                    if(effective!=0) result.Add(new ColdRootGrant(g.Sid,effective,0));
                }
            }
            // Root-only trusted grants do not change any child template.
            foreach(string sid in new[]{"S-1-5-18","S-1-5-32-544"})
                result.Add(new ColdRootGrant(sid,Full,0));
            return result.ToArray();
        }
    }
    public sealed class ColdSecuritySnapshot {
        public string DescriptorBase64 {get;private set;}
        public string OwnerBase64 {get;private set;}
        public string DaclBase64 {get;private set;}
        public string GroupBase64 {get;private set;}
        public string OwnerSid {get;private set;}
        public int Control {get;private set;}
        public string Sha256 {get;private set;}
        public ColdSecuritySnapshot(byte[] bytes) {
            var sd=new RawSecurityDescriptor(bytes,0);
            if(bytes.Length>65536 || sd.Owner==null || sd.Group==null || sd.DiscretionaryAcl==null || sd.SystemAcl!=null ||
               (sd.ControlFlags & ~(ControlFlags.SelfRelative|ControlFlags.DiscretionaryAclPresent|ControlFlags.DiscretionaryAclProtected|ControlFlags.DiscretionaryAclAutoInherited|ControlFlags.GroupDefaulted))!=0)
                throw new IOException("Unknown/null descriptor or control form");
            int offset=BitConverter.ToInt32(bytes,16);
            if(offset<20 || offset+8>bytes.Length) throw new IOException("DACL offset refused");
            int length=BitConverter.ToUInt16(bytes,offset+2);
            if(length<8 || offset+length>bytes.Length) throw new IOException("DACL bound refused");
            byte[] owner=new byte[sd.Owner.BinaryLength],group=new byte[sd.Group.BinaryLength];
            sd.Owner.GetBinaryForm(owner,0);sd.Group.GetBinaryForm(group,0);
            DescriptorBase64=Convert.ToBase64String(bytes);OwnerBase64=Convert.ToBase64String(owner);GroupBase64=Convert.ToBase64String(group);
            DaclBase64=Convert.ToBase64String(bytes,offset,length);OwnerSid=sd.Owner.Value;Control=(int)sd.ControlFlags;
            Sha256=Convert.ToHexString(SHA256.HashData(Encoding.ASCII.GetBytes(Control.ToString(System.Globalization.CultureInfo.InvariantCulture)+":"+OwnerBase64+":"+GroupBase64+":"+DaclBase64))).ToLowerInvariant();
        }
        public ColdSecuritySnapshot WithOwner(string sid) {
            var sd=new RawSecurityDescriptor(Convert.FromBase64String(DescriptorBase64),0);sd.Owner=new SecurityIdentifier(sid);
            byte[] bytes=new byte[sd.BinaryLength];sd.GetBinaryForm(bytes,0);return new ColdSecuritySnapshot(bytes);
        }
        public ColdSecuritySnapshot Restricted(string user) {
            var sd=new RawSecurityDescriptor(Convert.FromBase64String(DescriptorBase64),0);
            var grants=new List<ColdRootGrant>();
            foreach(GenericAce item in sd.DiscretionaryAcl) {
                var ace=item as CommonAce;
                if(ace==null || ace.IsCallback || ace.OpaqueLength!=0 || ace.AceQualifier!=AceQualifier.AccessAllowed) throw new IOException("Only standard allow root ACEs supported");
                grants.Add(new ColdRootGrant(ace.SecurityIdentifier.Value,unchecked((uint)ace.AccessMask),(byte)ace.AceFlags));
            }
            var selected=ColdRootPolicy.Restrict(grants.ToArray(),user);
            var acl=new RawAcl(sd.DiscretionaryAcl.Revision,selected.Length);
            foreach(var g in selected) acl.InsertAce(acl.Count,new CommonAce((AceFlags)g.Flags,AceQualifier.AccessAllowed,checked((int)g.Mask),new SecurityIdentifier(g.Sid),false,null));
            var target=new RawSecurityDescriptor(sd.ControlFlags,new SecurityIdentifier("S-1-5-32-544"),sd.Group,null,acl);
            byte[] bytes=new byte[target.BinaryLength];target.GetBinaryForm(bytes,0);
            return new ColdSecuritySnapshot(bytes);
        }
    }
    // Privilege is enabled only on a duplicate impersonation token for this
    // synchronous thread, never the process/account. Original context restored.
    public sealed class ColdRestorePrivilege : IDisposable {
        [StructLayout(LayoutKind.Sequential)] struct Luid {public uint Low;public int High;}
        [StructLayout(LayoutKind.Sequential)] struct TokenPrivilege {public uint Count;public Luid Id;public uint Attributes;}
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr h);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenThreadToken(IntPtr thread,uint access,bool self,out IntPtr token);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool DuplicateTokenEx(IntPtr token,uint access,IntPtr attributes,int level,int type,out IntPtr copy);
        [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool LookupPrivilegeValue(string system,string name,out Luid id);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token,bool disable,ref TokenPrivilege value,int size,IntPtr previous,IntPtr length);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool ImpersonateLoggedOnUser(IntPtr token);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool RevertToSelf();
        IntPtr token; bool active; readonly int thread;
        public ColdRestorePrivilege() {
            if(!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
            if(!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) throw new IOException("Elevated administrator required");
            if(OpenThreadToken(GetCurrentThread(),8,true,out var prior)) {CloseHandle(prior);throw new IOException("Existing impersonation context refused");}
            if(Marshal.GetLastWin32Error()!=1008) throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr original=IntPtr.Zero;thread=Environment.CurrentManagedThreadId;
            try {
                if(!OpenProcessToken(GetCurrentProcess(),10,out original) || !DuplicateTokenEx(original,44,IntPtr.Zero,2,2,out token) || !LookupPrivilegeValue(null,"SeRestorePrivilege",out var id)) throw new Win32Exception(Marshal.GetLastWin32Error());
                var privilege=new TokenPrivilege {Count=1,Id=id,Attributes=2};
                if(!AdjustTokenPrivileges(token,false,ref privilege,0,IntPtr.Zero,IntPtr.Zero) || Marshal.GetLastWin32Error()!=0) throw new IOException("SeRestorePrivilege unavailable; no mutation admitted");
                if(!ImpersonateLoggedOnUser(token)) throw new Win32Exception(Marshal.GetLastWin32Error());
                active=true;
            } catch {if(token!=IntPtr.Zero)CloseHandle(token);token=IntPtr.Zero;throw;}
            finally {if(original!=IntPtr.Zero)CloseHandle(original);}
        }
        public void Dispose() {
            if(active) {
                if(thread!=Environment.CurrentManagedThreadId || !RevertToSelf()) throw new IOException("Privilege context restore unconfirmed; stop this process");
                active=false;
            }
            if(token!=IntPtr.Zero){CloseHandle(token);token=IntPtr.Zero;}
        }
    }
    public sealed class ColdDirectorySecurityLease : IDisposable {
        [StructLayout(LayoutKind.Sequential)] struct Info {public uint Attributes;public System.Runtime.InteropServices.ComTypes.FILETIME Created,Accessed,Written;public uint Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;}
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle h,out Info info);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandleW(SafeFileHandle h,StringBuilder text,uint length,uint flags);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetVolumeInformationByHandleW(SafeFileHandle h,StringBuilder name,uint size,out uint serial,out uint maximum,out uint flags,StringBuilder filesystem,uint fsSize);
        [DllImport("advapi32.dll",SetLastError=true)] static extern uint GetSecurityInfo(SafeFileHandle handle,int type,uint selection,out IntPtr owner,out IntPtr group,out IntPtr dacl,out IntPtr sacl,out IntPtr descriptor);
        [DllImport("advapi32.dll",SetLastError=true)] static extern uint GetSecurityDescriptorLength(IntPtr descriptor);
        [DllImport("advapi32.dll",SetLastError=true)] static extern uint SetSecurityInfo(SafeFileHandle handle,int type,uint selection,IntPtr owner,IntPtr group,IntPtr dacl,IntPtr sacl);
        [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr pointer);
        readonly SafeFileHandle handle;readonly Info identity;readonly string path;readonly bool observationOnly;
        public string FileIdentity => identity.Volume.ToString("x8")+":"+identity.IndexHigh.ToString("x8")+identity.IndexLow.ToString("x8");
        public uint Attributes => identity.Attributes;
        public string CanonicalPath => path;
        public ColdDirectorySecurityLease(string canonicalPath) : this(canonicalPath,false) { }
        private ColdDirectorySecurityLease(string canonicalPath,bool metadataObservation) {
            observationOnly=metadataObservation;
            if(!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
            path=Path.GetFullPath(canonicalPath);
            if(path.Length<3 || path[1]!=':' || !String.Equals(path,canonicalPath,StringComparison.Ordinal)) throw new IOException("Canonical local directory required");
            // EXACT MAXIMUM_ALLOWED: documented SetSecurityInfo no-propagation.
            // Keep metadata reads/writes shared; withhold DELETE sharing.
            handle=CreateFileW(path,metadataObservation ? 0x00020080u : 0x02000000u,metadataObservation ? 7u : 3u,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
            try {
                if(handle.IsInvalid || !GetFileInformationByHandle(handle,out identity) || (identity.Attributes & 0x410)!=0x10) throw new IOException("Directory/reparse handle refused");
                var fs=new StringBuilder(64);
                if(!GetVolumeInformationByHandleW(handle,new StringBuilder(256),256,out var serial,out var max,out var flags,fs,64) || fs.ToString()!="NTFS") throw new IOException("NTFS handle required");
                ValidateIdentity();
            } catch {handle.Dispose();throw;}
        }
        public void ValidateIdentity() {
            var name=new StringBuilder(32768);uint count=GetFinalPathNameByHandleW(handle,name,(uint)name.Capacity,0);
            if(count==0 || count>=name.Capacity || name.ToString()!=@"\\?\"+path || !GetFileInformationByHandle(handle,out var now) || now.Volume!=identity.Volume || now.IndexHigh!=identity.IndexHigh || now.IndexLow!=identity.IndexLow || now.Attributes!=identity.Attributes) throw new IOException("Held directory identity/alias/attributes changed");
            // Reopen by canonical name as well; a still-held detached name is not
            // proof that the namespace still resolves to this volume/root.
            // FILE_READ_ATTRIBUTES only. Share DELETE too so this observer
            // coexists with the retained MAXIMUM_ALLOWED/no-delete-share handle.
            using var named=CreateFileW(path,0x80,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
            if(named.IsInvalid || !GetFileInformationByHandle(named,out var found) || found.Volume!=identity.Volume || found.IndexHigh!=identity.IndexHigh || found.IndexLow!=identity.IndexLow || found.Attributes!=identity.Attributes) throw new IOException("Named root substitution/disconnect refused");
        }
        public ColdSecuritySnapshot Read() {
            ValidateIdentity();
            uint error=GetSecurityInfo(handle,1,7,out var owner,out var group,out var dacl,out var sacl,out var descriptor);
            if(error!=0)throw new Win32Exception((int)error);
            try {uint size=GetSecurityDescriptorLength(descriptor);if(size<20 || size>65536)throw new IOException("Descriptor bounds");byte[] bytes=new byte[size];Marshal.Copy(descriptor,bytes,0,(int)size);return new ColdSecuritySnapshot(bytes);}
            finally {LocalFree(descriptor);}
        }
        public static ColdSecuritySnapshot ObserveForReceipt(string canonicalPath) {
            // READ_CONTROL + attributes, fully shared: never another DELETE-
            // requesting custody lease. No mutation is exposed on this handle.
            using var observer=new ColdDirectorySecurityLease(canonicalPath,true);
            return observer.Read();
        }
        public void Replace(string expectedSha256,string targetDescriptorBase64) {
            if(observationOnly)throw new IOException("Receipt observer cannot mutate security");
            var current=Read();
            if(current.Sha256!=expectedSha256)throw new IOException("Owner/DACL/control/group drift; nothing replaced");
            var bytes=Convert.FromBase64String(targetDescriptorBase64);var target=new ColdSecuritySnapshot(bytes);
            if(target.Control!=current.Control || target.GroupBase64!=current.GroupBase64)throw new IOException("Group/control changes are outside OWNER+DACL transaction scope");
            IntPtr buffer=Marshal.AllocHGlobal(bytes.Length);
            try {
                Marshal.Copy(bytes,0,buffer,bytes.Length);
                int ownerOffset=BitConverter.ToInt32(bytes,4),daclOffset=BitConverter.ToInt32(bytes,16);
                if(ownerOffset<20 || daclOffset<20)throw new IOException("Explicit owner/DACL required");
                // OWNER+DACL ONLY. Group/SACL/attributes never selected. Preserve
                // original DACL protection state: do NOT request protected or
                // unprotected transitions. MAXIMUM_ALLOWED suppresses propagation.
                uint selection=5;
                uint error=SetSecurityInfo(handle,1,selection,IntPtr.Add(buffer,ownerOffset),IntPtr.Zero,IntPtr.Add(buffer,daclOffset),IntPtr.Zero);
                if(error!=0)throw new Win32Exception((int)error);
                var observed=Read();
                if(observed.Sha256!=target.Sha256)throw new IOException("Applied descriptor/control verification failed; retain evidence, no automatic rollback");
            } finally {Marshal.FreeHGlobal(buffer);}
        }
        [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes {public uint Length;public IntPtr Descriptor;public int Inherit;}
        public static void CopyNewProtectedFile(string source,string destination,byte[] descriptor) {
            if(!OperatingSystem.IsWindows())throw new PlatformNotSupportedException();
            IntPtr sd=Marshal.AllocHGlobal(descriptor.Length),attributes=IntPtr.Zero;
            try {
                Marshal.Copy(descriptor,0,sd,descriptor.Length);
                var value=new SecurityAttributes {Length=(uint)Marshal.SizeOf<SecurityAttributes>(),Descriptor=sd,Inherit=0};
                attributes=Marshal.AllocHGlobal((int)value.Length);Marshal.StructureToPtr(value,attributes,false);
                using var output=CreateFileW(destination,0x40000000,1,attributes,1,0x80,IntPtr.Zero);
                if(output.IsInvalid)throw new Win32Exception(Marshal.GetLastWin32Error());
                using var file=new FileStream(output,FileAccess.Write,65536,false);
                using var input=new FileStream(source,FileMode.Open,FileAccess.Read,FileShare.Read);
                input.CopyTo(file,65536);file.Flush(true);
            } finally {if(attributes!=IntPtr.Zero)Marshal.FreeHGlobal(attributes);Marshal.FreeHGlobal(sd);}
        }
        public void Dispose(){handle.Dispose();}
    }
}

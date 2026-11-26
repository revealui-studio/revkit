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
        // Only IO representation may change: OI/CI, inherited marker, SID,
        // specific rights and inheritable order stay exact. Generic CREATOR
        // OWNER remains generic for mapping at the child's creation, never to
        // the current parent owner. No deny/object/callback/NP/generic rights.
        public static ColdRootGrant[] ChildInheritance(ColdRootGrant[] grants) {
            if(grants==null || grants.Length==0 || grants.Length>192)throw new ArgumentException("Bounded inheritance grammar required");
            var rows=new List<ColdRootGrant>();
            foreach(var g in grants) {
                if(g==null || String.IsNullOrWhiteSpace(g.Sid) || g.Sid.Length>184 || (g.Flags & ~27)!=0 ||
                   ((g.Flags&8)!=0 && (g.Flags&3)==0) || g.Mask==0 || (g.Mask & ~Full)!=0)
                    throw new ArgumentException("Unsupported child-inheritance ACE form");
                if((g.Flags&3)!=0)rows.Add(new ColdRootGrant(g.Sid,g.Mask,(byte)(g.Flags&~8)));
            }
            return rows.ToArray();
        }
        public static string ChildInheritanceHash(ColdRootGrant[] grants) {
            using var output=new MemoryStream();
            using(var writer=new BinaryWriter(output,Encoding.UTF8,true)) {
                writer.Write("unchanged-child-inheritance-v1");
                var rows=ChildInheritance(grants);writer.Write(rows.Length);
                foreach(var row in rows){writer.Write(row.Sid);writer.Write(row.Mask);writer.Write(row.Flags);}
            }
            return Convert.ToHexString(SHA256.HashData(output.ToArray())).ToLowerInvariant();
        }
        public static void RequireSameChildInheritance(ColdRootGrant[] before,ColdRootGrant[] after) {
            var a=ChildInheritance(before);var b=ChildInheritance(after);
            if(a.Length!=b.Length)throw new IOException("Changed child inheritance refused BEFORE mutation");
            for(int i=0;i<a.Length;i++)if(a[i].Sid!=b[i].Sid || a[i].Mask!=b[i].Mask || a[i].Flags!=b[i].Flags)
                throw new IOException("Changed child inheritance refused BEFORE mutation");
        }
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
    // Raw self-relative layout, independent of Windows account resolution.
    // Never replace AclSize with the parsed ACE size or drop spare/tail bytes.
    public sealed class ColdSecurityLayout {
        public int DescriptorBytes {get;private set;}
        public int OwnerOffset {get;private set;} public int OwnerBytes {get;private set;}
        public int GroupOffset {get;private set;} public int GroupBytes {get;private set;}
        public int DaclOffset {get;private set;} public int AclBytes {get;private set;}
        public int ParsedAclBytes {get;private set;} public int SpareBytes => AclBytes-ParsedAclBytes;
        public int TrailingBytes {get;private set;} public byte AclRevision {get;private set;}
        public int AceCount {get;private set;}
        static int SidLength(byte[] data,int offset) {
            if(offset<20 || offset+8>data.Length || data[offset]!=1 || data[offset+1]>15)throw new IOException("SID layout refused");
            int length=8+4*data[offset+1];if(offset+length>data.Length)throw new IOException("SID bound refused");return length;
        }
        public static ColdSecurityLayout Inspect(byte[] data) {
            if(data==null || data.Length<28 || data.Length>65536 || data[0]!=1 || data[1]!=0 || (BitConverter.ToUInt16(data,2)&0x8004)!=0x8004 || BitConverter.ToUInt32(data,12)!=0)throw new IOException("Relative descriptor header refused");
            var r=new ColdSecurityLayout {DescriptorBytes=data.Length,OwnerOffset=checked((int)BitConverter.ToUInt32(data,4)),GroupOffset=checked((int)BitConverter.ToUInt32(data,8)),DaclOffset=checked((int)BitConverter.ToUInt32(data,16))};
            r.OwnerBytes=SidLength(data,r.OwnerOffset);r.GroupBytes=SidLength(data,r.GroupOffset);
            if(r.OwnerOffset!=20 || r.GroupOffset!=20+r.OwnerBytes || r.DaclOffset!=r.GroupOffset+r.GroupBytes || r.DaclOffset+8>data.Length)throw new IOException("Unsupported descriptor component order/gap/overlap");
            int d=r.DaclOffset;r.AclRevision=data[d];r.AclBytes=BitConverter.ToUInt16(data,d+2);r.AceCount=BitConverter.ToUInt16(data,d+4);
            if((r.AclRevision!=2 && r.AclRevision!=4) || data[d+1]!=0 || data[d+6]!=0 || data[d+7]!=0 || r.AclBytes<8 || r.AclBytes%4!=0 || d+r.AclBytes>data.Length || r.AceCount>192)throw new IOException("ACL header/capacity refused");
            int at=d+8;
            for(int i=0;i<r.AceCount;i++) {
                if(at+4>d+r.AclBytes)throw new IOException("ACE header exceeds AclSize");
                int size=BitConverter.ToUInt16(data,at+2);
                if(size<4 || size%4!=0 || at+size>d+r.AclBytes)throw new IOException("ACE exceeds AclSize");at+=size;
            }
            r.ParsedAclBytes=at-d;r.TrailingBytes=data.Length-d-r.AclBytes;
            for(int i=at;i<data.Length;i++)if(data[i]!=0)throw new IOException("Nonzero spare/trailing bytes unsupported; never canonicalized");
            return r;
        }
        public void RequireWritable() {
            if(TrailingBytes!=0)throw new IOException("Outer descriptor trailing bytes lack a round-trip contract");
        }
        public static byte[] Compose(ushort control,byte[] owner,byte[] group,byte[] compactAcl,int minimumCapacity,byte[] tail) {
            if(owner==null || group==null || compactAcl==null || compactAcl.Length<8 || minimumCapacity<8)throw new IOException("Raw components required");
            int capacity=Math.Max(minimumCapacity,compactAcl.Length);
            if(capacity>65532 || capacity%4!=0)throw new IOException("ACL capacity bound");
            int d=20+owner.Length+group.Length;var data=new byte[checked(d+capacity+(tail?.Length??0))];
            if(data.Length>65536)throw new IOException("Descriptor size bound");
            data[0]=1;BitConverter.GetBytes(control).CopyTo(data,2);BitConverter.GetBytes(20).CopyTo(data,4);
            BitConverter.GetBytes(20+owner.Length).CopyTo(data,8);BitConverter.GetBytes(d).CopyTo(data,16);
            owner.CopyTo(data,20);group.CopyTo(data,20+owner.Length);compactAcl.CopyTo(data,d);
            BitConverter.GetBytes((ushort)capacity).CopyTo(data,d+2);if(tail!=null)tail.CopyTo(data,d+capacity);
            Inspect(data);return data;
        }
    }
    public sealed class ColdSecuritySnapshot {
        public ColdSecurityLayout Layout {get;private set;}
        public string DescriptorSha256 {get;private set;}
        public string DescriptorBase64 {get;private set;}
        public string OwnerBase64 {get;private set;}
        public string DaclBase64 {get;private set;}
        public string GroupBase64 {get;private set;}
        public string OwnerSid {get;private set;}
        public int Control {get;private set;}
        public string Sha256 {get;private set;}
        public ColdSecuritySnapshot(byte[] bytes) {
            Layout=ColdSecurityLayout.Inspect(bytes);DescriptorSha256=Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
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
            var owner=new SecurityIdentifier(sid);var bytes=new byte[owner.BinaryLength];owner.GetBinaryForm(bytes,0);
            byte[] raw=Convert.FromBase64String(DescriptorBase64),tail=new byte[Layout.TrailingBytes];
            Array.Copy(raw,raw.Length-tail.Length,tail,0,tail.Length);
            return new ColdSecuritySnapshot(ColdSecurityLayout.Compose((ushort)Control,bytes,Convert.FromBase64String(GroupBase64),Convert.FromBase64String(DaclBase64),Layout.AclBytes,tail));
        }
        ColdRootGrant[] Grants() {
            var sd=new RawSecurityDescriptor(Convert.FromBase64String(DescriptorBase64),0);
            var grants=new List<ColdRootGrant>();
            foreach(GenericAce item in sd.DiscretionaryAcl) {
                var ace=item as CommonAce;
                if(ace==null || ace.IsCallback || ace.OpaqueLength!=0 || ace.AceQualifier!=AceQualifier.AccessAllowed) throw new IOException("Only standard allow root ACEs supported");
                grants.Add(new ColdRootGrant(ace.SecurityIdentifier.Value,unchecked((uint)ace.AccessMask),(byte)ace.AceFlags));
            }
            return grants.ToArray();
        }
        public string ChildInheritanceSha256 => ColdRootPolicy.ChildInheritanceHash(Grants());
        public void RequireReplacementScope(ColdSecuritySnapshot target) {
            Layout.RequireWritable();target?.Layout.RequireWritable();
            if(target==null || target.Control!=Control || target.GroupBase64!=GroupBase64)
                throw new IOException("Group/control changes are outside OWNER+DACL scope");
            if(Convert.FromBase64String(DaclBase64)[0]!=Convert.FromBase64String(target.DaclBase64)[0])throw new IOException("ACL revision transition refused");
            ColdRootPolicy.RequireSameChildInheritance(Grants(),target.Grants());
        }
        public ColdSecuritySnapshot Restricted(string user) {
            var sd=new RawSecurityDescriptor(Convert.FromBase64String(DescriptorBase64),0);
            var grants=Grants();
            var selected=ColdRootPolicy.Restrict(grants,user);
            var acl=new RawAcl(sd.DiscretionaryAcl.Revision,selected.Length);
            foreach(var g in selected) acl.InsertAce(acl.Count,new CommonAce((AceFlags)g.Flags,AceQualifier.AccessAllowed,checked((int)g.Mask),new SecurityIdentifier(g.Sid),false,null));
            byte[] dacl=new byte[acl.BinaryLength];acl.GetBinaryForm(dacl,0);
            var admin=new SecurityIdentifier("S-1-5-32-544");byte[] owner=new byte[admin.BinaryLength];admin.GetBinaryForm(owner,0);
            var result=new ColdSecuritySnapshot(ColdSecurityLayout.Compose((ushort)Control,owner,Convert.FromBase64String(GroupBase64),dacl,Layout.AclBytes,null));
            RequireReplacementScope(result);return result;
        }
    }
    // Candidate ONLY. Raw input is never rewritten or supplied to a setter in
    // compacted form. The identity omits precisely AclSize and validated zero
    // unused allocation; every header/control/owner/group/ordered ACE byte stays.
    public sealed class ColdPermissionIdentity {
        public const string Profile="permission-ace-zero-unused-v1";
        readonly byte[] usedIdentity;
        public string RawSha256 {get;private set;}
        public string UsedIdentitySha256 {get;private set;}
        public ColdSecurityLayout Layout {get;private set;}
        public ColdPermissionIdentity(byte[] input) {
            var data=input==null?null:(byte[])input.Clone();Layout=ColdSecurityLayout.Inspect(data);Layout.RequireWritable();
            ushort control=BitConverter.ToUInt16(data,2);
            if((control & ~0x9406)!=0 || Layout.AceCount==0)throw new IOException("Candidate supports bounded nonempty OWNER/GROUP/DACL only; control/SACL/empty forms refused");
            int at=Layout.DaclOffset+8;
            for(int i=0;i<Layout.AceCount;i++) {
                int size=BitConverter.ToUInt16(data,at+2);
                if(data[at]!=0 || (data[at+1]&~27)!=0 || ((data[at+1]&8)!=0 && (data[at+1]&3)==0) || size<16)
                    throw new IOException("Candidate supports standard allow ACEs only; object/callback/audit/opaque flags refused");
                uint mask=BitConverter.ToUInt32(data,at+4);int sid=at+8;
                if(mask==0 || (mask & ~ColdRootPolicy.Full)!=0 || data[sid]!=1 || data[sid+1]>15 || size!=16+4*data[sid+1])
                    throw new IOException("Candidate ACE mask/SID/exact-size grammar refused");
                at+=size;
            }
            RawSha256=Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
            using var bytes=new MemoryStream();using(var writer=new BinaryWriter(bytes,Encoding.UTF8,true)) {
                writer.Write(Profile);writer.Write(data,0,Layout.DaclOffset);
                // Preserve revision/reserved/count and ordered ACE bytes; only
                // these two size bytes describe the excluded zero free area.
                int d=Layout.DaclOffset;writer.Write(data[d]);writer.Write(data[d+1]);writer.Write((ushort)Layout.ParsedAclBytes);
                writer.Write(data,d+4,Layout.ParsedAclBytes-4);
            }
            usedIdentity=bytes.ToArray();UsedIdentitySha256=Convert.ToHexString(SHA256.HashData(usedIdentity)).ToLowerInvariant();
        }
        public static void RequireRawCas(byte[] current,string expectedRawSha256) {
            // Forensic identity is independent of permission equivalence. The
            // initial fresh-volume descriptor may have a broader default ACL;
            // seed does not compare its permissions with the requested seed.
            if(current==null || current.Length<20 || current.Length>65536 || Convert.ToHexString(SHA256.HashData(current)).ToLowerInvariant()!=expectedRawSha256)
                throw new IOException("Candidate full raw CAS drift; no mutation admitted, even if permissions match");
        }
        public static ColdPermissionDelta Compare(byte[] requested,byte[] observed) {
            var a=new ColdPermissionIdentity(requested);var b=new ColdPermissionIdentity(observed);
            if(!CryptographicOperations.FixedTimeEquals(a.usedIdentity,b.usedIdentity))throw new IOException("Candidate meaningful header/control/owner/group/ordered ACE identity differs");
            return new ColdPermissionDelta {Profile=Profile,Classification=a.RawSha256==b.RawSha256?"ExactRaw":"ValidatedZeroUnusedAclCapacityOnly",RawEqual=a.RawSha256==b.RawSha256,RequestedRawSha256=a.RawSha256,ObservedRawSha256=b.RawSha256,UsedIdentitySha256=a.UsedIdentitySha256,RequestedAclBytes=a.Layout.AclBytes,ObservedAclBytes=b.Layout.AclBytes,AclBytesInUse=a.Layout.ParsedAclBytes};
        }
    }
    public sealed class ColdPermissionDelta {
        public string Profile {get;internal set;} public string Classification {get;internal set;}
        public bool RawEqual {get;internal set;} public bool RawByteRestorationPromised => false;
        public string RequestedRawSha256 {get;internal set;} public string ObservedRawSha256 {get;internal set;}
        public string UsedIdentitySha256 {get;internal set;}
        public int RequestedAclBytes {get;internal set;} public int ObservedAclBytes {get;internal set;} public int AclBytesInUse {get;internal set;}
    }
    public sealed class ColdPermissionChangeEvidence {
        public string Profile => ColdPermissionIdentity.Profile;
        public ColdSecuritySnapshot Before {get;internal set;} public ColdSecuritySnapshot Requested {get;internal set;} public ColdSecuritySnapshot Observed {get;internal set;}
        public ColdPermissionDelta Delta {get;internal set;}
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
        public ColdRestorePrivilege() : this(new[]{"SeRestorePrivilege"}) { }
        internal static ColdRestorePrivilege SyntheticVolumeScope() => new ColdRestorePrivilege(new[]{"SeRestorePrivilege","SeManageVolumePrivilege"});
        private ColdRestorePrivilege(string[] required) {
            if(!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
            if(!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)) throw new IOException("Elevated administrator required");
            if(OpenThreadToken(GetCurrentThread(),8,true,out var prior)) {CloseHandle(prior);throw new IOException("Existing impersonation context refused");}
            if(Marshal.GetLastWin32Error()!=1008) throw new Win32Exception(Marshal.GetLastWin32Error());
            IntPtr original=IntPtr.Zero;thread=Environment.CurrentManagedThreadId;
            try {
                if(!OpenProcessToken(GetCurrentProcess(),10,out original) || !DuplicateTokenEx(original,44,IntPtr.Zero,2,2,out token)) throw new Win32Exception(Marshal.GetLastWin32Error());
                foreach(string name in required) {
                    if(!LookupPrivilegeValue(null,name,out var id))throw new Win32Exception(Marshal.GetLastWin32Error());
                    var privilege=new TokenPrivilege {Count=1,Id=id,Attributes=2};
                    if(!AdjustTokenPrivileges(token,false,ref privilege,0,IntPtr.Zero,IntPtr.Zero) || Marshal.GetLastWin32Error()!=0)throw new IOException(name+" unavailable; no mutation admitted");
                }
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
        [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr pointer);
        readonly SafeFileHandle handle;readonly Info identity;readonly string path;readonly bool observationOnly;readonly uint nameFlags;readonly string finalName;
        public string FileIdentity => identity.Volume.ToString("x8")+":"+identity.IndexHigh.ToString("x8")+identity.IndexLow.ToString("x8");
        public uint Attributes => identity.Attributes;
        public int NativeMutationCalls {get;private set;}
        public string CanonicalPath => path;
        public ColdDirectorySecurityLease(string canonicalPath) : this(canonicalPath,false) { }
        private ColdDirectorySecurityLease(string canonicalPath,bool metadataObservation) {
            observationOnly=metadataObservation;
            if(!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
            path=Path.GetFullPath(canonicalPath);finalName=@"\\?\"+path;
            if(path.Length<3 || path[1]!=':' || !String.Equals(path,canonicalPath,StringComparison.Ordinal)) throw new IOException("Canonical local directory required");
            // Retain MAXIMUM_ALLOWED/no-delete-share custody. Descriptor mutation
            // is blocked: actual Windows disproved the SetSecurityInfo contract.
            // Keep metadata reads/writes shared; withhold DELETE sharing.
            handle=CreateFileW(path,metadataObservation ? 0x00020080u : 0x02000000u,metadataObservation ? 7u : 3u,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
            try {
                if(handle.IsInvalid || !GetFileInformationByHandle(handle,out identity) || (identity.Attributes & 0x410)!=0x10) throw new IOException("Directory/reparse handle refused");
                var fs=new StringBuilder(64);
                if(!GetVolumeInformationByHandleW(handle,new StringBuilder(256),256,out var serial,out var max,out var flags,fs,64) || fs.ToString()!="NTFS") throw new IOException("NTFS handle required");
                ValidateIdentity();
            } catch {handle.Dispose();throw;}
        }
        internal ColdDirectorySecurityLease(ColdSyntheticVirtualDisk owned) {
            owned.ValidateVolume();path=owned.VolumeRoot;finalName=path;nameFlags=1;
            handle=CreateFileW(path,0x02000000,3,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
            try {if(handle.IsInvalid || !GetFileInformationByHandle(handle,out identity) || (identity.Attributes&0x410)!=0x10)throw new IOException("Owned NTFS root handle refused");
                var fs=new StringBuilder(64);if(!GetVolumeInformationByHandleW(handle,new StringBuilder(256),256,out var serial,out var max,out var flags,fs,64) || fs.ToString()!="NTFS")throw new IOException("Owned volume is not NTFS");ValidateIdentity();}
            catch {handle.Dispose();throw;}
        }
        public void ValidateIdentity() {
            var name=new StringBuilder(32768);uint count=GetFinalPathNameByHandleW(handle,name,(uint)name.Capacity,nameFlags);
            if(count==0 || count>=name.Capacity || name.ToString()!=finalName || !GetFileInformationByHandle(handle,out var now) || now.Volume!=identity.Volume || now.IndexHigh!=identity.IndexHigh || now.IndexLow!=identity.IndexLow || now.Attributes!=identity.Attributes) throw new IOException("Held directory identity/alias/attributes changed");
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
            current.RequireReplacementScope(target);
            // Actual Windows 0a9fecd evidence changed control bits AND child
            // descriptors. No API is promoted by a source check or test flag.
            throw new IOException("Root-only filesystem security contract unaccepted; no mutation performed");
        }
        [DllImport("ntdll.dll",ExactSpelling=true)] static extern int NtSetSecurityObject(SafeFileHandle handle,uint selection,IntPtr descriptor);
        [DllImport("ntdll.dll",ExactSpelling=true)] static extern uint RtlNtStatusToDosError(int status);
        internal void ReplaceConstrainedCore(string expected,byte[] bytes) {
            if(observationOnly)throw new IOException("Observation-only lease");
            var current=Read();if(current.Sha256!=expected)throw new IOException("Owner/DACL drift before native call");
            var target=new ColdSecuritySnapshot(bytes);current.RequireReplacementScope(target);
            SetNative(bytes,5);
            var after=Read();if(after.Sha256!=target.Sha256 || after.DescriptorSha256!=target.DescriptorSha256)throw new IOException("Exact raw descriptor/ACL capacity round-trip failed; retain evidence");
        }
        internal void SeedFreshSynthetic(byte[] bytes) {
            RequireSynthetic();var target=new ColdSecuritySnapshot(bytes);target.Layout.RequireWritable();
            SetNative(bytes,7);var after=Read();
            if(after.DescriptorSha256!=target.DescriptorSha256)throw new IOException("Synthetic seed raw layout not retained; capacity/root gate remains open");
        }
        internal ColdPermissionChangeEvidence ReplacePermissionCandidate(string expectedRaw,byte[] bytes,bool seed) {
            RequireSynthetic();if(observationOnly)throw new IOException("Observation-only lease");
            var before=Read();ColdPermissionIdentity.RequireRawCas(Convert.FromBase64String(before.DescriptorBase64),expectedRaw);
            var target=new ColdSecuritySnapshot((byte[])bytes.Clone());new ColdPermissionIdentity(Convert.FromBase64String(target.DescriptorBase64));
            if(!seed){new ColdPermissionIdentity(Convert.FromBase64String(before.DescriptorBase64));before.RequireReplacementScope(target);}
            // Same original retained handle and selection as the strict path.
            // Seed is reachable only via the fresh one-attempt volume method.
            SetNative(Convert.FromBase64String(target.DescriptorBase64),seed?7u:5u);
            var observed=Read();var delta=ColdPermissionIdentity.Compare(Convert.FromBase64String(target.DescriptorBase64),Convert.FromBase64String(observed.DescriptorBase64));
            return new ColdPermissionChangeEvidence {Before=before,Requested=target,Observed=observed,Delta=delta};
        }
        void SetNative(byte[] bytes,uint selection) {
            RequireSynthetic();IntPtr buffer=Marshal.AllocHGlobal(bytes.Length);
            try {Marshal.Copy(bytes,0,buffer,bytes.Length);NativeMutationCalls++;int status=NtSetSecurityObject(handle,selection,buffer);if(status<0)throw new Win32Exception((int)RtlNtStatusToDosError(status));}
            finally {Marshal.FreeHGlobal(buffer);}
        }
        sealed class SyntheticBinding {public string Path,Identity;public Action Validate;}
        static readonly List<SyntheticBinding> syntheticRoots=new List<SyntheticBinding>();
        internal static void RegisterSynthetic(string path,string identity,Action validate) {lock(syntheticRoots){if(syntheticRoots.Count>=128)throw new IOException("Synthetic registry bound");syntheticRoots.Add(new SyntheticBinding {Path=path,Identity=identity,Validate=validate});}}
        void RequireSynthetic() {
            ValidateIdentity();lock(syntheticRoots)foreach(var root in syntheticRoots) {
                if(path==root.Path || path.StartsWith(root.Path.TrimEnd('\\')+"\\",StringComparison.OrdinalIgnoreCase)) {
                    root.Validate?.Invoke();
                    using var observed=String.IsNullOrEmpty(root.Identity)?null:new ColdDirectorySecurityLease(root.Path,true);
                    if(observed!=null && observed.FileIdentity!=root.Identity)throw new IOException("Synthetic ancestor replaced");return;
                }
            }
            throw new IOException("Only freshly created synthetic capabilities may invoke the maintained setter");
        }
        public static string CreateSyntheticDirectory(string parent,byte[] descriptor) {
            if(!OperatingSystem.IsWindows())throw new PlatformNotSupportedException();
            parent=Path.GetFullPath(parent);
            if(!parent.StartsWith("C:\\",StringComparison.Ordinal) || parent=="C:\\" || !Directory.Exists(parent) || descriptor==null || descriptor.Length>65536)throw new IOException("Synthetic C non-root private parent required");
            for(string at=parent;at!=null;at=Path.GetDirectoryName(at))if((File.GetAttributes(at)&FileAttributes.ReparsePoint)!=0 || File.Exists(Path.Combine(at,".git")) || Directory.Exists(Path.Combine(at,".git")))throw new IOException("Synthetic ancestry refused");
            string created=Path.Combine(parent,Guid.NewGuid().ToString("N"));ColdSourceLease.CreateProtectedDirectory(created,descriptor);
            using var lease=new ColdDirectorySecurityLease(created);RegisterSynthetic(created,lease.FileIdentity,null);return created;
        }
        public sealed class SyntheticTransaction : IDisposable {
            readonly ColdDirectorySecurityLease lease;bool closed;
            public int MutationCalls => lease.NativeMutationCalls;
            public bool IsClosed => closed;
            internal SyntheticTransaction(ColdDirectorySecurityLease owner){lease=owner;lease.RequireSynthetic();}
            public void Replace(string expected,byte[] bytes) {
                if(closed)throw new ObjectDisposedException("Synthetic transaction");lease.RequireSynthetic();
                var before=lease.Read();if(before.Sha256!=expected)throw new IOException("Synthetic descriptor drift");
                before.RequireReplacementScope(new ColdSecuritySnapshot(bytes));lease.ReplaceConstrainedCore(expected,bytes);
            }
            public void Dispose(){closed=true;}
        }
        public SyntheticTransaction OpenSyntheticTransaction(){RequireSynthetic();return new SyntheticTransaction(this);}
        public sealed class PermissionCandidateTransaction : IDisposable {
            readonly ColdDirectorySecurityLease lease;bool closed;
            public string Profile => ColdPermissionIdentity.Profile;public bool IsClosed => closed;
            public int MutationCalls => lease.NativeMutationCalls;
            internal PermissionCandidateTransaction(ColdDirectorySecurityLease owner){lease=owner;lease.RequireSynthetic();}
            public ColdPermissionChangeEvidence Replace(string expectedRawSha256,byte[] target) {
                if(closed)throw new ObjectDisposedException("Permission candidate transaction");
                return lease.ReplacePermissionCandidate(expectedRawSha256,target,false);
            }
            public void Dispose(){closed=true;}
        }
        public PermissionCandidateTransaction OpenPermissionCandidateTransaction(){RequireSynthetic();return new PermissionCandidateTransaction(this);}
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

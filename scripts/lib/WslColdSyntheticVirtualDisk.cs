// Fresh C-only synthetic disk capability. No open-existing, disk-number input,
// permanent attach, WSL registration, deletion or global disk selection API.
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
namespace Revealfleet.Backup {
    public sealed class ColdSyntheticVirtualDisk : IDisposable {
        public const ulong VirtualBytes=128UL*1024*1024, HardFileBytes=256UL*1024*1024;
        [StructLayout(LayoutKind.Sequential)] struct StorageType {public uint Device;public Guid Vendor;}
        // Version1 union begins at offset8 (ULONGLONG alignment), not offset4.
        [StructLayout(LayoutKind.Explicit,Size=128)] struct CreateParameters {
            [FieldOffset(0)] public uint Version;[FieldOffset(8)] public Guid Id;
            [FieldOffset(24)] public ulong Size;[FieldOffset(32)] public uint Block;
            [FieldOffset(36)] public uint Sector;[FieldOffset(40)] public IntPtr Parent;
            [FieldOffset(48)] public IntPtr Source;
        }
        [StructLayout(LayoutKind.Sequential)] struct AttachParameters {public uint Version,Reserved;}
        [StructLayout(LayoutKind.Sequential)] struct FileInfo {public uint Attributes;public System.Runtime.InteropServices.ComTypes.FILETIME C,A,W;public uint Volume,High,Low,Links,IndexHigh,IndexLow;}
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("virtdisk.dll",CharSet=CharSet.Unicode)] static extern uint CreateVirtualDisk(ref StorageType type,string path,uint access,IntPtr descriptor,uint flags,uint provider,ref CreateParameters parameters,IntPtr overlapped,out IntPtr handle);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("virtdisk.dll")] static extern uint AttachVirtualDisk(SafeFileHandle handle,IntPtr descriptor,uint flags,uint provider,ref AttachParameters parameters,IntPtr overlapped);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("virtdisk.dll")] static extern uint DetachVirtualDisk(SafeFileHandle handle,uint flags,uint provider);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("virtdisk.dll",CharSet=CharSet.Unicode)] static extern uint GetVirtualDiskPhysicalPath(SafeFileHandle handle,ref uint bytes,StringBuilder path);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("virtdisk.dll")] static extern uint GetVirtualDiskInformation(SafeFileHandle handle,ref uint bytes,IntPtr info,out uint used);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle handle,out FileInfo info);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle,StringBuilder text,uint length,uint flags);
        [DllImport("kernel32.dll",SetLastError=true)] static extern bool DeviceIoControl(SafeFileHandle handle,uint code,IntPtr input,uint inputBytes,byte[] output,uint size,out uint used,IntPtr overlapped);
        readonly SafeFileHandle disk,backing;readonly FileInfo fileIdentity;bool attached,closed,seeded,registered;
        string physical;ulong partitionOffset,partitionBytes;
        public string Workspace {get;private set;} public string ImagePath {get;private set;}
        public Guid Identifier {get;private set;} public string VolumeRoot {get;private set;}
        public int SeedMutationCalls {get;private set;}
        public bool Attached => attached;public bool Closed => closed;
        public uint DeviceNumber {get;private set;}
        public ulong BackingFileBytes => (ulong)fileIdentity.High<<32|fileIdentity.Low;
        public string PhysicalPath {get {Validate();if(!attached)throw new IOException("Not attached");return physical;}}
        static void Check(uint status){if(status!=0)throw new Win32Exception((int)status);}
        private ColdSyntheticVirtualDisk(string parent,byte[] directoryDescriptor,byte[] fileDescriptor) {
            if(!OperatingSystem.IsWindows() || IntPtr.Size!=8)throw new PlatformNotSupportedException("64-bit Windows virtual disk API required");
            if(!new System.Security.Principal.WindowsPrincipal(System.Security.Principal.WindowsIdentity.GetCurrent()).IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator))throw new IOException("Actual elevated synthetic runner required");
            Workspace=ColdDirectorySecurityLease.CreateSyntheticDirectory(parent,directoryDescriptor);ImagePath=Path.Combine(Workspace,"fixture.vhd");Identifier=Guid.NewGuid();
            IntPtr sd=IntPtr.Zero;
            try {
                if(fileDescriptor==null || fileDescriptor.Length<20 || fileDescriptor.Length>65536)throw new IOException("Bounded private file descriptor required");
                sd=Marshal.AllocHGlobal(fileDescriptor.Length);Marshal.Copy(fileDescriptor,0,sd,fileDescriptor.Length);
                var type=new StorageType {Device=2,Vendor=new Guid("EC984AEC-A0F9-47E9-901F-71415A66345B")};
                var create=new CreateParameters {Version=1,Id=Identifier,Size=VirtualBytes,Sector=512};
                // No parent/source input; fixed new VHD, full physical allocation.
                uint status=CreateVirtualDisk(ref type,ImagePath,0x3f0000,sd,1,0,ref create,IntPtr.Zero,out var raw);
                Check(status);disk=new SafeFileHandle(raw,true);
                backing=CreateFileW(ImagePath,0x80,3,IntPtr.Zero,3,0x00200000,IntPtr.Zero);
                if(backing.IsInvalid || !GetFileInformationByHandle(backing,out fileIdentity))throw new IOException("New VHD metadata/no-delete custody unavailable");
                Validate();
            } catch(Exception error) {backing?.Dispose();disk?.Dispose();throw new IOException("Synthetic creation refused; retain "+Workspace,error);}
            finally {if(sd!=IntPtr.Zero)Marshal.FreeHGlobal(sd);}
        }
        public static ColdRestorePrivilege OpenPrivilegeScope() => ColdRestorePrivilege.SyntheticVolumeScope();
        public static ColdSyntheticVirtualDisk CreateNew(string parent,byte[] directoryDescriptor,byte[] fileDescriptor) => new ColdSyntheticVirtualDisk(parent,directoryDescriptor,fileDescriptor);
        public void Validate() {
            if(closed || disk==null || disk.IsInvalid || disk.IsClosed || backing==null || backing.IsInvalid || backing.IsClosed)throw new IOException("Synthetic capability closed/unconfirmed");
            var name=new StringBuilder(32768);
            if(!GetFileInformationByHandle(backing,out var now) || now.Volume!=fileIdentity.Volume || now.IndexHigh!=fileIdentity.IndexHigh || now.IndexLow!=fileIdentity.IndexLow || now.Links!=1 || (now.Attributes&0x4c10)!=0 ||
                ((ulong)now.High<<32|now.Low)!=BackingFileBytes || BackingFileBytes<VirtualBytes || BackingFileBytes>HardFileBytes || GetFinalPathNameByHandleW(backing,name,(uint)name.Capacity,0)==0 || name.ToString()!=@"\\?\"+ImagePath)throw new IOException("Owned VHD file identity/size/alias changed");
            using(var named=CreateFileW(ImagePath,0x80,7,IntPtr.Zero,3,0x00200000,IntPtr.Zero)) {
                if(named.IsInvalid || !GetFileInformationByHandle(named,out var n) || n.Volume!=fileIdentity.Volume || n.IndexHigh!=fileIdentity.IndexHigh || n.IndexLow!=fileIdentity.IndexLow)throw new IOException("VHD name substitution refused");
            }
            IntPtr info=Marshal.AllocHGlobal(64);
            try {
                for(int i=0;i<64;i++)Marshal.WriteByte(info,i,0);
                Marshal.WriteInt32(info,2);uint size=64;Check(GetVirtualDiskInformation(disk,ref size,info,out var used));
                byte[] id=new byte[16];Marshal.Copy(IntPtr.Add(info,8),id,0,16);if(new Guid(id)!=Identifier)throw new IOException("Created VHD identifier changed");
                Marshal.WriteInt32(info,1);size=64;Check(GetVirtualDiskInformation(disk,ref size,info,out used));
                if((ulong)Marshal.ReadInt64(info,8)!=VirtualBytes)throw new IOException("VHD geometry changed");
            } finally {Marshal.FreeHGlobal(info);}
            if(attached && (CurrentPhysical()!=physical || NumberForPath(physical)!=DeviceNumber))throw new IOException("Owned attachment disconnect/rebind refused");
        }
        string CurrentPhysical() {
            var text=new StringBuilder(1024);uint size=2048;Check(GetVirtualDiskPhysicalPath(disk,ref size,text));string value=text.ToString();
            const string prefix=@"\\.\PhysicalDrive";
            if(!value.StartsWith(prefix,StringComparison.Ordinal) || !uint.TryParse(value.Substring(prefix.Length),out var unused))throw new IOException("Virtual API physical path refused");return value;
        }
        static uint NumberForPath(string path) {
            using var device=CreateFileW(path,0,7,IntPtr.Zero,3,0,IntPtr.Zero);byte[] data=new byte[12];
            if(device.IsInvalid || !DeviceIoControl(device,0x2d1080,IntPtr.Zero,0,data,12,out var used,IntPtr.Zero) || used<12 || BitConverter.ToUInt32(data,0)!=7)throw new IOException("Disk metadata identity unavailable");
            uint part=BitConverter.ToUInt32(data,8);if(part!=0 && part!=uint.MaxValue)throw new IOException("Whole-disk path required");return BitConverter.ToUInt32(data,4);
        }
        public void Attach() {
            Validate();if(attached)throw new IOException("Already attached");var p=new AttachParameters {Version=1};
            Check(AttachVirtualDisk(disk,IntPtr.Zero,2,0,ref p,IntPtr.Zero));attached=true;
            physical=CurrentPhysical();DeviceNumber=NumberForPath(physical);Validate();
        }
        public void ValidateStorage(string storagePath,uint observedNumber,ulong observedSize,bool isBoot,bool isSystem) {
            Validate();if(!attached || observedNumber!=DeviceNumber || observedSize!=VirtualBytes || isBoot || isSystem || String.IsNullOrWhiteSpace(storagePath) || NumberForPath(storagePath)!=DeviceNumber)throw new IOException("Storage object is not the owned new VHD");
        }
        public void BindVolume(string root,ulong offset,ulong size) {
            Validate();if(!attached || VolumeRoot!=null || offset<1048576 || offset>VirtualBytes || size==0 || size>VirtualBytes-offset)throw new IOException("Fresh owned partition required");
            if(root==null || root.Length!=49 || !root.StartsWith(@"\\?\Volume{",StringComparison.Ordinal) || !root.EndsWith("}\\",StringComparison.Ordinal) || !Guid.TryParse(root.Substring(11,36),out var id) || id==Guid.Empty)throw new IOException("Canonical volume GUID root required");
            VolumeRoot=@"\\?\Volume{"+id.ToString("D")+"}\\";partitionOffset=offset;partitionBytes=size;ValidateVolume();
        }
        public void ValidateVolume() {
            Validate();if(VolumeRoot==null)throw new IOException("Volume not bound");
            using var volume=CreateFileW(VolumeRoot.TrimEnd('\\'),0,7,IntPtr.Zero,3,0,IntPtr.Zero);byte[] data=new byte[1024];
            if(volume.IsInvalid || !DeviceIoControl(volume,0x560000,IntPtr.Zero,0,data,(uint)data.Length,out var used,IntPtr.Zero) || used<32 || BitConverter.ToUInt32(data,0)!=1 ||
               BitConverter.ToUInt32(data,8)!=DeviceNumber || (ulong)BitConverter.ToInt64(data,16)!=partitionOffset || (ulong)BitConverter.ToInt64(data,24)!=partitionBytes)throw new IOException("Volume extents do not bind the owned VHD partition");
        }
        public ColdDirectorySecurityLease OpenRoot() {
            ValidateVolume();if(!registered){ColdDirectorySecurityLease.RegisterSynthetic(VolumeRoot,"",ValidateVolume);registered=true;}return new ColdDirectorySecurityLease(this);
        }
        public void SeedRoot(ColdSecuritySnapshot descriptor) {
            if(seeded)throw new IOException("Fixture seed attempt already consumed; retain failed attempt");seeded=true;using var root=OpenRoot();
            try {root.SeedFreshSynthetic(Convert.FromBase64String(descriptor.DescriptorBase64));}finally {SeedMutationCalls=root.NativeMutationCalls;}
        }
        public ColdPermissionChangeEvidence SeedRootPermissionCandidate(string expectedRawSha256,ColdSecuritySnapshot descriptor) {
            if(seeded)throw new IOException("Fixture seed attempt already consumed; retain failed attempt");seeded=true;using var root=OpenRoot();
            try {return root.ReplacePermissionCandidate(expectedRawSha256,Convert.FromBase64String(descriptor.DescriptorBase64),true);}finally {SeedMutationCalls=root.NativeMutationCalls;}
        }
        [StructLayout(LayoutKind.Sequential)] struct SidAndAttributes {public IntPtr Sid;public uint Attributes;}
        [StructLayout(LayoutKind.Sequential)] struct GenericMapping {public uint Read,Write,Execute,All;}
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateDirectoryW(string path,IntPtr attributes);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr process,uint access,out IntPtr token);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool CreateRestrictedToken(IntPtr token,uint flags,uint disabled,ref SidAndAttributes sid,uint deleted,IntPtr privileges,uint restricted,IntPtr sids,out IntPtr result);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool DuplicateToken(IntPtr token,int level,out IntPtr result);
        [DllImport("advapi32.dll",SetLastError=true)] static extern bool AccessCheck(IntPtr descriptor,IntPtr token,uint access,ref GenericMapping mapping,IntPtr privileges,ref uint size,out uint granted,out bool allowed);
        public object ProveOrdinaryRights(ColdDirectorySecurityLease lease) {
            ValidateVolume();lease.ValidateIdentity();if(lease.CanonicalPath!=VolumeRoot)throw new IOException("Exact owned root lease required");
            byte[] descriptor=Convert.FromBase64String(lease.Read().DescriptorBase64);IntPtr process=IntPtr.Zero,restricted=IntPtr.Zero,copy=IntPtr.Zero,admin=IntPtr.Zero,sd=IntPtr.Zero,privileges=IntPtr.Zero;
            bool before=new System.Security.Principal.WindowsPrincipal(System.Security.Principal.WindowsIdentity.GetCurrent()).IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
            try {
                if(!OpenProcessToken(GetCurrentProcess(),10,out process))throw new Win32Exception(Marshal.GetLastWin32Error());
                var sid=new System.Security.Principal.SecurityIdentifier("S-1-5-32-544");byte[] bytes=new byte[sid.BinaryLength];sid.GetBinaryForm(bytes,0);admin=Marshal.AllocHGlobal(bytes.Length);Marshal.Copy(bytes,0,admin,bytes.Length);
                var disabled=new SidAndAttributes {Sid=admin};
                if(!CreateRestrictedToken(process,1,1,ref disabled,0,IntPtr.Zero,0,IntPtr.Zero,out restricted) || !DuplicateToken(restricted,2,out copy))throw new Win32Exception(Marshal.GetLastWin32Error());
                sd=Marshal.AllocHGlobal(descriptor.Length);Marshal.Copy(descriptor,0,sd,descriptor.Length);privileges=Marshal.AllocHGlobal(1024);
                foreach(uint access in new uint[]{0x10000,0x40,0x40000,0x80000,2,4}) {
                    var map=new GenericMapping {Read=0x120089,Write=0x120116,Execute=0x1200a0,All=0x1f01ff};uint size=1024;
                    if(!AccessCheck(sd,copy,access,ref map,privileges,ref size,out var granted,out var allowed))throw new Win32Exception(Marshal.GetLastWin32Error());
                    if(allowed!=(access==2 || access==4))throw new IOException("Ordinary security/creation rights differ from reviewed scope");
                }
                using(var token=new SafeAccessTokenHandle(copy)) {
                    copy=IntPtr.Zero;
                    System.Security.Principal.WindowsIdentity.RunImpersonated(token,()=>{
                        if(!CreateDirectoryW(VolumeRoot+"ordinary-created",IntPtr.Zero))throw new Win32Exception(Marshal.GetLastWin32Error());
                        using var file=new FileStream(VolumeRoot+"ordinary-created.bin",FileMode.CreateNew,FileAccess.Write,FileShare.Read);
                        file.Write(new byte[]{1,2,0,255});file.Flush(true);
                    });
                }
                bool after=new System.Security.Principal.WindowsPrincipal(System.Security.Principal.WindowsIdentity.GetCurrent()).IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
                if(!before || !after)throw new IOException("Prior privilege context not restored after ordinary proof");
                ValidateVolume();return new {DeniedDelete=true,DeniedDeleteChild=true,DeniedWriteDac=true,DeniedWriteOwner=true,ActualOrdinaryFileAndDirectoryCreated=true,PriorAdminContextRestored=true};
            } finally {if(process!=IntPtr.Zero)CloseHandle(process);if(restricted!=IntPtr.Zero)CloseHandle(restricted);if(copy!=IntPtr.Zero)CloseHandle(copy);if(admin!=IntPtr.Zero)Marshal.FreeHGlobal(admin);if(sd!=IntPtr.Zero)Marshal.FreeHGlobal(sd);if(privileges!=IntPtr.Zero)Marshal.FreeHGlobal(privileges);}
        }
        public void Detach() {
            Validate();if(!attached)return;Check(DetachVirtualDisk(disk,0,0));attached=false;
        }
        public void Dispose() {
            if(closed)return;if(attached)Detach();backing.Dispose();disk.Dispose();closed=true;
        }
    }
}

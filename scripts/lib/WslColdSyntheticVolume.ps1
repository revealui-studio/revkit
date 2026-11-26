# Bounded synthetic VOLUME ROOT protocol. Never imported as production execution.
. (Join-Path $PSScriptRoot 'WslColdVolumeCustody.ps1')
function Resolve-WslColdStorageNestedPath {
    param([string]$ManifestPath,[string]$Relative)
    # The selected system manifest currently declares direct files. Refuse
    # other grammars instead of resolving a module name through PSModulePath.
    if(-not $Relative -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':') -or $Relative.Contains('\') -or $Relative.Contains('/') -or [IO.Path]::GetExtension($Relative) -cnotin @('.cdxml','.psm1')){throw 'Storage nested declaration must be a direct CDXML/script file.'}
    return [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($ManifestPath)) $Relative))
}
function Assert-WslColdStorageCommandBinding {
    param($Parent,[string]$ManifestPath,[guid]$ManifestGuid,[version]$ManifestVersion,[string[]]$NestedPaths,[string]$Name,[object[]]$Resolved)
    $base=[IO.Path]::GetDirectoryName($ManifestPath)
    if(-not $Parent -or $Parent.Name -cne 'Storage' -or $Parent.ModuleType.ToString() -cne 'Manifest' -or -not [string]::Equals($Parent.Path,$ManifestPath,[StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals($Parent.ModuleBase,$base,[StringComparison]::OrdinalIgnoreCase) -or $Parent.Guid -ne $ManifestGuid -or $Parent.Version -ne $ManifestVersion){throw 'Selected Storage manifest identity differs from imported parent.'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($nested in @($Parent.NestedModules)){
        if(-not $nested.Path -or -not $seen.Add($nested.Path) -or $NestedPaths -inotcontains $nested.Path){throw 'Imported Storage nested module was not declared by selected manifest.'}
        $kind=if([IO.Path]::GetExtension($nested.Path) -ceq '.cdxml'){'Cim'}else{'Script'}
        if(-not [string]::Equals([IO.Path]::GetDirectoryName($nested.Path),$base,[StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals($nested.ModuleBase,$base,[StringComparison]::OrdinalIgnoreCase) -or $nested.Name -cne [IO.Path]::GetFileNameWithoutExtension($nested.Path) -or $nested.ModuleType.ToString() -cne $kind){throw 'Imported Storage nested path/name/type differs from declaration.'}
    }
    if($seen.Count -ne $NestedPaths.Count){throw 'Storage declared/imported nested inventory differs.'}
    if($Resolved.Count -ne 1){throw ('Ambiguous or shadowed Storage command: '+$Name)}
    $command=$Resolved[0];$origin=@($Parent.NestedModules|Where-Object {[object]::ReferenceEquals($_,$command.Module)})
    if($command.Name -cne $Name -or $command.CommandType.ToString() -cne 'Function' -or $origin.Count -ne 1 -or [IO.Path]::GetExtension($origin[0].Path) -cne '.cdxml' -or $command.ModuleName -cne $origin[0].Name -or -not [object]::ReferenceEquals($command,$Parent.ExportedCommands[$Name])){throw ('Storage command is not the selected manifest CDXML export: '+$Name)}
}
function Get-WslColdMicrosoftStorageFile {
    param([string]$Path)
    [void](Assert-WslColdProtectedPath $Path)
    $signature=Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    # Publisher identity, not a machine-specific file/certificate hash. Other
    # publisher forms require review, even if the local trust store accepts them.
    $subjects=@('CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US','CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US')
    if($signature.Status.ToString() -cne 'Valid' -or -not $signature.SignerCertificate -or $signature.SignerCertificate.Subject -cnotin $subjects){throw ('Valid Microsoft Storage signature required: '+$Path)}
    return [ordered]@{path=$Path;sha256=(Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant();signer=$signature.SignerCertificate.Subject}
}
function Get-WslColdStoragePreflight {
    if(-not $IsWindows -or -not [Environment]::Is64BitProcess){throw 'Read-only Storage preflight requires native 64-bit PowerShell on Windows.'}
    $manifest=[IO.Path]::GetFullPath((Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell/v1.0/Modules/Storage/Storage.psd1'))
    $files=[Collections.Generic.List[object]]::new();$files.Add((Get-WslColdMicrosoftStorageFile $manifest))
    $data=Microsoft.PowerShell.Utility\Import-PowerShellDataFile -LiteralPath $manifest -ErrorAction Stop
    $declarations=@($data.NestedModules)
    if($declarations.Count -lt 1 -or $declarations.Count -gt 128){throw 'Bounded declared Storage nested inventory required.'}
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($relative in $declarations){
        if($relative -isnot [string]){throw 'Unsupported Storage nested module specification.'}
        $path=Resolve-WslColdStorageNestedPath $manifest $relative
        if(-not $paths.Add($path)){throw 'Duplicate Storage nested declaration.'};$files.Add((Get-WslColdMicrosoftStorageFile $path))
    }
    foreach($loaded in @(Microsoft.PowerShell.Core\Get-Module -Name Storage -All)){
        if(-not [string]::Equals($loaded.Path,$manifest,[StringComparison]::OrdinalIgnoreCase)){throw 'Ambient Storage module differs from selected system manifest; fresh process required.'}
    }
    $parents=@(Microsoft.PowerShell.Core\Import-Module -Name $manifest -PassThru -Global -NoClobber -ErrorAction Stop)
    if($parents.Count -ne 1){throw 'Exactly one selected Storage parent required.'};$parent=$parents[0]
    $commands=[Collections.Generic.List[object]]::new()
    foreach($name in @('Get-DiskImage','Get-Disk','Get-Partition','Initialize-Disk','New-Partition','Format-Volume','Get-Volume')){
        $resolved=@(Microsoft.PowerShell.Core\Get-Command -Name ('Storage\'+$name) -All -ListImported -ErrorAction Stop)
        Assert-WslColdStorageCommandBinding $parent $manifest ([guid]$data.GUID) ([version]$data.ModuleVersion) @($paths) $name $resolved
        $commands.Add([ordered]@{name=$name;moduleName=$resolved[0].ModuleName;modulePath=$resolved[0].Module.Path;commandType=$resolved[0].CommandType.ToString()})
    }
    return [ordered]@{profile='microsoft-system-storage-cdxml-v1';readOnly=$true;manifest=$manifest;guid=$parent.Guid.ToString();version=$parent.Version.ToString();files=@($files);commands=@($commands);diskCommandsExecuted=$false;volumeAccepted=$false;productionAccepted=$false}
}
function Assert-WslSyntheticCParent {
    param([string]$Path)
    if(-not $IsWindows -or [IO.Path]::GetFullPath($Path) -cne $Path -or -not $Path.StartsWith('C:\',[StringComparison]::Ordinal) -or $Path -ceq 'C:\'){throw 'Canonical protected non-root C synthetic parent required.'}
    [void](Assert-WslColdProtectedPath $Path -Directory -PrivateData)
}
function Get-WslColdSyntheticVolumePlan {
    param([string]$FixtureParent,[string]$EvidenceParent,[string]$SourceManifestSha256)
    Assert-WslSyntheticCParent $FixtureParent;Assert-WslSyntheticCParent $EvidenceParent
    $source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    foreach($a in @($FixtureParent,$EvidenceParent)){
        if($a -ceq $source -or $a.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase) -or $source.StartsWith($a+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Independent source and data custody required.'}
    }
    if($FixtureParent -ceq $EvidenceParent -or $FixtureParent.StartsWith($EvidenceParent+'\',[StringComparison]::OrdinalIgnoreCase) -or $EvidenceParent.StartsWith($FixtureParent+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Disjoint fixture and evidence parents required.'}
    $code=Get-WslColdCustodyCode $source $SourceManifestSha256 -RequireProtected
    Initialize-WslColdWorkerProtocol
    $storage=Get-WslColdStoragePreflight
    $f=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($FixtureParent);$e=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($EvidenceParent)
    try {
        [ordered]@{schemaVersion=2;kind='new-private-synthetic-volume-root-v1';sourceRoot=$source;sourceCommit=$code.SourceCommit;sourceManifestSha256=$SourceManifestSha256;storage=$storage;
            ownerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;fixtureParent=$FixtureParent;evidenceParent=$EvidenceParent;fixtureIdentity=$f.FileIdentity;evidenceIdentity=$e.FileIdentity;
            fixtureDescriptor=$f.Read().DescriptorSha256;evidenceDescriptor=$e.Read().DescriptorSha256;
            virtualBytes=[long][Revealfleet.Backup.ColdSyntheticVirtualDisk]::VirtualBytes;hardFileBytes=[long][Revealfleet.Backup.ColdSyntheticVirtualDisk]::HardFileBytes;
            createdAt=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();expiresAt=[DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds();
            operations=@('Create NEW UUID private C workspace and fixed128MiB VHD via CreateVirtualDisk','Attach own handle NO_DRIVE_LETTER, nonpersistent','Initialize only returned/revalidated Disk object MBR; New-Partition only that object; Format only returned/revalidated Partition NTFS','Bind native virtual identifier/file identity/physical path/device metadata/volume extents before every write','Capture expected system children; seed generic foreign owner/group control0x8004 ACL248/parsed68/zero-spare180','Require exact stable descendants, root raw capacity and rollback; retain VHD/evidence; detach own handle only');
            actualProductionAccepted=$false;existingVhdAccepted=$false;physicalDiskAccepted=$false;rootPrivileges=@('SeRestorePrivilege','SeManageVolumePrivilege')}
    } finally {$f.Dispose();$e.Dispose()}
}
function Get-WslOwnedSyntheticStorage {
    param([Revealfleet.Backup.ColdSyntheticVirtualDisk]$Owned,[Collections.IDictionary]$StorageBinding)
    $Owned.Validate()
    if(-not $StorageBinding -or (ConvertTo-Json -InputObject (Get-WslColdStoragePreflight) -Depth 12 -Compress) -cne (ConvertTo-Json -InputObject $StorageBinding -Depth 12 -Compress)){throw 'Reviewed Storage ownership changed before disk operation.'}
    $images=@(Storage\Get-DiskImage -ImagePath $Owned.ImagePath -ErrorAction Stop)
    if($images.Count -ne 1 -or -not $images[0].Attached -or $images[0].DevicePath -cne $Owned.PhysicalPath -or $images[0].ImagePath -cne $Owned.ImagePath){throw 'Exact created image association refused.'}
    # Microsoft's documented Get-DiskImage | Get-Disk association. No global
    # enumeration, input disk ordinal, guessed letter or numeric fallback.
    $disks=@($images[0]|Storage\Get-Disk -ErrorAction Stop)
    if($disks.Count -ne 1){throw 'Ambiguous/missing image-to-Storage disk association.'}
    $d=$disks[0]
    if([int]$d.BusType -notin @(14,15) -or $d.IsOffline -or $d.IsReadOnly -or $d.IsClustered){throw 'Fresh virtual writable online disk required; no policy workaround.'}
    $Owned.ValidateStorage($d.Path,[uint32]$d.Number,[uint64]$d.Size,[bool]$d.IsBoot,[bool]$d.IsSystem)
    return $d
}
function Assert-WslOwnedSyntheticPartition {
    param([Revealfleet.Backup.ColdSyntheticVirtualDisk]$Owned,$Partition,[Collections.IDictionary]$StorageBinding)
    $disk=Get-WslOwnedSyntheticStorage $Owned $StorageBinding
    $parents=@(Storage\Get-Disk -Partition $Partition -ErrorAction Stop)
    $current=@($disk|Storage\Get-Partition -ErrorAction Stop)
    if($current.Count -ne 1 -or $current[0].ObjectId -cne $Partition.ObjectId -or $current[0].Offset -ne $Partition.Offset -or $current[0].Size -ne $Partition.Size){throw 'Partition identity/layout drift before write.'}
    if($parents.Count -ne 1 -or $parents[0].Path -cne $disk.Path -or $parents[0].UniqueId -cne $disk.UniqueId -or $Partition.DiskNumber -ne $disk.Number -or $Partition.Offset -lt 1MB -or $Partition.Size -le 0 -or $Partition.Offset+$Partition.Size -gt [Revealfleet.Backup.ColdSyntheticVirtualDisk]::VirtualBytes){throw 'Returned partition no longer belongs to owned VHD.'}
    $Owned.ValidateStorage($parents[0].Path,[uint32]$parents[0].Number,[uint64]$parents[0].Size,[bool]$parents[0].IsBoot,[bool]$parents[0].IsSystem)
}
function Initialize-WslOwnedSyntheticVolume {
    param([Revealfleet.Backup.ColdSyntheticVirtualDisk]$Owned,[string]$Evidence,[Collections.IDictionary]$StorageBinding)
    $disk=Get-WslOwnedSyntheticStorage $Owned $StorageBinding
    if($disk.PartitionStyle.ToString() -cne 'RAW' -or $disk.NumberOfPartitions -ne 0){throw 'Never initialize an existing partitioned disk.'}
    Write-WslBackupJsonNew (Join-Path $Evidence 'before-initialize.json') @{image=$Owned.ImagePath;identifier=$Owned.Identifier;physical=$Owned.PhysicalPath;storagePath=$disk.Path;number=$disk.Number;size=$disk.Size}
    $disk=Get-WslOwnedSyntheticStorage $Owned $StorageBinding # immediately before destructive command
    if($disk.PartitionStyle.ToString() -cne 'RAW' -or $disk.NumberOfPartitions -ne 0){throw 'RAW identity drift before initialize.'}
    $null=Storage\Initialize-Disk -InputObject $disk -PartitionStyle MBR -PassThru -Confirm:$false -ErrorAction Stop
    $disk=Get-WslOwnedSyntheticStorage $Owned $StorageBinding
    if($disk.PartitionStyle.ToString() -cne 'MBR' -or $disk.NumberOfPartitions -ne 0){throw 'Unexpected initialized layout.'}
    Write-WslBackupJsonNew (Join-Path $Evidence 'before-partition.json') @{identifier=$Owned.Identifier;storagePath=$disk.Path;uniqueId=$disk.UniqueId}
    $disk=Get-WslOwnedSyntheticStorage $Owned $StorageBinding
    if($disk.PartitionStyle.ToString() -cne 'MBR' -or $disk.NumberOfPartitions -ne 0){throw 'Partition layout drift before creation.'}
    $parts=@(Storage\New-Partition -InputObject $disk -UseMaximumSize -MbrType IFS -ErrorAction Stop)
    if($parts.Count -ne 1){throw 'Exactly one returned synthetic partition required.'};$part=$parts[0]
    Assert-WslOwnedSyntheticPartition $Owned $part $StorageBinding
    Write-WslBackupJsonNew (Join-Path $Evidence 'before-format.json') @{identifier=$Owned.Identifier;partition=$part.ObjectId;offset=$part.Offset;size=$part.Size}
    Assert-WslOwnedSyntheticPartition $Owned $part $StorageBinding # immediately before format
    $volumes=@(Storage\Format-Volume -Partition $part -FileSystem NTFS -AllocationUnitSize 4096 -NewFileSystemLabel 'RevkitSynthetic' -Confirm:$false -ErrorAction Stop)
    Assert-WslOwnedSyntheticPartition $Owned $part $StorageBinding
    if($volumes.Count -ne 1 -or $volumes[0].FileSystemType.ToString() -cne 'NTFS' -or $volumes[0].AllocationUnitSize -ne 4096){throw 'Returned NTFS volume refused.'}
    $Owned.BindVolume($volumes[0].Path,[uint64]$part.Offset,[uint64]$part.Size)
    Write-WslBackupJsonNew (Join-Path $Evidence 'volume-bound.json') @{identifier=$Owned.Identifier;root=$Owned.VolumeRoot;offset=$part.Offset;size=$part.Size}
}
function Get-WslOwnedSyntheticTree {
    param([Revealfleet.Backup.ColdSyntheticVirtualDisk]$Owned,[switch]$SystemOnly)
    $Owned.ValidateVolume();$root=$Owned.VolumeRoot;$queue=[Collections.Generic.Queue[object]]::new();$queue.Enqueue(@{path=$root;depth=0})
    $rows=[Collections.Generic.List[object]]::new();[long]$bytes=0
    while($queue.Count){
        $entry=$queue.Dequeue();if($entry.depth -gt 4){throw 'Synthetic depth limit.'}
        foreach($path in [IO.Directory]::GetFileSystemEntries($entry.path)){
            if($rows.Count -ge 64){throw 'Synthetic entry limit.'};$Owned.ValidateVolume();$attr=[IO.File]::GetAttributes($path)
            if($attr -band [IO.FileAttributes]::ReparsePoint){throw 'Unexpected synthetic reparse; do not follow.'}
            $relative=$path.Substring($root.Length)
            if($entry.depth -eq 0 -and $SystemOnly -and $relative -cnotin @('System Volume Information','$RECYCLE.BIN')){throw ('Unexpected pre-fixture system child: '+$relative)}
            if($entry.depth -eq 0 -and $relative -cnotin @('System Volume Information','$RECYCLE.BIN','ordinary','protected','baseline.bin','new-child.bin','ordinary-created','ordinary-created.bin')){throw ('Unmodeled system-created NTFS child: '+$relative)}
            $isDir=($attr -band [IO.FileAttributes]::Directory) -ne 0
            if($isDir){$item=[IO.DirectoryInfo]::new($path);$acl=[IO.FileSystemAclExtensions]::GetAccessControl($item);$queue.Enqueue(@{path=$path;depth=$entry.depth+1});$hash=''}
            else {$item=[IO.FileInfo]::new($path);if($item.Length -gt 1MB -or $bytes+$item.Length -gt 16MB){throw 'Synthetic data budget exceeded.'};$bytes+=$item.Length;$acl=[IO.FileSystemAclExtensions]::GetAccessControl($item);$stream=[IO.File]::OpenRead($path);try {$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))}finally {$stream.Dispose()}}
            $item.Refresh();$rows.Add([ordered]@{path=$relative;descriptor=[Convert]::ToBase64String($acl.GetSecurityDescriptorBinaryForm());attributes=[int]$item.Attributes;created=$item.CreationTimeUtc.Ticks;written=$item.LastWriteTimeUtc.Ticks;hash=$hash})
        }
    }
    return (ConvertTo-Json -InputObject @($rows|Sort-Object path -CaseSensitive) -Depth 10 -Compress)
}
function New-WslGenericPaddedRoot {
    $owner=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-111-222-333-4294960000');$group=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-111-222-333-513')
    $sd=[Security.AccessControl.RawSecurityDescriptor]::new(('O:'+$owner.Value+'G:'+$group.Value+'D:(A;OICI;FA;;;WD)(A;OICI;FA;;;CO)(A;OICI;FA;;;SY)'))
    $a=[byte[]]::new($sd.DiscretionaryAcl.BinaryLength);$sd.DiscretionaryAcl.GetBinaryForm($a,0)
    $o=[byte[]]::new($owner.BinaryLength);$owner.GetBinaryForm($o,0);$g=[byte[]]::new($group.BinaryLength);$group.GetBinaryForm($g,0)
    return [Revealfleet.Backup.ColdSecuritySnapshot]::new([Revealfleet.Backup.ColdSecurityLayout]::Compose(0x8004,$o,$g,$a,248,$null))
}
function Invoke-WslColdSyntheticVolume {
    param([string]$PlanPath,[string]$ReviewedPlanSha256)
    if(-not $IsWindows){throw 'Actual Windows/root review required; native cannot execute synthetic volume.'}
    Assert-WslBackupHash $ReviewedPlanSha256;$doc=Read-WslRecoveryDocument $PlanPath
    if($doc.Sha256 -cne $ReviewedPlanSha256){throw 'Independent reviewed plan digest differs.'};$p=$doc.Value
    Assert-WslRecoveryFields $p @('schemaVersion','kind','sourceRoot','sourceCommit','sourceManifestSha256','storage','ownerSid','fixtureParent','evidenceParent','fixtureIdentity','evidenceIdentity','fixtureDescriptor','evidenceDescriptor','virtualBytes','hardFileBytes','createdAt','expiresAt','operations','actualProductionAccepted','existingVhdAccepted','physicalDiskAccepted','rootPrivileges') 'synthetic volume review plan'
    if($p.schemaVersion -ne 2 -or $p.kind -cne 'new-private-synthetic-volume-root-v1' -or $p.expiresAt -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -or $p.expiresAt-$p.createdAt -gt 3600){throw 'Fresh synthetic-only plan required.'}
    $fresh=Get-WslColdSyntheticVolumePlan $p.fixtureParent $p.evidenceParent $p.sourceManifestSha256
    foreach($name in @('sourceRoot','sourceCommit','ownerSid','fixtureIdentity','evidenceIdentity','fixtureDescriptor','evidenceDescriptor','virtualBytes','hardFileBytes')){if($fresh[$name] -cne $p[$name]){throw 'Reviewed synthetic source/parent binding drift.'}}
    foreach($name in @('operations','rootPrivileges','actualProductionAccepted','existingVhdAccepted','physicalDiskAccepted')){if((ConvertTo-Json -InputObject $fresh[$name] -Compress) -cne (ConvertTo-Json -InputObject $p[$name] -Compress)){throw 'Reviewed synthetic operation/privilege scope differs.'}}
    if((ConvertTo-Json -InputObject $fresh.storage -Depth 12 -Compress) -cne (ConvertTo-Json -InputObject $p.storage -Depth 12 -Compress)){throw 'Reviewed Microsoft Storage binding drift.'}
    if([IO.DriveInfo]::new('C:\').AvailableFreeSpace -lt 1GB+[Revealfleet.Backup.ColdSyntheticVirtualDisk]::HardFileBytes){throw 'Conservative C synthetic capacity refused.'}
    $scope=[Revealfleet.Backup.ColdSyntheticVirtualDisk]::OpenPrivilegeScope();$owned=$lease=$transaction=$null;$failure=$null;$evidence=$null
    try {
        $user=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$dir=New-WslColdNamespaceDescriptor $user -PrivateData;$file=New-WslColdNamespaceDescriptor $user -PrivateData -File
        $evidence=[Revealfleet.Backup.ColdDirectorySecurityLease]::CreateSyntheticDirectory($p.evidenceParent,$dir)
        Write-WslBackupJsonNew (Join-Path $evidence 'reviewed-plan.json') $p
        $owned=[Revealfleet.Backup.ColdSyntheticVirtualDisk]::CreateNew($p.fixtureParent,$dir,$file)
        Write-WslBackupJsonNew (Join-Path $evidence 'created.json') @{workspace=$owned.Workspace;image=$owned.ImagePath;identifier=$owned.Identifier;virtualBytes=$fresh.virtualBytes;backingFileBytes=$owned.BackingFileBytes;productionAccepted=$false}
        $owned.Attach();Initialize-WslOwnedSyntheticVolume $owned $evidence $fresh.storage
        $systems=Get-WslOwnedSyntheticTree $owned -SystemOnly;Write-WslBackupJsonNew (Join-Path $evidence 'system-before-seed.json') @{tree=$systems}
        $seed=New-WslGenericPaddedRoot;Write-WslBackupJsonNew (Join-Path $evidence 'seed-proposed.json') $seed
        $owned.SeedRoot($seed)
        $systemAfter=Get-WslOwnedSyntheticTree $owned -SystemOnly;Write-WslBackupJsonNew (Join-Path $evidence 'system-after-seed.json') @{tree=$systemAfter}
        if($systemAfter -cne $systems){throw 'System-created children changed during fixture seeding; preserve exact delta, no acceptance.'}
        $root=$owned.VolumeRoot
        [void][IO.Directory]::CreateDirectory(($root+'ordinary'));[IO.File]::WriteAllBytes(($root+'ordinary\data.bin'),[byte[]](1,2,0,255))
        [Revealfleet.Backup.ColdSourceLease]::CreateProtectedDirectory(($root+'protected'),$dir);[IO.File]::WriteAllBytes(($root+'baseline.bin'),[byte[]](17,33,0,255))
        $beforeTree=Get-WslOwnedSyntheticTree $owned
        if((Get-WslOwnedSyntheticTree $owned) -cne $beforeTree){throw 'Synthetic baseline unstable; no retry.'}
        $lease=$owned.OpenRoot();$before=$lease.Read();Write-WslBackupJsonNew (Join-Path $evidence 'baseline.json') @{root=$before;tree=$beforeTree;fileIdentity=$lease.FileIdentity;attributes=$lease.Attributes}
        if($before.Control -ne 0x8004 -or $before.Layout.AclBytes -ne 248 -or $before.Layout.ParsedAclBytes -ne 68 -or $before.Layout.OwnerBytes -ne 28 -or $before.Layout.GroupBytes -ne 28){throw 'Faithful generic raw layout was not retained.'}
        $target=$before.Restricted($user);Write-WslBackupJsonNew (Join-Path $evidence 'restricted-proposed.json') $target
        $transaction=$lease.OpenSyntheticTransaction();$transaction.Replace($before.Sha256,[Convert]::FromBase64String($target.DescriptorBase64))
        Write-WslBackupJsonNew (Join-Path $evidence 'restricted-observed.json') @{root=$lease.Read();tree=(Get-WslOwnedSyntheticTree $owned)}
        if((Get-WslOwnedSyntheticTree $owned) -cne $beforeTree){throw 'Existing synthetic descendants changed after restriction.'}
        $rights=$owned.ProveOrdinaryRights($lease);Write-WslBackupJsonNew (Join-Path $evidence 'ordinary-rights.json') $rights
        [IO.File]::WriteAllBytes(($root+'new-child.bin'),[byte[]](1,2,0,255))
        $new=[IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($root+'new-child.bin'))
        $old=[IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($root+'baseline.bin'))
        if($new.GetSecurityDescriptorSddlForm('All') -cne $old.GetSecurityDescriptorSddlForm('All')){throw 'New-child inheritance differs.'}
        # Keep evidence of this new child; never delete even fixture files. The
        # restore comparison includes it in a new explicit rollback baseline.
        $rollbackTree=Get-WslOwnedSyntheticTree $owned;Write-WslBackupJsonNew (Join-Path $evidence 'before-rollback.json') @{tree=$rollbackTree}
        $transaction.Replace($target.Sha256,[Convert]::FromBase64String($before.DescriptorBase64))
        $after=$lease.Read();if($after.DescriptorSha256 -cne $before.DescriptorSha256 -or (Get-WslOwnedSyntheticTree $owned) -cne $rollbackTree -or $transaction.MutationCalls -ne 2){throw 'Exact volume-root raw rollback/descendant proof failed.'}
        Write-WslBackupJsonNew (Join-Path $evidence 'accepted-before-detach.json') @{root=$after;tree=$rollbackTree;mutationCalls=$transaction.MutationCalls;seedMutationCalls=$owned.SeedMutationCalls;syntheticVolumeAccepted=$true;realEAccepted=$false;productionAccepted=$false}
    } catch {
        $failure=$_
        if($evidence -and $owned -and $owned.VolumeRoot){
            try {
                if($lease){$observed=$lease.Read()}else{$probe=$owned.OpenRoot();try {$observed=$probe.Read()}finally {$probe.Dispose()}}
                Write-WslBackupJsonNew (Join-Path $evidence 'failed-root-observation.json') @{root=$observed;originalFailure=$failure.Exception.Message}
            } catch {try {Write-WslBackupJsonNew (Join-Path $evidence 'failed-root-observation-unavailable.json') @{reason=$_.Exception.Message;originalFailure=$failure.Exception.Message}}catch {}}
        }
        throw
    }
    finally {
        # Durable pending outcome precedes handle cleanup. Never let a second
        # evidence/teardown failure hide the original failed acceptance.
        if($evidence){try {Write-WslBackupJsonNew (Join-Path $evidence 'pending-detach.json') @{failure=$(if($failure){$failure.Exception.Message}else{$null});image=$(if($owned){$owned.ImagePath}else{$null});retainAll=$true}}catch {if(-not $failure){$failure=$_}}}
        if($transaction){$transaction.Dispose()};if($lease){$lease.Dispose()}
        try {if($owned){$owned.Detach();$owned.Dispose()};if($evidence){Write-WslBackupJsonNew (Join-Path $evidence 'detached.json') @{ownAttachmentDetached=$true;retained=$true;productionAccepted=$false}}}
        catch {if(-not $failure){$failure=$_};if($evidence){try {Write-WslBackupJsonNew (Join-Path $evidence 'teardown-failure.json') @{reason=$_.Exception.Message;state='Unconfirmed; stop, retain attempt, no global detach or lock breaking'}}catch {}}}
        finally {$scope.Dispose()}
        if($failure){throw $failure}
    }
    [pscustomobject]@{Evidence=$evidence;Image=$owned.ImagePath;SyntheticOnly=$true;ProductionAccepted=$false}
}

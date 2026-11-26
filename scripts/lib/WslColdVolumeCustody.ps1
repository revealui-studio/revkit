#Requires -Version 7.0
# Legacy exact-raw planning remains blocked. Explicit v2 permission custody
# uses reviewed v4 plans and retained journals; old descendants are never scanned.
. (Join-Path $PSScriptRoot 'WslBackup.ps1')
. (Join-Path $PSScriptRoot 'WindowsArtifactDeployment.ps1')
. (Join-Path $PSScriptRoot 'WslDiskIdentity.ps1')

function Assert-WslColdVolumeRoot {
    param([string]$Path)
    if(-not $IsWindows){throw 'Actual Windows NTFS root required.'}
    if($Path.Length -ne 3 -or 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.IndexOf($Path[0]) -lt 0 -or $Path.Substring(1) -cne ':\' -or [IO.Path]::GetFullPath($Path) -cne $Path){throw 'Canonical direct volume root only; no aliases or subdirectories.'}
}

function Get-WslColdCustodyCode {
    param([string]$SourceRoot,[string]$ManifestSha256,[switch]$RequireProtected)
    $source=[IO.Path]::GetFullPath($SourceRoot)
    if([IO.Path]::GetFullPath((Join-Path $source 'scripts/lib')) -cne $PSScriptRoot){throw 'Provisioner must execute from its reviewed package source root.'}
    $files=@(Get-RevkitWindowsArtifactFiles -SourceRoot $source -ExpectedSourceManifestSha256 $ManifestSha256)
    if($RequireProtected){[void](Assert-WslColdProtectedPath (Join-Path $source 'artifact-source-manifest.json'));foreach($f in $files){[void](Assert-WslColdProtectedPath $f.SourcePath)}}
    [pscustomobject]@{SourceCommit=$files[0].SourceCommit;Files=$files;SourceRoot=$source}
}

function Assert-WslColdNamespaceLeaf {
    param([string]$Name)
    if([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 64){throw 'Bounded direct-root namespace required.'}
    foreach($character in $Name.ToCharArray()){if(-not 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-'.Contains([string]$character)){throw 'Literal namespace characters required.'}}
    $reserved=@('CON','PRN','AUX','NUL')
    foreach($number in 1..9){$reserved+=('COM'+$number);$reserved+=('LPT'+$number)}
    if($Name.ToUpperInvariant() -in $reserved){throw 'Reserved device namespace refused.'}
}

function Assert-WslColdVolumeCustodyPolicy {
    param($Policy)
    Assert-WslRecoveryFields $Policy @('schemaVersion','kind','volumeRoot','hardware','namespace','trustedUserSid','evidenceDirectory','evidenceHardware','sourceRoot','sourceManifestSha256','namespaceAdditionalBytes','evidenceAdditionalBytes','reserveBytes') 'volume custody policy'
    Assert-WslRecoveryInteger $Policy.schemaVersion 1
    if($Policy.schemaVersion -ne 1 -or $Policy.kind -cne 'cold-volume-custody-v1'){throw 'Explicit cold-volume-custody-v1 required.'}
    Assert-WslColdVolumeRoot $Policy.volumeRoot
    Assert-WslColdNamespaceLeaf $Policy.namespace
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if($Policy.trustedUserSid -cne $user){throw 'Private owner must be the current reviewed Windows user.'}
    foreach($field in @('namespaceAdditionalBytes','evidenceAdditionalBytes')){Assert-WslRecoveryInteger $Policy[$field] 1}
    Assert-WslRecoveryInteger $Policy.reserveBytes 64GB
    Assert-WslBackupHash $Policy.sourceManifestSha256
}

function Assert-WslColdCustodyCapacity {
    param($Policy,$Files)
    [decimal]$payload=(Get-Item -LiteralPath (Join-Path $Policy.sourceRoot 'artifact-source-manifest.json') -Force).Length
    foreach($file in $Files){$payload+=(Get-Item -LiteralPath $file.SourcePath -Force).Length}
    if($Policy.namespaceAdditionalBytes -le $payload){throw 'Explicit positive namespace metadata/growth allowance beyond full payload required.'}
    $root=Assert-WslColdWindowsHardware $Policy.volumeRoot $Policy.hardware
    $evidence=Assert-WslColdWindowsHardware $Policy.evidenceDirectory $Policy.evidenceHardware
    if([decimal]$root.Free -lt [decimal]$Policy.namespaceAdditionalBytes+$Policy.reserveBytes -or [decimal]$evidence.Free -lt [decimal]$Policy.evidenceAdditionalBytes+$Policy.reserveBytes){throw 'Fresh per-filesystem custody payload/evidence/reserve capacity refused.'}
    return $payload
}

function Assert-WslColdCustodyGrowth {
    param($Policy,[decimal]$InitialRootFree,[decimal]$InitialEvidenceFree)
    $root=Assert-WslColdWindowsHardware $Policy.volumeRoot $Policy.hardware
    $evidence=Assert-WslColdWindowsHardware $Policy.evidenceDirectory $Policy.evidenceHardware
    if($root.Free -lt $Policy.reserveBytes -or $evidence.Free -lt $Policy.reserveBytes -or
        $InitialRootFree-$root.Free -gt $Policy.namespaceAdditionalBytes -or $InitialEvidenceFree-$evidence.Free -gt $Policy.evidenceAdditionalBytes){throw 'Observed custody growth/reserve exceeded; retain all attempts, no activation.'}
}

function Assert-WslColdCustodyInheritanceContract {
    param($Plan)
    Initialize-WslColdWorkerProtocol
    Assert-WslRecoveryFields $Plan.childInheritance @('profile','sha256') 'child inheritance contract'
    $before=[Revealfleet.Backup.ColdSecuritySnapshot]::new([Convert]::FromBase64String($Plan.before.DescriptorBase64))
    $after=[Revealfleet.Backup.ColdSecuritySnapshot]::new([Convert]::FromBase64String($Plan.after.DescriptorBase64))
    $before.RequireReplacementScope($after);$after.RequireReplacementScope($before)
    Assert-WslRecoveryFields $Plan.rawLayout @('profile','before','after') 'raw layout contract'
    if($Plan.rawLayout.profile -cne 'exact-raw-acl-capacity-v1' -or $Plan.rawLayout.before -cne $before.DescriptorSha256 -or $Plan.rawLayout.after -cne $after.DescriptorSha256){throw 'Exact raw layout binding differs.'}
    if($Plan.childInheritance.profile -cne 'unchanged-child-inheritance-v1' -or
        $Plan.childInheritance.sha256 -cne $before.ChildInheritanceSha256 -or
        $Plan.childInheritance.sha256 -cne $after.ChildInheritanceSha256 -or
        $before.Sha256 -cne $Plan.before.Sha256 -or $after.Sha256 -cne $Plan.after.Sha256 -or
        $before.Restricted($Plan.policy.trustedUserSid).Sha256 -cne $after.Sha256){throw 'Reviewed inheritance/descriptor transformation differs.'}
}

function Get-WslColdVolumeCustodyPlan {
    param($Policy)
    if($Policy.kind -ceq 'cold-volume-permission-custody-v2'){return Get-WslColdPermissionCustodyPlan $Policy}
    Assert-WslColdVolumeCustodyPolicy $Policy
    $user=$Policy.trustedUserSid
    $code=Get-WslColdCustodyCode $Policy.sourceRoot $Policy.sourceManifestSha256
    [void](Assert-WslColdCustodyCapacity $Policy $code.Files)
    $volume=Assert-WslColdWindowsHardware $Policy.volumeRoot $Policy.hardware
    $evidence=Assert-WslColdWindowsHardware $Policy.evidenceDirectory $Policy.evidenceHardware
    if($volume.Domain -ceq $evidence.Domain -or $Policy.hardware.serial -ceq $Policy.evidenceHardware.serial){throw 'Before/after evidence must be on an independently reviewed different hardware/volume.'}
    [void](Assert-WslColdProtectedPath $Policy.evidenceDirectory -Directory -PrivateData)
    $namespace=Join-Path $Policy.volumeRoot $Policy.namespace
    if(Test-Path -LiteralPath $namespace){throw 'Namespace collision; no adoption, overwrite or reparse.'}
    Initialize-WslColdWorkerProtocol
    $lease=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($Policy.volumeRoot)
    $safeEvidence=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($Policy.evidenceDirectory)
    try {
        $before=$lease.Read();$after=$before.Restricted($user);$evidenceDescriptor=$safeEvidence.Read()
        [ordered]@{schemaVersion=3;kind='cold-volume-custody-plan-v3';intent='ApplyOrRollback';policy=$Policy;
            sourceCommit=$code.SourceCommit;sourceFiles=@($code.Files|ForEach-Object {@{path=$_.RelativePath;sha256=$_.Sha256}});
            rootFileIdentity=$lease.FileIdentity;rootAttributes=$lease.Attributes;before=$before;after=$after;
            evidenceFileIdentity=$safeEvidence.FileIdentity;evidenceDescriptorSha256=$evidenceDescriptor.Sha256;
            createdAt=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();expiresAt=[DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds();
            childInheritance=@{profile='unchanged-child-inheritance-v1';sha256=$before.ChildInheritanceSha256};
            rawLayout=@{profile='exact-raw-acl-capacity-v1';before=$before.DescriptorSha256;after=$after.DescriptorSha256};
            namespacePath=$namespace;sourceOrWorkerActivated=$false;descendantsEnumerated=$false;existingChildParentDeletionFallbackRemoved=$true;
            api='UNACCEPTED root-only filesystem security contract; actual Windows child/control drift retained';
            privileges='Scoped thread-token SeRestorePrivilege required BEFORE mutation; no account/process trust change';
            sacl='Not read or selected by mutation API';group='Observed and unchanged';
            rollback='Root OWNER+DACL only, same volume/root/current after hash. New namespace/evidence retained. Never overwrite later edits.'}
    } finally {$safeEvidence.Dispose();$lease.Dispose()}
}

function New-WslColdNamespaceDescriptor {
    param([string]$UserSid,[switch]$PrivateData,[switch]$File)
    $acl=if($File){[Security.AccessControl.FileSecurity]::new()}else{[Security.AccessControl.DirectorySecurity]::new()}
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach($sid in @('S-1-5-18','S-1-5-32-544')){
        $rule=if($File){[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','Allow')}else{[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow')}
        [void]$acl.AddAccessRule($rule)
    }
    $sid=if($PrivateData){$UserSid}else{'S-1-5-32-545'}
    $rights=if($PrivateData){'FullControl'}else{'ReadAndExecute'}
    $rule=if($File){[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),$rights,'Allow')}else{[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),$rights,'ContainerInherit,ObjectInherit','None','Allow')}
    [void]$acl.AddAccessRule($rule)
    return ,$acl.GetSecurityDescriptorBinaryForm()
}

function Install-WslColdVolumeNamespaces {
    param($Plan,$Files,[string]$EvidenceAttempt)
    $root=$Plan.namespacePath;$user=$Plan.policy.trustedUserSid
    $public=New-WslColdNamespaceDescriptor $user
    $private=New-WslColdNamespaceDescriptor $user -PrivateData
    $fileAcl=New-WslColdNamespaceDescriptor $user -File
    # Every created directory is exclusive; only paths created by THIS call may
    # be reused while copying. Nothing pre-existing is adopted or recursed.
    $created=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    function New-ColdDirectory([string]$Path,[byte[]]$Descriptor) {
        if($created.Contains($Path)){return}
        [Revealfleet.Backup.ColdSourceLease]::CreateProtectedDirectory($Path,$Descriptor)
        [void]$created.Add($Path)
    }
    New-ColdDirectory $root $public
    $authority=Join-Path $root 'authority';$data=Join-Path $root 'private'
    New-ColdDirectory $authority $public;New-ColdDirectory $data $private
    $release=Join-Path $authority $Plan.sourceCommit;New-ColdDirectory $release $public
    foreach($f in $Files){
        $destination=Join-Path $release $f.RelativePath
        $relativeDirectory=[IO.Path]::GetDirectoryName($f.RelativePath)
        $directory=$release
        foreach($part in $relativeDirectory.Replace('\','/').Split('/',[StringSplitOptions]::RemoveEmptyEntries)){$directory=Join-Path $directory $part;New-ColdDirectory $directory $public}
        [Revealfleet.Backup.ColdDirectorySecurityLease]::CopyNewProtectedFile($f.SourcePath,$destination,$fileAcl)
        [void](Assert-WslColdProtectedPath $destination)
        if((Get-FileHash -LiteralPath $destination).Hash.ToLowerInvariant() -cne $f.Sha256){throw 'New code copy differs; partial namespace retained.'}
    }
    $manifest=Join-Path $release 'artifact-source-manifest.json'
    [Revealfleet.Backup.ColdDirectorySecurityLease]::CopyNewProtectedFile((Join-Path $Plan.policy.sourceRoot 'artifact-source-manifest.json'),$manifest,$fileAcl)
    if((Get-FileHash -LiteralPath $manifest).Hash.ToLowerInvariant() -cne $Plan.policy.sourceManifestSha256){throw 'New authority manifest differs; retain partial namespace.'}
    [void](Assert-WslColdProtectedPath $manifest)
    [void](Assert-WslColdProtectedPath $data -Directory -PrivateData)
    [void](Assert-WslColdProtectedPath $authority -Directory)
    Write-WslBackupJsonNew (Join-Path $EvidenceAttempt 'namespaces-verified.json') @{authority=$release;privateData=$data;activated=$false;existingDescendantDescriptorsRewritten=$false;parentDeletionFallbackRemoved=$true}
    [pscustomobject]@{Authority=$release;PrivateData=$data;Activated=$false}
}

function Invoke-WslColdVolumeCustody {
    [CmdletBinding()]
    param([ValidateSet('Apply','Rollback')][string]$Phase,[string]$PlanPath,[string]$ReviewedPlanSha256)
    if(-not $IsWindows){throw 'Actual Windows required; no native mutation fallback.'}
    Assert-WslBackupHash $ReviewedPlanSha256
    $document=Read-WslRecoveryDocument $PlanPath
    if($document.Sha256 -cne $ReviewedPlanSha256){throw 'Plan differs from independent review.'}
    $p=$document.Value
    if($p.kind -ceq 'cold-volume-permission-custody-plan-v4'){return Invoke-WslColdPermissionCustody $Phase $PlanPath $ReviewedPlanSha256}
    Assert-WslRecoveryFields $p @('schemaVersion','kind','intent','policy','sourceCommit','sourceFiles','rootFileIdentity','rootAttributes','before','after','evidenceFileIdentity','evidenceDescriptorSha256','createdAt','expiresAt','namespacePath','sourceOrWorkerActivated','descendantsEnumerated','existingChildParentDeletionFallbackRemoved','api','privileges','sacl','group','rollback','childInheritance','rawLayout') 'reviewed custody plan'
    if($p.schemaVersion -ne 3 -or $p.kind -cne 'cold-volume-custody-plan-v3' -or $p.expiresAt -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -or $p.expiresAt-$p.createdAt -gt 3600){throw 'Fresh versioned root plan required.'}
    if($p.intent -cnotin @('ApplyOrRollback','RollbackOnly') -or ($p.intent -ceq 'RollbackOnly' -and $Phase -cne 'Rollback')){throw 'Reviewed plan phase differs.'}
    Assert-WslColdVolumeCustodyPolicy $p.policy
    Assert-WslColdCustodyInheritanceContract $p
    if($p.namespacePath -cne (Join-Path $p.policy.volumeRoot $p.policy.namespace) -or $p.policy.trustedUserSid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'Root namespace/current owner binding changed.'}
    $code=Get-WslColdCustodyCode $p.policy.sourceRoot $p.policy.sourceManifestSha256 -RequireProtected
    if($code.SourceCommit -cne $p.sourceCommit -or $code.Files.Count -ne $p.sourceFiles.Count){throw 'Reviewed source changed.'}
    $expected=@{};foreach($row in $p.sourceFiles){if($expected.ContainsKey($row.path)){throw 'Duplicate reviewed source'};$expected[$row.path]=$row.sha256}
    foreach($row in $code.Files){if($expected[$row.RelativePath] -cne $row.Sha256){throw 'Reviewed source changed.'}}
    if($Phase -ceq 'Apply'){[void](Assert-WslColdCustodyCapacity $p.policy $code.Files)}
    if($Phase -ceq 'Apply' -and (Test-Path -LiteralPath $p.namespacePath)){throw 'Namespace collision before mutation.'}
    $initialRoot=Assert-WslColdWindowsHardware $p.policy.volumeRoot $p.policy.hardware
    $evidence=Assert-WslColdWindowsHardware $p.policy.evidenceDirectory $p.policy.evidenceHardware
    if($evidence.Domain -ceq $p.policy.hardware.volumeUuid -or $p.policy.evidenceHardware.serial -ceq $p.policy.hardware.serial){throw 'Independent evidence custody required.'}
    [void](Assert-WslColdProtectedPath $p.policy.evidenceDirectory -Directory -PrivateData)
    Initialize-WslColdWorkerProtocol
    throw 'Root-only filesystem security contract unaccepted after actual Windows control/child drift; no mutation admitted.'

}

function Get-WslColdVolumeRollbackPlan {
    param([string]$OriginalPlanPath,[string]$ReviewedOriginalPlanSha256,[string]$ApplyReceiptPath,[string]$ReviewedApplyReceiptSha256)
    if(-not $IsWindows){throw 'Actual Windows required.'}
    Assert-WslBackupHash $ReviewedOriginalPlanSha256
    $doc=Read-WslRecoveryDocument $OriginalPlanPath
    if($doc.Sha256 -cne $ReviewedOriginalPlanSha256){throw 'Original review digest differs.'}
    $p=$doc.Value
    if($p.kind -ceq 'cold-volume-permission-custody-plan-v4'){return Get-WslColdPermissionRollbackPlan $OriginalPlanPath $ReviewedOriginalPlanSha256 $ApplyReceiptPath $ReviewedApplyReceiptSha256}
    if($ApplyReceiptPath -or $ReviewedApplyReceiptSha256){throw 'Legacy raw rollback does not accept permission receipts.'}
    if($p.kind -cne 'cold-volume-custody-plan-v3' -or $p.schemaVersion -ne 3){throw 'Original versioned root plan required.'}
    Assert-WslColdVolumeCustodyPolicy $p.policy
    Assert-WslColdCustodyInheritanceContract $p
    if($p.policy.trustedUserSid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value){throw 'Current owner changed.'}
    [void](Get-WslColdCustodyCode $p.policy.sourceRoot $p.policy.sourceManifestSha256 -RequireProtected)
    [void](Assert-WslColdWindowsHardware $p.policy.volumeRoot $p.policy.hardware)
    $lease=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($p.policy.volumeRoot)
    try {
        if($lease.FileIdentity -cne $p.rootFileIdentity -or $lease.Read().Sha256 -cne $p.after.Sha256){throw 'Later root edit/substitution: rollback plan refused.'}
        $p.intent='RollbackOnly'
        $p.createdAt=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();$p.expiresAt=$p.createdAt+3600
        return $p # NEW output must be independently reviewed, saved and hashed.
    } finally {$lease.Dispose()}
}

# Explicit production permission profile. The legacy exact-raw path above stays
# blocked. No synthetic fixture/API is an operational dependency or admission.
function Assert-WslColdCanonicalDirectory {
    param([string]$Path)
    if($Path.Length -lt 3 -or 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.IndexOf($Path[0]) -lt 0 -or $Path.Substring(1,2) -cne ':\' -or $Path.IndexOf(':',2) -ge 0 -or [IO.Path]::GetFullPath($Path) -cne $Path -or ($Path.Length -gt 3 -and $Path.EndsWith('\'))){throw 'Canonical local directory required; no relative/UNC/ADS/alias path.'}
}
function Assert-WslColdHeldCustodyVolume {
    param($Lease,[string]$Uuid)
    if($Uuid -cne ([guid]$Uuid).ToString('D') -or $Lease.VolumeGuidPath -cne ('\\?\Volume{'+$Uuid+'}\')){throw 'Held/native hardware volume binding differs.'}
}
function Get-WslColdCustodyCurrentUser { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
function Assert-WslColdPermissionPolicy {
    param($Policy)
    $fields=@('schemaVersion','kind','fidelityProfile','volumeRoot','hardware','namespace','trustedUserSid','evidenceDirectory','evidenceHardware','sourceRoot','sourceManifestSha256','namespaceAdditionalBytes','evidenceAdditionalBytes','reserveBytes')
    Assert-WslRecoveryFields $Policy $fields 'permission custody policy'
    Assert-WslRecoveryInteger $Policy.schemaVersion 2
    if($Policy.schemaVersion -ne 2 -or $Policy.kind -cne 'cold-volume-permission-custody-v2' -or $Policy.fidelityProfile -cne 'permission-ace-zero-unused-v1'){throw 'Explicit production permission policy v2 required.'}
    Assert-WslColdVolumeRoot $Policy.volumeRoot;Assert-WslColdNamespaceLeaf $Policy.namespace
    Assert-WslColdCanonicalDirectory $Policy.sourceRoot;Assert-WslColdCanonicalDirectory $Policy.evidenceDirectory
    if($Policy.trustedUserSid -cne (Get-WslColdCustodyCurrentUser)){throw 'Reviewed current owner differs.'}
    Assert-WslBackupHash $Policy.sourceManifestSha256
    foreach($n in @('namespaceAdditionalBytes','evidenceAdditionalBytes')){Assert-WslRecoveryInteger $Policy[$n] 1}
    if($Policy.evidenceAdditionalBytes -lt 8MB){throw 'At least8MiB independently reserved evidence allowance required.'}
    Assert-WslRecoveryInteger $Policy.reserveBytes 64GB
}
function Get-WslColdCustodyHardware {
    param([string]$Path,$Expected)
    $root=[IO.Path]::GetPathRoot($Path)
    if($root.Length -ne 3 -or $root[1] -ne ':'){throw 'Local hardware path required.'}
    $parts=@(Storage\Get-Partition -DriveLetter $root[0] -ErrorAction Stop)
    if($parts.Count -ne 1){throw 'Ambiguous custody partition.'}
    $disks=@(Storage\Get-Disk -Partition $parts[0] -ErrorAction Stop);$volumes=@($parts[0]|Storage\Get-Volume -ErrorAction Stop)
    if($disks.Count -ne 1 -or $volumes.Count -ne 1){throw 'Ambiguous custody disk/filesystem.'}
    $domain=Assert-WslColdVolumeObservation $disks[0] $parts[0] $volumes[0] $Expected
    [pscustomobject]@{Domain=$domain;Free=[IO.DriveInfo]::new($root).AvailableFreeSpace;Root=$root}
}
function Get-WslColdPermissionPair {
    param($Plan)
    Initialize-WslColdWorkerProtocol
    $a=[Revealfleet.Backup.ColdSecuritySnapshot]::new([Convert]::FromBase64String($Plan.before.DescriptorBase64))
    $b=[Revealfleet.Backup.ColdSecuritySnapshot]::new([Convert]::FromBase64String($Plan.after.DescriptorBase64))
    $ai=[Revealfleet.Backup.ColdPermissionIdentity]::new([Convert]::FromBase64String($a.DescriptorBase64));$bi=[Revealfleet.Backup.ColdPermissionIdentity]::new([Convert]::FromBase64String($b.DescriptorBase64))
    $a.RequireReplacementScope($b);$b.RequireReplacementScope($a)
    Assert-WslRecoveryFields $Plan.fidelity @('profile','beforeRawSha256','requestedRawSha256','requestedPermissionSha256','childInheritanceSha256','rawByteRestorationPromised','sacl') 'permission fidelity'
    if($a.DescriptorSha256 -cne $Plan.before.DescriptorSha256 -or $b.DescriptorSha256 -cne $Plan.after.DescriptorSha256 -or
        $a.Restricted($Plan.policy.trustedUserSid).DescriptorSha256 -cne $b.DescriptorSha256 -or $Plan.fidelity.profile -cne 'permission-ace-zero-unused-v1' -or
        $Plan.fidelity.beforeRawSha256 -cne $ai.RawSha256 -or $Plan.fidelity.requestedRawSha256 -cne $bi.RawSha256 -or $Plan.fidelity.requestedPermissionSha256 -cne $bi.UsedIdentitySha256 -or
        $Plan.fidelity.childInheritanceSha256 -cne $a.ChildInheritanceSha256 -or $Plan.fidelity.childInheritanceSha256 -cne $b.ChildInheritanceSha256 -or
        $Plan.fidelity.rawByteRestorationPromised -isnot [bool] -or $Plan.fidelity.rawByteRestorationPromised -cne $false -or $Plan.fidelity.sacl -cne 'explicit-security-components-v1:no-sacl:0x1ff'){throw 'Permission pair/forward/inverse/raw binding differs.'}
    return @{Before=$a;After=$b}
}
function Get-WslColdPermissionCustodyPlan {
    param($Policy)
    Assert-WslColdPermissionPolicy $Policy
    $code=Get-WslColdCustodyCode $Policy.sourceRoot $Policy.sourceManifestSha256 -RequireProtected
    Initialize-WslColdWorkerProtocol
    $storage=Get-WslColdStoragePreflight
    $root=Get-WslColdCustodyHardware $Policy.volumeRoot $Policy.hardware;$evidence=Get-WslColdCustodyHardware $Policy.evidenceDirectory $Policy.evidenceHardware
    if($root.Domain -ceq $evidence.Domain -or $Policy.hardware.serial -ceq $Policy.evidenceHardware.serial){throw 'Different evidence hardware AND filesystem required.'}
    # Parent is admin authority, not a user-writable private data leaf. Each NEW
    # attempt is created protected/private with current user read-only access.
    [void](Assert-WslColdProtectedPath $Policy.evidenceDirectory -Directory)
    [void](Assert-WslColdPermissionCapacity @{policy=$Policy} $code.Files)
    $namespace=Join-Path $Policy.volumeRoot $Policy.namespace
    if(Test-Path -LiteralPath $namespace){throw 'NEW namespace collision; no adoption.'}
    $r=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($Policy.volumeRoot);$e=$null
    try {
        $e=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($Policy.evidenceDirectory)
        Assert-WslColdHeldCustodyVolume $r $Policy.hardware.volumeUuid;Assert-WslColdHeldCustodyVolume $e $Policy.evidenceHardware.volumeUuid
        $a=$r.Read();$b=$a.Restricted($Policy.trustedUserSid);$bi=[Revealfleet.Backup.ColdPermissionIdentity]::new([Convert]::FromBase64String($b.DescriptorBase64))
        [void][Revealfleet.Backup.ColdPermissionIdentity]::new([Convert]::FromBase64String($a.DescriptorBase64))
        [ordered]@{schemaVersion=4;kind='cold-volume-permission-custody-plan-v4';intent='ApplyOnly';transactionId=[guid]::NewGuid().ToString('D');policy=$Policy;
            sourceCommit=$code.SourceCommit;sourceFiles=@($code.Files|ForEach-Object {@{path=$_.RelativePath;sha256=$_.Sha256}});storage=$storage;
            rootFileIdentity=$r.FileIdentity;rootAttributes=$r.Attributes;before=$a;after=$b;evidenceFileIdentity=$e.FileIdentity;evidenceRawSha256=$e.Read().DescriptorSha256;
            namespacePath=$namespace;bootstrap=$a.SecurityWriterAdmission();createdAt=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();expiresAt=[DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds();
            fidelity=@{profile=$Policy.fidelityProfile;beforeRawSha256=$a.DescriptorSha256;requestedRawSha256=$b.DescriptorSha256;requestedPermissionSha256=$bi.UsedIdentitySha256;childInheritanceSha256=$a.ChildInheritanceSha256;rawByteRestorationPromised=$false;sacl='explicit-security-components-v1:no-sacl:0x1ff'};
            authority='Independent exact plan review PLUS actual elevated current owner; no receipt/test flag grants authority';
            scope='NTFS root OWNER+DACL only; unchanged control/group/child templates; no old descendant enumeration/mutation';
            privileges=@('Scoped thread-token SeRestorePrivilege','Scoped thread-token SeSecurityPrivilege for read-only SACL refusal');
            rollback=$null;productionActivated=$false;existingChildrenPrivatized=$false}
    } finally {if($e){$e.Dispose()};$r.Dispose()}
}
function Assert-WslColdPermissionPlan {
    param($Plan,[string]$Phase,[switch]$OriginalRollbackReference)
    Assert-WslRecoveryFields $Plan @('schemaVersion','kind','intent','transactionId','policy','sourceCommit','sourceFiles','storage','rootFileIdentity','rootAttributes','before','after','evidenceFileIdentity','evidenceRawSha256','namespacePath','bootstrap','createdAt','expiresAt','fidelity','authority','scope','privileges','rollback','productionActivated','existingChildrenPrivatized') 'permission custody plan'
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach($n in @('schemaVersion','createdAt','expiresAt')){Assert-WslRecoveryInteger $Plan[$n] 1}
    if($Plan.schemaVersion -ne 4 -or $Plan.kind -cne 'cold-volume-permission-custody-plan-v4' -or $Plan.intent -cne ($Phase+'Only') -or (-not $OriginalRollbackReference -and $Plan.expiresAt -le $now) -or $Plan.createdAt -gt $now -or $Plan.expiresAt-$Plan.createdAt -gt 3600 -or $Plan.expiresAt -le $Plan.createdAt){throw 'Fresh exact-phase production permission plan required.'}
    if($Plan.transactionId -cne ([guid]$Plan.transactionId).ToString('D')){throw 'Exact transaction UUID required.'}
    Assert-WslColdPermissionPolicy $Plan.policy
    if($Plan.productionActivated -isnot [bool] -or $Plan.existingChildrenPrivatized -isnot [bool]){throw 'Exact boolean scope fields required.'}
    if($Plan.namespacePath -cne (Join-Path $Plan.policy.volumeRoot $Plan.policy.namespace) -or $Plan.productionActivated -cne $false -or $Plan.existingChildrenPrivatized -cne $false){throw 'Reviewed operation scope differs.'}
    $pair=Get-WslColdPermissionPair $Plan
    if((ConvertTo-Json $pair.Before.SecurityWriterAdmission() -Compress) -cne (ConvertTo-Json $Plan.bootstrap -Compress)){throw 'Reviewed security-writer disposition differs.'}
    if($Phase -ceq 'Apply' -and $null -ne $Plan.rollback){throw 'Forward plan cannot carry rollback capability.'}
    if($Phase -ceq 'Rollback') {Assert-WslRecoveryFields $Plan.rollback @('originalPlanPath','originalPlanSha256','applyReceiptPath','applyReceiptSha256','observedAfterBase64','observedAfterRawSha256','namespaceSnapshot') 'fresh rollback review'}
}
function Read-WslColdPermissionReceipt {
    param($OriginalPlan,[string]$OriginalDigest,[string]$Path,[string]$Digest)
    Assert-WslBackupHash $Digest
    [void](Assert-WslColdProtectedPath $Path);[void](Assert-WslColdProtectedPath $Path -PrivateData)
    $doc=Read-WslRecoveryDocument $Path
    if($doc.Sha256 -cne $Digest){throw 'Independent apply receipt review differs.'};$v=$doc.Value
    Assert-WslRecoveryFields $v @('profile','bindingScope','context','outcome','proof') 'observed apply receipt'
    if($v.outcome -cnotin @('Accepted','ObservedOnly') -or $v.bindingScope -cne 'ProductionVolume' -or $v.profile -cne 'cold-volume-permission-custody-v2' -or $v.context.reviewedPlanSha256 -cne $OriginalDigest -or $v.context.transactionId -cne $OriginalPlan.transactionId -or $v.context.sourceCommit -cne $OriginalPlan.sourceCommit -or $v.context.phase -cne 'Apply' -or $v.context.rootFileIdentity -cne $OriginalPlan.rootFileIdentity){throw 'Receipt is not bound to independently reviewed original apply plan.'}
    $before=[Revealfleet.Backup.ColdSecuritySnapshot]::new([Convert]::FromBase64String($v.proof.Before.DescriptorBase64));$requested=[Revealfleet.Backup.ColdSecuritySnapshot]::new([Convert]::FromBase64String($v.proof.Requested.DescriptorBase64));$observed=[Revealfleet.Backup.ColdSecuritySnapshot]::new([Convert]::FromBase64String($v.proof.Observed.DescriptorBase64))
    if($before.DescriptorSha256 -cne $OriginalPlan.before.DescriptorSha256 -or $requested.DescriptorSha256 -cne $OriginalPlan.after.DescriptorSha256 -or $observed.DescriptorSha256 -cne $v.proof.Observed.DescriptorSha256){throw 'Apply receipt raw chain differs.'}
    [void][Revealfleet.Backup.ColdPermissionIdentity]::Compare([Convert]::FromBase64String($requested.DescriptorBase64),[Convert]::FromBase64String($observed.DescriptorBase64))
    return $observed
}
function Get-WslColdRetainedNamespace {
    param($Plan,$Files)
    if(-not (Test-Path -LiteralPath $Plan.namespacePath)){return '[]'}
    $expected=@{};$prefix='authority/'+$Plan.sourceCommit
    $expected['authority']=$null;$expected['private']=$null;$expected[$prefix]=$null
    foreach($file in $Files){$relative=$prefix+'/'+$file.RelativePath.Replace('\','/');$expected[$relative]=$file.Sha256;$at=[IO.Path]::GetDirectoryName($relative).Replace('\','/');while($at){$expected[$at]=$null;$at=[IO.Path]::GetDirectoryName($at);if($at){$at=$at.Replace('\','/')}}}
    $expected[$prefix+'/artifact-source-manifest.json']=$Plan.policy.sourceManifestSha256
    $rootItem=Get-Item -LiteralPath $Plan.namespacePath -Force
    if(-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Retained namespace root type/reparse drift.'}
    $namespaceLease=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($Plan.namespacePath)
    try {
    $rootSnapshot=$namespaceLease.Read();$rows=[Collections.Generic.List[object]]::new()
    $rows.Add([ordered]@{path='';identity=$namespaceLease.FileIdentity;descriptor=$rootSnapshot.DescriptorBase64;directory=$true;sha256='';created=$rootItem.CreationTimeUtc.Ticks;written=$rootItem.LastWriteTimeUtc.Ticks})
    $queue=[Collections.Generic.Queue[string]]::new();$queue.Enqueue($Plan.namespacePath);[long]$bytes=0
    while($queue.Count){$parent=$queue.Dequeue();foreach($path in [IO.Directory]::GetFileSystemEntries($parent)){
        if($rows.Count -ge 512){throw 'Retained namespace bound exceeded.'};$item=Get-Item -LiteralPath $path -Force
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Retained namespace reparse refused.'}
        $relative=$item.FullName.Substring($Plan.namespacePath.Length+1).Replace('\','/')
        if(-not $expected.ContainsKey($relative)){throw 'Unknown retained namespace/private data; rollback requires separate storage-owner disposition, no read/delete.'}
        if($item.PSIsContainer){if($null -ne $expected[$relative]){throw 'Namespace file/directory drift.'};$queue.Enqueue($item.FullName);$digest=''}
        else{if($null -eq $expected[$relative] -or $item.Length -gt 8MB -or $bytes+$item.Length -gt 16MB){throw 'Retained namespace type/data bound refused.'};$bytes+=$item.Length;$digest=(Get-FileHash -LiteralPath $item.FullName).Hash.ToLowerInvariant();if($digest -cne $expected[$relative]){throw 'Retained namespace public source drift.'}}
        $acl=Get-Acl -LiteralPath $item.FullName;$item.Refresh();$rows.Add([ordered]@{path=$relative;directory=[bool]$item.PSIsContainer;sha256=$digest;descriptor=[Convert]::ToBase64String($acl.GetSecurityDescriptorBinaryForm());created=$item.CreationTimeUtc.Ticks;written=$item.LastWriteTimeUtc.Ticks})
    }}
    return (ConvertTo-Json -InputObject @($rows|Sort-Object path -CaseSensitive) -Depth 8 -Compress)
    } finally {$namespaceLease.Dispose()}
}
function Get-WslColdPermissionRollbackPlan {
    param([string]$OriginalPlanPath,[string]$OriginalDigest,[string]$ApplyReceiptPath,[string]$ReceiptDigest)
    Assert-WslBackupHash $OriginalDigest;Assert-WslBackupHash $ReceiptDigest
    $doc=Read-WslRecoveryDocument $OriginalPlanPath
    if($doc.Sha256 -cne $OriginalDigest){throw 'Original independently reviewed plan differs.'};$p=$doc.Value
    Assert-WslColdPermissionPlan $p 'Apply' -OriginalRollbackReference
    # An expired APPLY plan cannot authorize a new apply, but its exact reviewed
    # bytes are still the rollback baseline. Caller refreshes expiry below only
    # AFTER receipt/current state/identity/source checks. See validator override.
    $code=Get-WslColdCustodyCode $p.policy.sourceRoot $p.policy.sourceManifestSha256 -RequireProtected
    [void](Get-WslColdStoragePreflight);[void](Get-WslColdCustodyHardware $p.policy.volumeRoot $p.policy.hardware);[void](Get-WslColdCustodyHardware $p.policy.evidenceDirectory $p.policy.evidenceHardware)
    $observed=Read-WslColdPermissionReceipt $p $OriginalDigest $ApplyReceiptPath $ReceiptDigest
    $lease=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($p.policy.volumeRoot)
    try {
        if($lease.FileIdentity -cne $p.rootFileIdentity -or $lease.Attributes -ne $p.rootAttributes -or $lease.Read().DescriptorSha256 -cne $observed.DescriptorSha256){throw 'Later raw edit/root substitution; rollback plan refused.'}
        $p.intent='RollbackOnly';$p.createdAt=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();$p.expiresAt=$p.createdAt+3600;$p.transactionId=[guid]::NewGuid().ToString('D')
        $p.rollback=@{originalPlanPath=[IO.Path]::GetFullPath($OriginalPlanPath);originalPlanSha256=$OriginalDigest;applyReceiptPath=[IO.Path]::GetFullPath($ApplyReceiptPath);applyReceiptSha256=$ReceiptDigest;observedAfterBase64=$observed.DescriptorBase64;observedAfterRawSha256=$observed.DescriptorSha256;namespaceSnapshot=(Get-WslColdRetainedNamespace $p $code.Files)}
        return $p
    } finally {$lease.Dispose()}
}
function New-WslColdCustodyJournalDescriptor {
    param([string]$UserSid,[switch]$File)
    $acl=if($File){[Security.AccessControl.FileSecurity]::new()}else{[Security.AccessControl.DirectorySecurity]::new()};$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach($sid in @('S-1-5-18','S-1-5-32-544')){
        $rule=if($File){[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','Allow')}else{[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow')};[void]$acl.AddAccessRule($rule)
    }
    $rule=if($File){[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($UserSid),'ReadAndExecute','Allow')}else{[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($UserSid),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')};[void]$acl.AddAccessRule($rule)
    return ,$acl.GetSecurityDescriptorBinaryForm()
}
function Assert-WslColdPermissionCapacity {
    param($Plan,$Files,$Initial=$null)
    $p=$Plan.policy;$root=Get-WslColdCustodyHardware $p.volumeRoot $p.hardware;$e=Get-WslColdCustodyHardware $p.evidenceDirectory $p.evidenceHardware
    if($root.Domain -ceq $e.Domain -or $p.hardware.serial -ceq $p.evidenceHardware.serial){throw 'Evidence hardware/volume independence lost.'}
    [decimal]$bytes=(Get-Item -LiteralPath (Join-Path $p.sourceRoot 'artifact-source-manifest.json')).Length
    foreach($f in $Files){$bytes+=(Get-Item -LiteralPath $f.SourcePath).Length}
    if($p.namespaceAdditionalBytes -le $bytes -or $root.Free -lt $p.reserveBytes+$p.namespaceAdditionalBytes -or $e.Free -lt $p.reserveBytes+$p.evidenceAdditionalBytes){throw 'Fresh full-payload/positive-overhead/independent evidence reserve refused.'}
    if($Initial -and ($Initial.rootFree-$root.Free -gt $p.namespaceAdditionalBytes -or $Initial.evidenceFree-$e.Free -gt $p.evidenceAdditionalBytes)){throw 'Observed custody growth exceeded reviewed allowance.'}
    return @{rootFree=$root.Free;evidenceFree=$e.Free;payloadBytes=$bytes}
}
function Invoke-WslColdPermissionCustody {
    param([string]$Phase,[string]$PlanPath,[string]$ReviewedPlanSha256)
    if(-not $IsWindows){throw 'Actual Windows required; no native production fallback.'}
    Assert-WslBackupHash $ReviewedPlanSha256
    Initialize-WslColdWorkerProtocol
    $held=[Collections.Generic.List[object]]::new();$scope=$root=$parent=$attemptLease=$transaction=$null;$failure=$null;$attempt=$null;$applied=$false
    try {
        # Hold the reviewed plan while reading it; a path/hash sampled once is
        # not permission to accept later input replacement.
        $planIdentity=[Revealfleet.Backup.ColdSourceLease]::InspectIdentityForReview([IO.Path]::GetFullPath($PlanPath))
        $planStream=[IO.File]::Open($PlanPath,'Open','Read','Read');$held.Add(@{path=[IO.Path]::GetFullPath($PlanPath);identity=$planIdentity;stream=$planStream;sha256=$ReviewedPlanSha256})
        $doc=Read-WslRecoveryDocument $PlanPath;if($doc.Sha256 -cne $ReviewedPlanSha256){throw 'Independent exact plan review differs.'};$p=$doc.Value
        Assert-WslColdPermissionPlan $p $Phase
        $code=Get-WslColdCustodyCode $p.policy.sourceRoot $p.policy.sourceManifestSha256 -RequireProtected
        if($code.SourceCommit -cne $p.sourceCommit -or $code.Files.Count -ne $p.sourceFiles.Count){throw 'Reviewed source closure changed.'}
        $expected=@{};foreach($r in $p.sourceFiles){Assert-WslRecoveryFields $r @('path','sha256') 'reviewed source row';if($expected.ContainsKey($r.path)){throw 'Duplicate source path.'};$expected[$r.path]=$r.sha256}
        $inputs=@($code.Files|ForEach-Object {if($expected[$_.RelativePath] -cne $_.Sha256){throw 'Reviewed source bytes changed.'};@{path=$_.SourcePath;sha256=$_.Sha256}})+@(@{path=(Join-Path $p.policy.sourceRoot 'artifact-source-manifest.json');sha256=$p.policy.sourceManifestSha256})
        if($Phase -ceq 'Rollback'){
            $original=Read-WslRecoveryDocument $p.rollback.originalPlanPath
            if($original.Sha256 -cne $p.rollback.originalPlanSha256){throw 'Original rollback baseline review differs.'}
            Assert-WslColdPermissionPlan $original.Value 'Apply' -OriginalRollbackReference
            $observed=Read-WslColdPermissionReceipt $original.Value $original.Sha256 $p.rollback.applyReceiptPath $p.rollback.applyReceiptSha256
            if($p.before.DescriptorSha256 -cne $original.Value.before.DescriptorSha256 -or $p.after.DescriptorSha256 -cne $original.Value.after.DescriptorSha256 -or $p.sourceCommit -cne $original.Value.sourceCommit -or
                (ConvertTo-Json $p.policy -Depth 12 -Compress) -cne (ConvertTo-Json $original.Value.policy -Depth 12 -Compress) -or $p.rootFileIdentity -cne $original.Value.rootFileIdentity -or
                $observed.DescriptorBase64 -cne $p.rollback.observedAfterBase64 -or $observed.DescriptorSha256 -cne $p.rollback.observedAfterRawSha256){throw 'Fresh rollback cannot change original scope/target or actual observed raw CAS.'}
            $inputs+=@(@{path=$p.rollback.originalPlanPath;sha256=$p.rollback.originalPlanSha256},@{path=$p.rollback.applyReceiptPath;sha256=$p.rollback.applyReceiptSha256})
        }
        foreach($f in $inputs){
            $path=[IO.Path]::GetFullPath($f.path);$id=[Revealfleet.Backup.ColdSourceLease]::InspectIdentityForReview($path);$stream=[IO.File]::Open($path,'Open','Read','Read');$held.Add(@{path=$path;identity=$id;stream=$stream;sha256=$f.sha256})
        }
        $scope=[Revealfleet.Backup.ColdRestorePrivilege]::CustodyScope()
        $root=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($p.policy.volumeRoot);$parent=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($p.policy.evidenceDirectory)
        if($root.FileIdentity -cne $p.rootFileIdentity -or $root.Attributes -ne $p.rootAttributes -or $parent.FileIdentity -cne $p.evidenceFileIdentity -or $parent.Read().DescriptorSha256 -cne $p.evidenceRawSha256){throw 'Root/evidence handle/descriptor drift.'}
        [void](Assert-WslColdProtectedPath $p.policy.evidenceDirectory -Directory)
        if(-not $root.Read().SecurityWriterAdmission().Admissible){throw 'Production bootstrap refused: ordinary WRITE_DAC/WRITE_OWNER or untrusted owner cannot be excluded by the retained handle; no atomic descriptor CAS.'}
        $initial=Assert-WslColdPermissionCapacity $p $code.Files
        $validateBody={param($p,$code,$held,$root,$parent,$initial)
            if([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -ge $p.expiresAt){throw 'Reviewed transaction expired.'}
            if((ConvertTo-Json (Get-WslColdStoragePreflight) -Depth 12 -Compress) -cne (ConvertTo-Json $p.storage -Depth 12 -Compress)){throw 'Reviewed Microsoft Storage source binding changed.'}
            [void](Assert-WslColdPermissionCapacity $p $code.Files $initial)
            [void](Assert-WslColdProtectedPath $p.policy.evidenceDirectory -Directory)
            if($parent.FileIdentity -cne $p.evidenceFileIdentity -or $parent.Read().DescriptorSha256 -cne $p.evidenceRawSha256){throw 'Independent evidence parent drift.'}
            $root.ValidateIdentity();$parent.ValidateIdentity();Assert-WslColdHeldCustodyVolume $root $p.policy.hardware.volumeUuid;Assert-WslColdHeldCustodyVolume $parent $p.policy.evidenceHardware.volumeUuid
            foreach($f in $held){
                if([Revealfleet.Backup.ColdSourceLease]::InspectIdentityForReview($f.path) -cne $f.identity){throw 'Held reviewed file name/identity drift.'}
                $f.stream.Position=0;$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($f.stream)).ToLowerInvariant();$f.stream.Position=0
                if($hash -cne $f.sha256){throw 'Held reviewed input/code bytes drift.'}
            }
        }
        $validate={& $validateBody $p $code $held $root $parent $initial}.GetNewClosure()
        & $validate
        $expectedRaw=if($Phase -ceq 'Apply'){$p.before.DescriptorSha256}else{$p.rollback.observedAfterRawSha256}
        if($root.Read().DescriptorSha256 -cne $expectedRaw){throw 'Full raw root CAS drift before any evidence creation/mutation.'}
        if($Phase -ceq 'Apply' -and (Test-Path -LiteralPath $p.namespacePath)){throw 'Exclusive namespace collision before mutation.'}
        if($Phase -ceq 'Rollback' -and (Get-WslColdRetainedNamespace $p $code.Files) -cne $p.rollback.namespaceSnapshot){throw 'Retained namespace drift after rollback review.'}
        Assert-WslColdHeldCustodyVolume $root $p.policy.hardware.volumeUuid;Assert-WslColdHeldCustodyVolume $parent $p.policy.evidenceHardware.volumeUuid
        $root.RequireNoSacl() # mandatory supported read, never infer absence from unselected data
        $attempt=Join-Path $p.policy.evidenceDirectory ('revkit-custody-'+([guid]$p.transactionId).ToString('N'))
        [Revealfleet.Backup.ColdSourceLease]::CreateProtectedDirectory($attempt,(New-WslColdCustodyJournalDescriptor $p.policy.trustedUserSid))
        [void](Assert-WslColdProtectedPath $attempt -Directory);[void](Assert-WslColdProtectedPath $attempt -Directory -PrivateData)
        $retainedInputs=@(@{source=$PlanPath;name='reviewed-plan.json';sha256=$ReviewedPlanSha256})
        if($Phase -ceq 'Rollback'){$retainedInputs+=@(@{source=$p.rollback.originalPlanPath;name='original-reviewed-apply-plan.json';sha256=$p.rollback.originalPlanSha256},@{source=$p.rollback.applyReceiptPath;name='reviewed-apply-observation.json';sha256=$p.rollback.applyReceiptSha256})}
        foreach($input in $retainedInputs){
            $dest=Join-Path $attempt $input.name
            [Revealfleet.Backup.ColdDirectorySecurityLease]::CopyNewProtectedFile($input.source,$dest,(New-WslColdCustodyJournalDescriptor $p.policy.trustedUserSid -File))
            if((Get-FileHash -LiteralPath $dest).Hash.ToLowerInvariant() -cne $input.sha256){throw 'Exact reviewed input custody failed before mutation.'}
        }
        $context=@{reviewedPlanSha256=$ReviewedPlanSha256;transactionId=$p.transactionId;sourceCommit=$p.sourceCommit;phase=$Phase;rootFileIdentity=$p.rootFileIdentity}
        $rollbackObserved=if($Phase -ceq 'Rollback'){$p.rollback.observedAfterBase64}else{$null}
        $transaction=$root.OpenProductionPermissionTransaction($p.rootFileIdentity,$p.policy.hardware.volumeUuid,$p.before.DescriptorBase64,$p.after.DescriptorBase64,$p.policy.trustedUserSid,$attempt,(ConvertTo-Json $context -Compress),[Action]$validate,$rollbackObserved)
        if($Phase -ceq 'Apply'){
            $proof=$transaction.Apply();$applied=$true
            & $validate
            if(Test-Path -LiteralPath $p.namespacePath){throw 'Namespace collision after root restriction; never adopt.'}
            $namespace=Install-WslColdVolumeNamespaces $p $code.Files $attempt
            & $validate
            Write-WslBackupJsonNew (Join-Path $attempt 'completed.json') @{profile='cold-volume-permission-custody-v2';phase=$Phase;planSha256=$ReviewedPlanSha256;actualAfter=$proof.Observed;delta=$proof.Delta;namespace=$namespace;productionActivated=$false;existingChildrenPrivatized=$false}
        }else{
            $proof=$transaction.Rollback()
            if((Get-WslColdRetainedNamespace $p $code.Files) -cne $p.rollback.namespaceSnapshot){throw 'Retained child evidence changed during rollback; unaccepted, preserve state.'}
            Write-WslBackupJsonNew (Join-Path $attempt 'completed.json') @{profile='cold-volume-permission-custody-v2';phase=$Phase;planSha256=$ReviewedPlanSha256;actualAfter=$proof.Observed;delta=$proof.Delta;namespaceRetained=$true;newNamespaceAuthorityAccepted=$false;productionActivated=$false}
        }
        [pscustomobject]@{EvidenceAttempt=$attempt;Receipt=(Join-Path $attempt ($Phase.ToLowerInvariant()+'-accepted.json'));State=$transaction.State;NativeMutationCalls=$transaction.MutationCalls;Activated=$false;ExistingChildrenPrivatized=$false}
    } catch {
        $failure=$_
        if($attempt){
            try {Write-WslBackupJsonNew (Join-Path $attempt 'failure.json') @{phase=$Phase;state=$(if($transaction){$transaction.State}else{'NotMutated'});reason=$failure.Exception.Message;retainAll=$true}}catch {Write-Warning 'Failure evidence unavailable; retain attempt and original error.'}
            if($applied -and $transaction.State -ceq 'Applied'){
                # Public code only was copied. Never remove artifacts. Journaled
                # inverse uses the SAME original handle and actual observed CAS.
                try {$inverseTree=Get-WslColdRetainedNamespace $p $code.Files;Write-WslBackupJsonNew (Join-Path $attempt 'failure-before-inverse.json') @{tree=$inverseTree;actualApplied=$transaction.Applied.Observed};$inverse=$transaction.Rollback();if((Get-WslColdRetainedNamespace $p $code.Files) -cne $inverseTree){throw 'Retained namespace delta during failure inverse.'};Write-WslBackupJsonNew (Join-Path $attempt 'failure-inverse.json') @{observed=$inverse.Observed;delta=$inverse.Delta;namespaceRetained=$true;namespaceAuthorityAccepted=$false}}
                catch {Write-Warning 'Inverse unconfirmed/refused; retain raw journals, no retry or inferred restoration.'}
            }
        }
        throw
    } finally {
        $cleanup=$null
        foreach($o in @($transaction,$attemptLease,$parent,$root,$scope)) {if($o){try{$o.Dispose()}catch{if(-not $cleanup){$cleanup=$_}}}}
        foreach($f in $held){try{$f.stream.Dispose()}catch{if(-not $cleanup){$cleanup=$_}}}
        if($cleanup -and -not $failure){throw $cleanup};if($cleanup -and $failure){Write-Warning 'Owned custody cleanup unconfirmed; original failure preserved.'}
    }
}

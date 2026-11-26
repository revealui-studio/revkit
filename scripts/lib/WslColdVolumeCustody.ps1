#Requires -Version 7.0
# Root OWNER+DACL planning only. Apply/Rollback blocked by actual Windows drift.
# No production mutation API is accepted; descendants are never enumerated.
. (Join-Path $PSScriptRoot 'WslBackup.ps1')
. (Join-Path $PSScriptRoot 'WindowsArtifactDeployment.ps1')

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

function Get-WslColdVolumeCustodyPlan {
    param($Policy)
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
        [ordered]@{schemaVersion=1;kind='cold-volume-custody-plan-v1';intent='ApplyOrRollback';policy=$Policy;
            sourceCommit=$code.SourceCommit;sourceFiles=@($code.Files|ForEach-Object {@{path=$_.RelativePath;sha256=$_.Sha256}});
            rootFileIdentity=$lease.FileIdentity;rootAttributes=$lease.Attributes;before=$before;after=$after;
            evidenceFileIdentity=$safeEvidence.FileIdentity;evidenceDescriptorSha256=$evidenceDescriptor.Sha256;
            createdAt=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds();expiresAt=[DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds();
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
    Assert-WslRecoveryFields $p @('schemaVersion','kind','intent','policy','sourceCommit','sourceFiles','rootFileIdentity','rootAttributes','before','after','evidenceFileIdentity','evidenceDescriptorSha256','createdAt','expiresAt','namespacePath','sourceOrWorkerActivated','descendantsEnumerated','existingChildParentDeletionFallbackRemoved','api','privileges','sacl','group','rollback') 'reviewed custody plan'
    if($p.schemaVersion -ne 1 -or $p.kind -cne 'cold-volume-custody-plan-v1' -or $p.expiresAt -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -or $p.expiresAt-$p.createdAt -gt 3600){throw 'Fresh versioned root plan required.'}
    if($p.intent -cnotin @('ApplyOrRollback','RollbackOnly') -or ($p.intent -ceq 'RollbackOnly' -and $Phase -cne 'Rollback')){throw 'Reviewed plan phase differs.'}
    Assert-WslColdVolumeCustodyPolicy $p.policy
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
    param([string]$OriginalPlanPath,[string]$ReviewedOriginalPlanSha256)
    if(-not $IsWindows){throw 'Actual Windows required.'}
    Assert-WslBackupHash $ReviewedOriginalPlanSha256
    $doc=Read-WslRecoveryDocument $OriginalPlanPath
    if($doc.Sha256 -cne $ReviewedOriginalPlanSha256){throw 'Original review digest differs.'}
    $p=$doc.Value
    if($p.kind -cne 'cold-volume-custody-plan-v1' -or $p.schemaVersion -ne 1){throw 'Original versioned root plan required.'}
    Assert-WslColdVolumeCustodyPolicy $p.policy
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

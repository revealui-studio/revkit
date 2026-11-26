#Requires -Version 7.0
param([string]$RetainedFixtureParent)
BeforeAll {
    . (Join-Path $PSScriptRoot '..' '..' 'scripts/lib/WslColdVolumeCustody.ps1')
    Initialize-WslColdWorkerProtocol
    $script:syntheticUser='S-1-5-21-111-222-333-1001'
    function Grants { @([Revealfleet.Backup.ColdRootGrant]::new('S-1-1-0',0x1f01ff,3),[Revealfleet.Backup.ColdRootGrant]::new('S-1-3-0',0x1f01ff,3),[Revealfleet.Backup.ColdRootGrant]::new('S-1-5-18',0x1f01ff,3)) }
    function EffectiveMask($Rows,[string[]]$Sids) {
        [uint32]$mask=0;foreach($r in $Rows){if(-not ($r.Flags -band 8) -and $r.Sid -in $Sids){$mask=$mask -bor $r.Mask}};return $mask
    }
        if($IsWindows){
            function New-SyntheticTree {
                $base=if($RetainedFixtureParent){$RetainedFixtureParent}else{$TestDrive}
                if($RetainedFixtureParent){
                    [void](Assert-WslColdProtectedPath $base -Directory -PrivateData)
                    if([IO.Path]::GetFullPath($base) -ceq [IO.Path]::GetPathRoot($base)){throw 'Synthetic fixture parent cannot be a volume root.'}
                    $cursor=[IO.DirectoryInfo]::new($base)
                    while($cursor){if(Test-Path -LiteralPath (Join-Path $cursor.FullName '.git')){throw 'Synthetic custody must be outside Git.'};$cursor=$cursor.Parent}
                }
                $root=Join-Path $base ([Guid]::NewGuid().ToString('N'))
                $descriptor=[Security.AccessControl.DirectorySecurity]::new();$descriptor.SetAccessRuleProtection($true,$false)
                $user=[Security.Principal.WindowsIdentity]::GetCurrent().User
                $descriptor.SetOwner($user)
                foreach($sid in @('S-1-1-0','S-1-3-0','S-1-5-18')){$descriptor.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
                [Revealfleet.Backup.ColdSourceLease]::CreateProtectedDirectory($root,$descriptor.GetSecurityDescriptorBinaryForm())
                $child=New-Item -ItemType Directory -Path (Join-Path $root 'ordinary')
                $grandchild=New-Item -ItemType Directory -Path (Join-Path $child.FullName 'grandchild')
                $file=Join-Path $grandchild.FullName 'data.bin';[IO.File]::WriteAllBytes($file,[byte[]](1,0,255,42))
                $private=Join-Path $root 'protected'
                $privateBytes=New-WslColdNamespaceDescriptor $user.Value -PrivateData
                $privateSd=[Security.AccessControl.RawSecurityDescriptor]::new($privateBytes,0);$privateSd.Owner=$user
                $privateBytes=[byte[]]::new($privateSd.BinaryLength);$privateSd.GetBinaryForm($privateBytes,0)
                [Revealfleet.Backup.ColdSourceLease]::CreateProtectedDirectory($private,$privateBytes)
                [IO.File]::WriteAllText((Join-Path $private 'retained.txt'),'synthetic preserved')
                [IO.File]::WriteAllText((Join-Path $root 'baseline.txt'),'baseline')
                Save-CustodyTestReceipt $root initial
                return $root
            }
            function Save-CustodyTestReceipt([string]$Root,[string]$Phase) {
                if(-not $RetainedFixtureParent){return}
                $snapshot=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($Root)
                try {Write-WslBackupJsonNew ($Root+'-'+$Phase+'.json') @{root=$Root;phase=$Phase;descriptor=$snapshot.Read();tree=(Tree-Receipt $Root);productionAccepted=$false}}
                finally {$snapshot.Dispose()}
            }
            function Tree-Receipt([string]$Root) {
                @((Get-ChildItem -LiteralPath $Root -Recurse -Force)|ForEach-Object {
                    $item=$_;$acl=Get-Acl -LiteralPath $item.FullName
                    [ordered]@{path=$item.FullName;descriptor=$acl.Sddl;attributes=[int]$item.Attributes;created=$item.CreationTimeUtc.Ticks;written=$item.LastWriteTimeUtc.Ticks;data=$(if(-not $item.PSIsContainer){(Get-FileHash -LiteralPath $item.FullName).Hash}else{''})}
                })|ConvertTo-Json -Depth 8 -Compress
            }
        }

}
Describe 'Bounded root ACL semantics on every platform' {
    It 'removes dangerous root grants while preserving read, traverse and creation' {
        $after=[Revealfleet.Backup.ColdRootPolicy]::Restrict((Grants),$syntheticUser)
        $ordinary=EffectiveMask $after @($syntheticUser,'S-1-1-0')
        ($ordinary -band 0xd0040)|Should -Be 0
        foreach($right in @(1,2,4,8,32,128,0x20000,0x100000)){($ordinary -band $right)|Should -Be $right}
        foreach($trusted in @('S-1-5-18','S-1-5-32-544')){(EffectiveMask $after @($trusted,'S-1-1-0') -band 0x1f01ff)|Should -Be 0x1f01ff}
    }
    It 'preserves each child template and CreatorOwner mapping without a blanket deny' {
        $before=Grants;$after=[Revealfleet.Backup.ColdRootPolicy]::Restrict($before,$syntheticUser)
        $templates=@($after|Where-Object {$_.Flags -band 3})
        $templates.Count|Should -Be $before.Count
        for($i=0;$i -lt $before.Count;$i++){
            $templates[$i].Sid|Should -BeExactly $before[$i].Sid
            $templates[$i].Mask|Should -Be $before[$i].Mask
            ($templates[$i].Flags -band 3)|Should -Be ($before[$i].Flags -band 3)
        }
        ($templates|Where-Object Sid -eq 'S-1-3-0').Flags|Should -Be 11
    }
    It 'refuses unknown principals, no-propagate/inherited/callback-style flags and generic masks' {
        foreach($grant in @([Revealfleet.Backup.ColdRootGrant]::new('unknown',1,0),[Revealfleet.Backup.ColdRootGrant]::new('S-1-1-0',1,7),[Revealfleet.Backup.ColdRootGrant]::new('S-1-1-0',1,19),[Revealfleet.Backup.ColdRootGrant]::new('S-1-1-0',0x10000000,3),[Revealfleet.Backup.ColdRootGrant]::new('S-1-3-0',1,0))){
            {[Revealfleet.Backup.ColdRootPolicy]::Restrict(@($grant),$syntheticUser)}|Should -Throw
        }
    }
    It 'distinguishes inherit-only ancestor templates from dangerous effective and private leaf grants' {
        $template=[pscustomobject]@{Sid='S-1-1-0';Rights=[Security.AccessControl.FileSystemRights]::FullControl;Allow=$true;InheritOnly=$true}
        {Assert-WslColdAclGrants @($template) @('S-1-5-18') -PrivateData}|Should -Not -Throw
        {Assert-WslColdAclGrants @($template) @('S-1-5-18') -PrivateData -Leaf}|Should -Throw
        $template.InheritOnly=$false
        {Assert-WslColdAclGrants @($template) @('S-1-5-18')}|Should -Throw
    }
    It 'rejects namespace aliases, device names and traversal before any path creation' {
        foreach($name in @('..','a/b','a\b','name.','NUL','COM1','LPT9','x:stream','with space','')){{Assert-WslColdNamespaceLeaf $name}|Should -Throw}
        {Assert-WslColdNamespaceLeaf 'synthetic-recovery_01'}|Should -Not -Throw
    }
    It 'refuses insufficient explicit namespace/evidence budgets using actual fixture byte lengths' {
        $root=Join-Path $TestDrive 'bounded-package';[void][IO.Directory]::CreateDirectory($root)
        $manifest=Join-Path $root 'artifact-source-manifest.json';[IO.File]::WriteAllText($manifest,'{}')
        $file=Join-Path $root 'public';[IO.File]::WriteAllBytes($file,[byte[]]::new(512))
        $policy=@{sourceRoot=$root;volumeRoot='X:\';evidenceDirectory='Y:\private';hardware=@{};evidenceHardware=@{};namespaceAdditionalBytes=1024; evidenceAdditionalBytes=1024;reserveBytes=64GB}
        Mock Assert-WslColdWindowsHardware { [pscustomobject]@{Free=64GB+2048} }
        (Assert-WslColdCustodyCapacity $policy @([pscustomobject]@{SourcePath=$file}))|Should -Be 514
        $policy.namespaceAdditionalBytes=514
        {Assert-WslColdCustodyCapacity $policy @([pscustomobject]@{SourcePath=$file})}|Should -Throw
        $policy.namespaceAdditionalBytes=4096
        {Assert-WslColdCustodyCapacity $policy @([pscustomobject]@{SourcePath=$file})}|Should -Throw
    }
    It 'cannot invoke native mutation or accept another plan without Windows admission' -Skip:$IsWindows {
        {Invoke-WslColdVolumeCustody -Phase Apply -PlanPath '/must-not-open' -ReviewedPlanSha256 ('a'*64)}|Should -Throw -ExpectedMessage '*Actual Windows*'
        {[Revealfleet.Backup.ColdDirectorySecurityLease]::new('/must-not-open')}|Should -Throw
        {[Revealfleet.Backup.ColdRestorePrivilege]::new()}|Should -Throw
    }
}

Describe 'Actual Windows synthetic no-propagation and custody' -Tag 'WindowsSynthetic' {
    It 'refuses a synthetic subdirectory at the PRODUCTION volume-root entrypoint' -Skip:(-not $IsWindows) {
        {Assert-WslColdVolumeRoot (Join-Path $TestDrive 'not-a-root')}|Should -Throw
        foreach($path in @('e:\','E:\child','E:\..\','\\?\E:\','\\server\share\')){{Assert-WslColdVolumeRoot $path}|Should -Throw}
    }
    It 'preserves every real child/grandchild descriptor, owner, bytes and metadata during root-only DACL update' -Skip:(-not $IsWindows) {
        $root=New-SyntheticTree;$original=Tree-Receipt $root
        $lease=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($root)
        try {
            $before=$lease.Read();$user=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            # Unelevated acceptance changes DACL only while retaining own owner.
            # Production Admin owner transition has a SEPARATE elevated case.
            $after=$before.Restricted($user)
            $sd=[Security.AccessControl.RawSecurityDescriptor]::new([Convert]::FromBase64String($after.DescriptorBase64),0)
            $sd.Owner=[Security.Principal.SecurityIdentifier]::new($user)
            $bytes=[byte[]]::new($sd.BinaryLength);$sd.GetBinaryForm($bytes,0)
            $target=[Revealfleet.Backup.ColdSecuritySnapshot]::new($bytes)
            $lease.Replace($before.Sha256,$target.DescriptorBase64)
            $lease.Read().Sha256|Should -BeExactly $target.Sha256
            (Tree-Receipt $root)|Should -BeExactly $original
            $new=Join-Path $root 'new-ordinary-file';[IO.File]::WriteAllText($new,'new child')
            [IO.File]::ReadAllText($new)|Should -BeExactly 'new child'
            (Get-Acl -LiteralPath $new).Sddl|Should -BeExactly (Get-Acl -LiteralPath (Join-Path $root 'baseline.txt')).Sddl
            # Before rollback remove only this test-created extra file; existing
            # descendants remain untouched by the OWNER+DACL primitive itself.
            Remove-Item -LiteralPath $new
            $lease.Replace($target.Sha256,$before.DescriptorBase64)
            $lease.Read().Sha256|Should -BeExactly $before.Sha256
            (Tree-Receipt $root)|Should -BeExactly $original
        } finally {Save-CustodyTestReceipt $root final;$lease.Dispose()}
    }
    It 'demonstrates MAXIMUM_ALLOWED no-propagation using a deliberately DIFFERENT child template' -Skip:(-not $IsWindows) {
        $root=New-SyntheticTree;$original=Tree-Receipt $root
        $lease=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($root)
        try {
            $before=$lease.Read();$currentUser=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$target=$before.Restricted($currentUser).WithOwner($currentUser)
            $sd=[Security.AccessControl.RawSecurityDescriptor]::new([Convert]::FromBase64String($target.DescriptorBase64),0)
            foreach($ace in $sd.DiscretionaryAcl){if($ace.SecurityIdentifier.Value -eq 'S-1-1-0' -and ($ace.AceFlags -band 8)){$ace.AccessMask=0x1200a9}}
            $bytes=[byte[]]::new($sd.BinaryLength);$sd.GetBinaryForm($bytes,0)
            $target=[Revealfleet.Backup.ColdSecuritySnapshot]::new($bytes)
            $lease.Replace($before.Sha256,$target.DescriptorBase64)
            (Tree-Receipt $root)|Should -BeExactly $original
            $new=Join-Path $root 'different-template-child';[IO.File]::WriteAllText($new,'new synthetic child')
            $newAcl=[Security.AccessControl.RawSecurityDescriptor]::new((Get-Acl -LiteralPath $new).Sddl)
            @($newAcl.DiscretionaryAcl|Where-Object {$_.SecurityIdentifier.Value -eq 'S-1-1-0'})[0].AccessMask|Should -Be 0x1200a9
            Remove-Item -LiteralPath $new
            $lease.Replace($target.Sha256,$before.DescriptorBase64)
            (Tree-Receipt $root)|Should -BeExactly $original
        } finally {Save-CustodyTestReceipt $root final;$lease.Dispose()}
    }
    It 'preserves unprotected subtree control/group and existing child descriptors with the same handle API' -Skip:(-not $IsWindows) {
        $root=New-SyntheticTree;$child=Join-Path $root 'ordinary';$original=Tree-Receipt $child
        $lease=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($child)
        try {
            $before=$lease.Read();($before.Control -band 0x1000)|Should -Be 0
            $target=$before.WithOwner($before.OwnerSid)
            $lease.Replace($before.Sha256,$target.DescriptorBase64)
            $lease.Read().Control|Should -Be $before.Control
            $lease.Read().GroupBase64|Should -BeExactly $before.GroupBase64
            (Tree-Receipt $child)|Should -BeExactly $original
        } finally {$lease.Dispose()}
    }
    It 'refuses descriptor drift before replacement and an existing namespace without cleanup-induced success' -Skip:(-not $IsWindows) {
        $root=New-SyntheticTree;$lease=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($root)
        try {
            $before=$lease.Read()
            {$lease.Replace(('0'*64),$before.DescriptorBase64)}|Should -Throw
            $lease.Read().Sha256|Should -BeExactly $before.Sha256
            {[Revealfleet.Backup.ColdSourceLease]::CreateProtectedDirectory($root,[Convert]::FromBase64String($before.DescriptorBase64))}|Should -Throw
            $lease.Read().Sha256|Should -BeExactly $before.Sha256
        } finally {Save-CustodyTestReceipt $root final;$lease.Dispose()}
    }
    It 'creates protected children which retain private exclusion and resist rename while held' -Skip:(-not $IsWindows) {
        $root=New-SyntheticTree;$path=Join-Path $root 'protected'
        $lease=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($path)
        try {
            $sd=$lease.Read();$raw=[Security.AccessControl.RawSecurityDescriptor]::new([Convert]::FromBase64String($sd.DescriptorBase64),0)
            @($raw.DiscretionaryAcl|Where-Object {$_.SecurityIdentifier.Value -eq 'S-1-1-0'}).Count|Should -Be 0
            {Move-Item -LiteralPath $path -Destination ($path+'-moved') -ErrorAction Stop}|Should -Throw
            $lease.ValidateIdentity()
            [IO.File]::ReadAllText((Join-Path $path 'retained.txt'))|Should -BeExactly 'synthetic preserved'
        } finally {Save-CustodyTestReceipt $root final;$lease.Dispose()}
    }
}

# Explicitly separate elevation-dependent ownership/ordinary-token acceptance.
Describe 'Elevated synthetic owner transition and rollback' -Tag 'Elevated' {
    BeforeAll {
        if($IsWindows -and -not ('Revealfleet.Tests.OrdinaryCaller' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'WslColdVolumeCustody.Fixture.cs')}
    }
    It 'restores an unresolved SID with scoped privilege and leaves all descendants unchanged' -Skip:(-not $IsWindows -or -not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
        # Shared private-tree helpers are loaded by the file BeforeAll.
        # This case never selects a real volume or production namespace.
        $root=New-SyntheticTree;$receipt=Tree-Receipt $root
        $tokenBefore=[Security.Principal.WindowsIdentity]::GetCurrent().Name
        $levelBefore=[Security.Principal.WindowsIdentity]::GetCurrent().ImpersonationLevel
        $scope=[Revealfleet.Backup.ColdRestorePrivilege]::new();$lease=$null
        try {
            $lease=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($root)
            $before=$lease.Read();$foreign=$before.WithOwner('S-1-5-21-111-222-333-4294960000')
            $lease.Replace($before.Sha256,$foreign.DescriptorBase64)
            $lease.Read().OwnerSid|Should -BeExactly $foreign.OwnerSid
            $after=$foreign.Restricted([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
            $lease.Replace($foreign.Sha256,$after.DescriptorBase64)
            $lease.Read().OwnerSid|Should -BeExactly 'S-1-5-32-544'
            (Tree-Receipt $root)|Should -BeExactly $receipt
            # Stale-before rollback must fail; it cannot overwrite current state.
            {$lease.Replace($foreign.Sha256,$before.DescriptorBase64)}|Should -Throw
            $lease.Read().Sha256|Should -BeExactly $after.Sha256
            $lease.Replace($after.Sha256,$foreign.DescriptorBase64)
            $lease.Read().Sha256|Should -BeExactly $foreign.Sha256
            $lease.Replace($foreign.Sha256,$before.DescriptorBase64)
            (Tree-Receipt $root)|Should -BeExactly $receipt
        } finally {Save-CustodyTestReceipt $root final;if($lease){$lease.Dispose()};$scope.Dispose()}
        [Security.Principal.WindowsIdentity]::GetCurrent().Name|Should -BeExactly $tokenBefore
        [Security.Principal.WindowsIdentity]::GetCurrent().ImpersonationLevel|Should -Be $levelBefore
    }
    It 'denies ordinary root mutation/substitution but permits real ordinary child creation after Admin ownership' -Skip:(-not $IsWindows -or -not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
        $root=New-SyntheticTree;$lease=$scope=$null
        $existingAuthority=Join-Path $root 'existing-authority'
        [Revealfleet.Backup.ColdSourceLease]::CreateProtectedDirectory($existingAuthority,(New-WslColdNamespaceDescriptor ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)))
        $existingAcl=(Get-Acl -LiteralPath $existingAuthority).Sddl
        $ordinaryBefore=[Revealfleet.Tests.OrdinaryCaller]::new()
        try {$ordinaryBefore.Enter();[Revealfleet.Tests.OrdinaryCaller]::CanOpen($existingAuthority,0x10000)|Should -BeTrue}
        finally {$ordinaryBefore.Dispose()}
        $scope=[Revealfleet.Backup.ColdRestorePrivilege]::new()
        try {
            $lease=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($root)
            $before=$lease.Read();$after=$before.Restricted([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
            $lease.Replace($before.Sha256,$after.DescriptorBase64)
        } finally {if($lease){$lease.Dispose()};$scope.Dispose()}
        $namespace=Join-Path $root 'new-authority'
        [Revealfleet.Backup.ColdSourceLease]::CreateProtectedDirectory($namespace,(New-WslColdNamespaceDescriptor ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)))
        $ordinary=[Revealfleet.Tests.OrdinaryCaller]::new()
        try {
            $ordinary.Enter()
            foreach($right in @(0x10000,0x40,0x40000,0x80000)){[Revealfleet.Tests.OrdinaryCaller]::CanOpen($root,$right)|Should -BeFalse}
            [Revealfleet.Tests.OrdinaryCaller]::CreateChildren($root)
            [IO.File]::ReadAllText((Join-Path $root 'ordinary-created-file'))|Should -BeExactly 'ordinary synthetic bytes'
            [Revealfleet.Tests.OrdinaryCaller]::CanOpen($namespace,0x10000)|Should -BeFalse
            [Revealfleet.Tests.OrdinaryCaller]::CanOpen($existingAuthority,0x10000)|Should -BeFalse
            [Revealfleet.Tests.OrdinaryCaller]::CanOpen((Join-Path $root 'baseline.txt'),0x10000)|Should -BeTrue
            {Move-Item -LiteralPath $namespace -Destination ($namespace+'-substituted') -ErrorAction Stop}|Should -Throw
            { [IO.File]::WriteAllText((Join-Path $namespace 'forbidden'),'must refuse') }|Should -Throw
        } finally {$ordinary.Dispose()}
        Test-Path -LiteralPath (Join-Path $namespace 'forbidden')|Should -BeFalse
        (Get-Acl -LiteralPath $existingAuthority).Sddl|Should -BeExactly $existingAcl
        $lease=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($root);$scope=[Revealfleet.Backup.ColdRestorePrivilege]::new()
        try {$lease.Replace($after.Sha256,$before.DescriptorBase64)} finally {Save-CustodyTestReceipt $root final;$lease.Dispose();$scope.Dispose()}
    }
}

Describe 'Reviewed-plan refusal precedes volume effects' {
    It 'rejects a changed plan digest without opening a root, privilege or namespace' -Skip:(-not $IsWindows) {
        $plan=Join-Path $TestDrive 'invalid-plan.json';[IO.File]::WriteAllText($plan,'{}')
        Mock Assert-WslColdWindowsHardware {throw 'must not observe a volume'}
        Mock Install-WslColdVolumeNamespaces {throw 'must not create namespace'}
        {Invoke-WslColdVolumeCustody -Phase Apply -PlanPath $plan -ReviewedPlanSha256 ('0'*64)}|Should -Throw -ExpectedMessage '*independent review*'
        Should -Invoke Assert-WslColdWindowsHardware -Times 0
        Should -Invoke Install-WslColdVolumeNamespaces -Times 0
    }
}

Describe 'Elevated new-namespace installation under an independent protected synthetic anchor' -Tag 'Elevated' {
    It 'copies verified new public code/private data and retains a partial collision for root-only rollback' -Skip:(-not $IsWindows -or -not $RetainedFixtureParent -or -not ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
        # This acceptance needs a reviewed admin-protected ancestor, not ordinary
        # user Temp. Failure to provide that anchor is an explicit test gap.
        [void](Assert-WslColdProtectedPath $RetainedFixtureParent -Directory)
        $root=New-SyntheticTree
        $scope=[Revealfleet.Backup.ColdRestorePrivilege]::new();$lease=$null
        try {
            $lease=[Revealfleet.Backup.ColdDirectorySecurityLease]::new($root)
            $before=$lease.Read();$after=$before.Restricted([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
            $lease.Replace($before.Sha256,$after.DescriptorBase64)
            $source=Join-Path $root 'fixed-synthetic-package';[IO.Directory]::CreateDirectory($source)|Out-Null
            $input=Join-Path $source 'fixed.bin';[IO.File]::WriteAllBytes($input,[byte[]](1,2,3,255))
            $manifest=Join-Path $source 'artifact-source-manifest.json';[IO.File]::WriteAllText($manifest,'{"synthetic":true}')
            $user=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $attempt=Join-Path $root 'synthetic-evidence'
            [Revealfleet.Backup.ColdSourceLease]::CreateProtectedDirectory($attempt,(New-WslColdNamespaceDescriptor $user -PrivateData))
            $plan=@{namespacePath=(Join-Path $root 'new-recovery');sourceCommit=('a'*40);policy=@{trustedUserSid=$user;sourceRoot=$source;sourceManifestSha256=(Get-FileHash -LiteralPath $manifest).Hash.ToLowerInvariant()}}
            $file=[pscustomobject]@{SourcePath=$input;RelativePath='scripts/nested/fixed.bin';Sha256=(Get-FileHash -LiteralPath $input).Hash.ToLowerInvariant()}
            $result=Install-WslColdVolumeNamespaces $plan @($file) $attempt
            $result.Activated|Should -BeFalse
            [void](Assert-WslColdProtectedPath (Join-Path $result.Authority 'scripts/nested/fixed.bin'))
            [void](Assert-WslColdProtectedPath $result.PrivateData -Directory -PrivateData)
            (Get-FileHash -LiteralPath (Join-Path $result.Authority 'scripts/nested/fixed.bin')).Hash.ToLowerInvariant()|Should -BeExactly $file.Sha256
            # A second NEW namespace deliberately hits an exclusive file collision.
            # The first copy must survive; no cleanup may manufacture a pass.
            $partialAttempt=Join-Path $root 'partial-evidence'
            [Revealfleet.Backup.ColdSourceLease]::CreateProtectedDirectory($partialAttempt,(New-WslColdNamespaceDescriptor $user -PrivateData))
            $plan.namespacePath=Join-Path $root 'partial-recovery'
            {Install-WslColdVolumeNamespaces $plan @($file,$file) $partialAttempt}|Should -Throw
            $partial=Join-Path $plan.namespacePath ('authority/'+$plan.sourceCommit+'/scripts/nested/fixed.bin')
            [IO.File]::ReadAllBytes($partial).Length|Should -Be 4
            Test-Path -LiteralPath (Join-Path $partialAttempt 'namespaces-verified.json')|Should -BeFalse
            $lease.Read().Sha256|Should -BeExactly $after.Sha256
            $lease.Replace($after.Sha256,$before.DescriptorBase64)
            Test-Path -LiteralPath $partial|Should -BeTrue
            $lease.Read().Sha256|Should -BeExactly $before.Sha256
        } finally {Save-CustodyTestReceipt $root final;if($lease){$lease.Dispose()};$scope.Dispose()}
    }
}

# Synthetic host acceptance helpers only; no operational trust override.
function Get-WslColdTestAclAudit {
    param([string]$Path,[switch]$PrivateData)
    $allowed=@('S-1-5-18','S-1-5-32-544',[Security.Principal.NTAccount]::new('NT SERVICE','TrustedInstaller').Translate([Security.Principal.SecurityIdentifier]).Value)
    if($PrivateData){$allowed+=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
    $rows=@();$current=[IO.DirectoryInfo]::new([IO.Path]::GetFullPath($Path))
    while($current){
        if($rows.Count -ge 32 -or -not $current.Exists -or ($current.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Synthetic ancestry type/depth/reparse refused.'}
        $acl=Get-Acl -LiteralPath $current.FullName
        $entries=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|ForEach-Object {[pscustomobject]@{Sid=$_.IdentityReference.Value;Rights=[int]$_.FileSystemRights;Allow=($_.AccessControlType -eq 'Allow');InheritOnly=([int]$_.PropagationFlags -band 2) -ne 0}})
        $denied=@($entries|Where-Object {$_.Allow -and -not $_.InheritOnly -and $_.Sid -cnotin $allowed -and ($_.Rights -band 0xd0040)})
        $owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        $publicAllowed=@('S-1-5-18','S-1-5-32-544',[Security.Principal.NTAccount]::new('NT SERVICE','TrustedInstaller').Translate([Security.Principal.SecurityIdentifier]).Value)
        $oldLeafMask=0xd0040 -bor [int][Security.AccessControl.FileSystemRights]::Write
        $publicLeafOffenders=@($entries|Where-Object {$_.Allow -and $_.Sid -cnotin $publicAllowed -and -not ($_.Sid -ceq 'S-1-3-0' -and $_.InheritOnly) -and ($_.Rights -band $oldLeafMask)})
        $rows+=@{oldPublicLeafOffenders=$publicLeafOffenders;path=$current.FullName;owner=$owner;ownerAccepted=($owner -cin $allowed);entries=$entries;offendingEffectiveGrants=$denied;role='ancestor-of-new-protected-child'}
        $current=$current.Parent
    }
    return ,$rows
}
function New-WslColdSyntheticAnchor {
    param([string]$Parent,[switch]$Authority,[string]$AuditPath)
    # Source-only runner chooses known profile/ProgramFiles parents; this API
    # creates exactly one UUID directory, never adopts or edits an old child.
    if(-not $IsWindows){throw 'Windows synthetic anchor only.'}
    $path=[IO.Path]::GetFullPath($Parent)
    if($path -cne $Parent -or $path -ceq [IO.Path]::GetPathRoot($path)){throw 'Canonical non-root synthetic parent required.'}
    $audit=Get-WslColdTestAclAudit $path -PrivateData:(-not $Authority)
    Write-WslBackupJsonNew $AuditPath @{schemaVersion=1;syntheticOnly=$true;authority=[bool]$Authority;ancestors=$audit}
    $allowed=@('S-1-5-18','S-1-5-32-544',[Security.Principal.NTAccount]::new('NT SERVICE','TrustedInstaller').Translate([Security.Principal.SecurityIdentifier]).Value)
    if(-not $Authority){$allowed+=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
    foreach($row in $audit){
        if(-not $row.ownerAccepted){throw ('Synthetic ancestor owner refused: '+$row.path+' SID '+$row.owner)}
        # Parent role only. Full private/public LEAF validation follows secure
        # exclusive creation; no operational leaf/ancestor rule is changed.
        try {Assert-WslColdAclGrants $row.entries $allowed -PrivateData:(-not $Authority)}
        catch {throw ('Synthetic ancestor grants refused: '+$row.path+' '+($row.offendingEffectiveGrants|ConvertTo-Json -Compress))}
        $cursor=[IO.DirectoryInfo]::new($row.path)
        if(Test-Path -LiteralPath (Join-Path $cursor.FullName '.git')){throw 'Synthetic anchor must be outside Git.'}
    }
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().User
    if($Authority){$bytes=New-WslColdNamespaceDescriptor $user.Value}
    else {
        $sd=[Security.AccessControl.DirectorySecurity]::new();$sd.SetAccessRuleProtection($true,$false);$sd.SetOwner($user)
        foreach($sid in @($user.Value,'S-1-5-18','S-1-5-32-544')){$sd.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
        $bytes=$sd.GetSecurityDescriptorBinaryForm()
    }
    $new=Join-Path $path ('revkit-synthetic-'+[Guid]::NewGuid().ToString('N'))
    [Revealfleet.Backup.ColdSourceLease]::CreateProtectedDirectory($new,$bytes)
    [void](Assert-WslColdProtectedPath $new -Directory -PrivateData:(-not $Authority))
    return $new
}
function Get-WslColdCaseManifest {
    param([string[]]$Paths)
    $manifest=@()
    foreach($path in $Paths){
        $tokens=$null;$errors=$null;$full=[IO.Path]::GetFullPath($path)
        $ast=[Management.Automation.Language.Parser]::ParseFile($full,[ref]$tokens,[ref]$errors)
        if($errors){throw ('Test inventory parse failure: '+$full+' '+$errors[0].Message)}
        $commands=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'It'},$true))
        if(-not $commands.Count){throw 'Required suite contains no tests.'}
        foreach($command in $commands){
            $name=$command.CommandElements[1]
            if($name -isnot [Management.Automation.Language.StringConstantExpressionAst]){throw 'Dynamic test inventory requires explicit review.'}
            $manifest+=@{file=$full;name=$name.Value}
        }
    }
    return ,$manifest
}
function Get-WslColdAcceptanceAccounting {
    param([object[]]$Manifest,[object[]]$Tests,[switch]$IncludeElevated)
    $elevatedNames=@('restores an unresolved SID with scoped privilege and leaves all descendants unchanged','denies ordinary root mutation/substitution but permits real ordinary child creation after Admin ownership','copies verified new public code/private data and retains a partial collision for root-only rollback','preserves explicit unprotected control and unresolved owner/group through a constrained elevated transaction')
    $platformNames=@('cannot invoke native mutation or accept another plan without Windows admission','has no native-host fallback that can open a real Windows source')
    $index=@{};foreach($row in $Manifest){$key=$row.file+'|'+$row.name;if($index.ContainsKey($key)){throw 'Ambiguous test inventory.'};$index[$key]=$false}
    $excluded=@();$skips=@();$notRun=@();$missing=@();$passed=0;$failed=0;$selected=0
    foreach($test in $Tests){
        $key=$test.file+'|'+$test.name
        if(-not $index.ContainsKey($key) -or $index[$key]){throw 'Unexpected/duplicate discovered test.'};$index[$key]=$true
        if($test.result -ceq 'NotRun' -and -not $IncludeElevated -and $test.name -cin $elevatedNames -and $test.file.EndsWith('WslColdVolumeCustody.Tests.ps1',[StringComparison]::OrdinalIgnoreCase) -and $test.elevated -and -not $test.shouldRun){$excluded+=@($test.name);continue}
        $selected++
        switch -CaseSensitive ($test.result) {
            'Passed' {$passed++}
            'Failed' {$failed++}
            'Skipped' {if($test.name -cnotin $platformNames -or -not ($test.file.EndsWith('WslColdVolumeCustody.Tests.ps1',[StringComparison]::OrdinalIgnoreCase) -or $test.file.EndsWith('WslColdAdmission.Tests.ps1',[StringComparison]::OrdinalIgnoreCase))){$skips+=@($test.name)}}
            default {$notRun+=@($test.name)}
        }
    }
    foreach($key in $index.Keys){if(-not $index[$key]){$missing+=@($key)}}
    [pscustomobject]@{total=$Manifest.Count;discovered=$Tests.Count;selected=$selected;excluded=$excluded.Count;excludedNames=[string[]]$excluded;passed=$passed;failed=$failed;notRun=$notRun.Count;unexpectedNotRun=[string[]]$notRun;unexpectedSkips=[string[]]$skips;missing=[string[]]$missing;componentAccepted=($failed -eq 0 -and $notRun.Count -eq 0 -and $skips.Count -eq 0 -and $missing.Count -eq 0 -and $selected -gt 0)}
}

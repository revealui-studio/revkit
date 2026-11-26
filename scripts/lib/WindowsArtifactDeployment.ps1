#Requires -Version 7.0

function Update-RevkitWindowsFleetProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Content, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw 'Profile parse failed before launcher reconciliation.' }
    $edits = @()
    $legacyBody = @'
{
    param([string]$Sub = '')
    $target = if ($Sub) { "~/__FLEET__/$Sub" } else { '~/__FLEET__' }
    wsl.exe -d Ubuntu --cd $target -- bash -lc claude
}
'@
    foreach ($statement in $ast.EndBlock.Statements) {
        $remove = $false
        if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
            $name = $statement.Name
            $safeName = $name.Length -gt 0
            foreach ($character in $name.ToCharArray()) {
                if (-not 'abcdefghijklmnopqrstuvwxyz0123456789-'.Contains([string]$character)) { $safeName = $false }
            }
            $body = $statement.Body.Extent.Text.Replace("`r`n", "`n").Trim()
            if ($safeName -and $body -ceq $legacyBody.Replace("`r`n", "`n").Replace('__FLEET__', $name).Trim()) { $remove = $true }
            elseif ($statement.Extent.Text.Contains('-- bash -lc claude') -and $statement.Extent.Text.Contains('wsl.exe')) {
                throw 'Unknown owner WSL launcher requires source review; profile remains unchanged.'
            }
        } elseif ($statement.Extent.Text.Trim() -ceq 'wsl --set-default Ubuntu >$null 2>&1') { $remove = $true }
        if ($remove) {
            $start = $statement.Extent.StartOffset
            # Contiguous comments document this recognized retired definition.
            while ($start -gt 0) {
                $lineEnd = $start
                if ($Content[$lineEnd - 1] -eq "`n") { $lineEnd-- }
                if ($lineEnd -gt 0 -and $Content[$lineEnd - 1] -eq "`r") { $lineEnd-- }
                $previous = $Content.LastIndexOf("`n", [Math]::Max(0, $lineEnd - 1)) + 1
                $line = $Content.Substring($previous, $lineEnd - $previous).Trim()
                if ($line -and -not $line.StartsWith('#')) { break }
                $start = $previous
            }
            $edits += @{ Start = $start; End = $statement.Extent.EndOffset }
        }
    }
    foreach ($edit in @($edits | Sort-Object Start -Descending)) {
        $Content = $Content.Substring(0, $edit.Start) + $Content.Substring($edit.End)
    }
    $guard = @'
if ((Get-Variable -Name _RevkitProfilePid -Scope Script -ErrorAction SilentlyContinue) -and $script:_RevkitProfilePid -eq $PID) { return }
$script:_RevkitProfilePid = $PID
'@
    foreach ($newline in @("`n", "`r`n")) {
        $oldGuard = 'if ($env:_PROFILE_LOADED) { return }' + $newline + '$env:_PROFILE_LOADED = ''1'''
        $Content = $Content.Replace($oldGuard, $guard)
    }
    if ($Content.Contains('$env:_PROFILE_LOADED')) { throw 'Unknown inherited profile guard requires source review.' }
    return $Content.Replace('# Lives on C: drive so it works without external drives', '# Local entry point loads the reviewed Windows artifact release.')
}

function Update-RevkitWindowsProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content, [switch]$ReconcileFleetLauncher)
    if ($ReconcileFleetLauncher) { $Content = Update-RevkitWindowsFleetProfile -Content $Content }
    $startMarker = '# generated-by-revkit windows-module:start'
    $endMarker = '# generated-by-revkit windows-module:end'
    $replacement = @'
# generated-by-revkit windows-module:start
$revkitWindowsRoot = [Environment]::GetEnvironmentVariable('REVEALUI_ROOT', 'User')
if ([string]::IsNullOrWhiteSpace($revkitWindowsRoot)) { throw 'RevKit Windows artifact deployment is not configured.' }
$revkitWindowsModule = Join-Path $revkitWindowsRoot 'powershell\Modules\RevealUI.RevStation\RevealUI.RevStation.psd1'
if (-not (Test-Path -LiteralPath $revkitWindowsModule -PathType Leaf)) { throw 'Configured RevKit Windows module is unavailable.' }
Import-Module -Name $revkitWindowsModule -Force -ErrorAction Stop
Remove-Variable revkitWindowsRoot, revkitWindowsModule
# generated-by-revkit windows-module:end
'@
    if ([string]::IsNullOrWhiteSpace($Content)) { return $replacement + "`n" }
    $start = $Content.IndexOf($startMarker, [StringComparison]::Ordinal)
    $end = $Content.IndexOf($endMarker, [StringComparison]::Ordinal)
    if ($start -ge 0 -or $end -ge 0) {
        if ($start -lt 0 -or $end -le $start -or $Content.IndexOf($startMarker, $start + 1, [StringComparison]::Ordinal) -ge 0 -or
            $Content.IndexOf($endMarker, $end + 1, [StringComparison]::Ordinal) -ge 0) { throw 'Ambiguous managed Windows profile markers.' }
        return $Content.Substring(0, $start) + $replacement + $Content.Substring($end + $endMarker.Length)
    }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Content, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw 'Existing Windows profile has parse errors; no deployment is safe.' }
    $statements = @($ast.EndBlock.Statements)
    $candidates = @()
    for ($index = 0; $index -lt $statements.Count; $index++) {
        $statement = $statements[$index]
        if ($statement -is [Management.Automation.Language.AssignmentStatementAst] -and
            $statement.Left -is [Management.Automation.Language.VariableExpressionAst] -and
            $statement.Left.VariablePath.UserPath -ceq '_revstationRoot') { $candidates += $index }
    }
    if ($candidates.Count -ne 1) { throw 'Unrecognized owner profile: no unique maintained module-loader adoption boundary.' }
    $index = $candidates[0]
    if ($index + 3 -ge $statements.Count -or $statements[$index + 1] -isnot [Management.Automation.Language.IfStatementAst] -or
        $statements[$index + 2] -isnot [Management.Automation.Language.IfStatementAst]) { throw 'Module-loader statement layout is unsupported.' }
    $last = $statements[$index + 3]
    $commands = @($last.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true))
    if ($commands.Count -ne 1 -or $commands[0].GetCommandName() -cne 'Remove-Variable') { throw 'Module-loader cleanup boundary is unsupported.' }
    $allowed = @('Join-Path', 'Test-Path', 'Get-Volume', 'Where-Object', 'ForEach-Object', 'Select-Object', 'Import-Module', 'Remove-Variable')
    $imports = 0
    foreach ($statement in $statements[$index..($index + 3)]) {
        foreach ($command in $statement.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)) {
            if ($command.GetCommandName() -cnotin $allowed) { throw 'Owner customization inside module-loader boundary requires review.' }
            if ($command.GetCommandName() -ceq 'Import-Module') {
                if ($command.CommandElements.Count -lt 2 -or $command.CommandElements[1] -isnot [Management.Automation.Language.StringConstantExpressionAst] -or $command.CommandElements[1].Value -cne 'RevealUI.RevStation') { throw 'Module-loader imports a different owner module.' }
                $imports++
            }
        }
        foreach ($assignment in $statement.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] }, $true)) {
            if ($assignment.Left -isnot [Management.Automation.Language.VariableExpressionAst] -or
                $assignment.Left.VariablePath.UserPath -cnotin @('_revstationRoot', 'modulePath', 'env:PSModulePath', 'env:REVEALUI_ROOT')) {
                throw 'Owner variable customization inside the module-loader boundary requires review.'
            }
        }
        if (@($statement.FindAll({ param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] }, $true)).Count -gt 0) {
            throw 'Owner method invocation inside the module-loader boundary requires review.'
        }
        if (@($statement.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)).Count -gt 0) {
            throw 'Owner functions inside module-loader boundary require review.'
        }
    }
    if ($imports -ne 1) { throw 'Expected exactly one maintained module import in the adoption boundary.' }
    return $Content.Substring(0, $statements[$index].Extent.StartOffset) + $replacement + $Content.Substring($last.Extent.EndOffset)
}

function Get-RevkitWindowsArtifactFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceRoot, [string]$ExpectedSourceManifestSha256)
    $policy = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'windows-artifact-scope.json') -Raw | ConvertFrom-Json
    if ($policy.schemaVersion -ne 1) { throw 'Unsupported Windows artifact scope policy.' }
    $sourceManifest = Join-Path $SourceRoot 'artifact-source-manifest.json'
    $manifestFiles = @{}
    if (Test-Path -LiteralPath $sourceManifest) {
        if ([string]::IsNullOrWhiteSpace($ExpectedSourceManifestSha256) -or
            (Get-FileHash -LiteralPath $sourceManifest -Algorithm SHA256).Hash -ine $ExpectedSourceManifestSha256) {
            throw 'Packaged Windows source requires the exact independently recorded native manifest SHA256.'
        }
        $manifest = Get-Content -LiteralPath $sourceManifest -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($manifest.schemaVersion -ne 1 -or $manifest.kind -cne 'revealfleet-windows-artifact-source') { throw 'Unsupported packaged Windows source manifest.' }
        $sourceCommit = $manifest.sourceCommit
        $paths = @($manifest.files.path)
        foreach ($entry in $manifest.files) {
            if ($manifestFiles.ContainsKey($entry.path)) { throw 'Duplicate Windows artifact manifest path.' }
            $manifestFiles[$entry.path] = $entry.sha256
        }
    } else {
        $raw = @(& git -C $SourceRoot ls-files -z -- @($policy.roots))
        if ($LASTEXITCODE -ne 0) { throw 'Windows artifacts require maintained committed source or a verified native package.' }
        & git -C $SourceRoot diff --quiet HEAD -- @($policy.roots)
        if ($LASTEXITCODE -ne 0) { throw 'Commit reviewed Windows source before building its deployment artifacts.' }
        $paths = @(($raw -join "`n").Split([char]0))
        $sourceCommit = @(& git -C $SourceRoot rev-parse HEAD) -join ''
        if ($LASTEXITCODE -ne 0) { throw 'Maintained source identity is unavailable.' }
    }
    if ($sourceCommit.Length -ne 40) { throw 'Unsupported Windows source commit identity.' }
    foreach ($character in $sourceCommit.ToCharArray()) {
        if (-not '0123456789abcdef'.Contains([string]$character)) { throw 'Unsupported Windows source commit identity.' }
    }
    $files = [Collections.Generic.List[object]]::new()
    foreach ($relative in $paths) {
        if ([string]::IsNullOrWhiteSpace($relative)) { continue }
        $parts = $relative.Split('/')
        $selected = $false
        foreach ($root in $policy.roots) { if ($relative -ceq $root -or $relative.StartsWith($root + '/', [StringComparison]::Ordinal)) { $selected = $true } }
        if (-not $selected -or $parts -contains '..' -or $relative.StartsWith('/') -or $relative.Contains('\') -or $relative.Contains(':') -or
            @($parts | Where-Object { $_ -cin $policy.excludedParts }).Count -gt 0 -or $parts[-1] -cin $policy.excludedLeaves) {
            if ($manifestFiles.Count -gt 0) { throw 'Packaged Windows source path is outside its maintained scope.' }
            continue
        }
        $path = Join-Path $SourceRoot $relative
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Windows source artifacts must be regular files.' }
        $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($manifestFiles.Count -gt 0 -and $manifestFiles[$relative] -cne $hash) { throw 'Native Windows source package checksum differs.' }
        $files.Add([pscustomobject]@{ RelativePath = $relative; SourcePath = $item.FullName; Sha256 = $hash; SourceCommit = $sourceCommit })
    }
    foreach ($required in $policy.required) {
        if ($required -cnotin @($files.RelativePath)) { throw 'Reviewed maintained module, Dismount and deployment closure are required in the Windows artifact source.' }
    }
    return $files.ToArray()
}

function Set-RevkitPrivateDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $null = [IO.Directory]::CreateDirectory($Path)
    $item = Get-Item -LiteralPath $Path
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Windows artifact directories cannot be reparse links.' }
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'), [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    # Set-Acl's provider tries all security sections, including Audit. Its
    # fallback can require SeSecurityPrivilege on an already protected directory.
    # Import only the reviewed DACL into a freshly read descriptor; .NET persists
    # only modified sections. Owner, group and the unread SACL remain untouched.
    $access = [Security.AccessControl.AccessControlSections]::Access
    $sections = $access -bor [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group
    $current = [IO.FileSystemAclExtensions]::GetAccessControl($item, $sections)
    $owner = $current.GetOwner([Security.Principal.SecurityIdentifier])
    $group = $current.GetGroup([Security.Principal.SecurityIdentifier])
    $expected = $acl.GetSecurityDescriptorSddlForm($access)
    $current.SetSecurityDescriptorSddlForm($expected, $access)
    [IO.FileSystemAclExtensions]::SetAccessControl($item, $current)
    $verified = [IO.FileSystemAclExtensions]::GetAccessControl($item, $sections)
    # Windows may canonicalize ACE order and the auto-inherited flag. Verify
    # exact rule semantics and DACL protection, not that incidental SDDL form.
    $ruleKey = {
        param($rule)
        '{0}|{1}|{2}|{3}|{4}|{5}' -f $rule.IdentityReference.Value, [int]$rule.AccessControlType,
            [int]$rule.FileSystemRights, [int]$rule.InheritanceFlags, [int]$rule.PropagationFlags, $rule.IsInherited
    }
    $expectedRules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { & $ruleKey $_ } | Sort-Object)
    $actualRules = @($verified.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { & $ruleKey $_ } | Sort-Object)
    if (-not $verified.AreAccessRulesProtected -or ($actualRules -join "`n") -cne ($expectedRules -join "`n") -or
        $verified.GetOwner([Security.Principal.SecurityIdentifier]) -ne $owner -or
        $verified.GetGroup([Security.Principal.SecurityIdentifier]) -ne $group) {
        throw 'Private artifact directory access or ownership verification failed.'
    }
}

function Install-RevkitColdAuthority {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$SourceRoot,[Parameter(Mandatory)][string]$ExpectedSourceManifestSha256,[switch]$Apply)
    # Unlike the user artifact/profile adapter, this owner NEVER edits an
    # existing namespace or inherits authority from a hash-verified E package.
    $files=@(Get-RevkitWindowsArtifactFiles $SourceRoot $ExpectedSourceManifestSha256)
    $bytes=[long]0;foreach($file in $files){$bytes+=(Get-Item -LiteralPath $file.SourcePath).Length}
    $commit=$files[0].SourceCommit
    $plan=[ordered]@{SchemaVersion=1;Kind='protected-cold-authority-v1';SourceCommit=$commit;
        SourceManifestSha256=$ExpectedSourceManifestSha256;Files=$files.Count;PayloadBytes=$bytes;
        Parent='%ProgramFiles%';Namespace='RevKitCold';Release=$commit;
        Owner='S-1-5-32-544';WritePrincipals=@('S-1-5-18','S-1-5-32-544');OtherRead=$true;
        ExistingPathsChanged=@();ProfileChanged=$false;PolicyInstalled=$false;Activated=$false;Applied=$false;
        Rollback='Retain partial new namespace. After review and no running controller, remove only this newly created namespace; no prior ACL/settings to restore.'}
    if(-not $Apply){return [pscustomobject]$plan}
    if(-not $IsWindows){throw 'Protected authority provisioning requires Windows.'}
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Protected authority provisioning requires an elevated administrator.'}
    . (Join-Path $PSScriptRoot 'WslBackup.ps1')
    $parent=[IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles))
    [void](Assert-WslColdProtectedPath $parent -Directory)
    $root=Join-Path $parent 'RevKitCold'
    if(Test-Path -LiteralPath $root){throw 'Authority namespace already exists; replacement/repair is outside provisioning.'}
    if(-not $PSCmdlet.ShouldProcess($root,'Create NEW administrator-owned cold authority namespace; copy verified release; no policy or activation')){return [pscustomobject]$plan}
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach($sid in @('S-1-5-18','S-1-5-32-544')){
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))
    # Create with the protected descriptor, not create-then-fix inheritance.
    Initialize-WslColdWorkerProtocol
    [Revealfleet.Backup.ColdSourceLease]::CreateProtectedDirectory($root,$acl.GetSecurityDescriptorBinaryForm())
    [void](Assert-WslColdProtectedPath $root -Directory)
    function Set-ColdCreatedOwner([string]$Path) {
        $item=Get-Item -LiteralPath $Path -Force
        $ownerAcl=[IO.FileSystemAclExtensions]::GetAccessControl($item,[Security.AccessControl.AccessControlSections]::Owner)
        $ownerAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        [IO.FileSystemAclExtensions]::SetAccessControl($item,$ownerAcl)
    }
    $release=Join-Path $root $commit
    [void][IO.Directory]::CreateDirectory($release)
    Set-ColdCreatedOwner $release
    foreach($file in $files){
        $dest=Join-Path $release $file.RelativePath
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))
        [IO.File]::Copy($file.SourcePath,$dest,$false)
        Set-ColdCreatedOwner $dest
        $directory=[IO.Path]::GetDirectoryName($dest)
        while($directory -ine $root){Set-ColdCreatedOwner $directory;$directory=[IO.Path]::GetDirectoryName($directory)}
        [void](Assert-WslColdProtectedPath $dest)
        if((Get-FileHash -LiteralPath $dest).Hash.ToLowerInvariant() -cne $file.Sha256){throw 'Authority copy differs; partial namespace retained, no activation.'}
    }
    [IO.File]::Copy((Join-Path $SourceRoot 'artifact-source-manifest.json'),(Join-Path $release 'artifact-source-manifest.json'),$false)
    Set-ColdCreatedOwner (Join-Path $release 'artifact-source-manifest.json')
    [void](Assert-WslColdProtectedPath (Join-Path $release 'artifact-source-manifest.json'))
    if((Get-FileHash -LiteralPath (Join-Path $release 'artifact-source-manifest.json')).Hash.ToLowerInvariant() -cne $ExpectedSourceManifestSha256){throw 'Authority manifest changed; partial namespace retained.'}
    $plan.Applied=$true;$plan.Parent=$parent;$plan.Release=$release
    return [pscustomobject]$plan
}

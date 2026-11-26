#Requires -Version 7.0

BeforeAll { . (Join-Path $PSScriptRoot '..' '..' 'scripts' 'lib' 'WindowsArtifactDeployment.ps1') }
Describe 'Windows profile adoption preserves owner content' {
    BeforeEach {
        $script:ProfileText = @'
$ownerModel = 'owner-selected-model'
$ownerTrust = 'preserve-this-preference'
$_revstationRoot = Join-Path $env:USERPROFILE '.revealui'
if (-not $_revstationRoot) {
    $_revstationRoot = Get-Volume | Where-Object DriveLetter | Select-Object -First 1
}
if ($_revstationRoot) {
    $modulePath = Join-Path $_revstationRoot 'powershell\Modules'
    $env:PSModulePath = "$modulePath;$env:PSModulePath"
    Import-Module RevealUI.RevStation -ErrorAction SilentlyContinue
}
Remove-Variable -Name _revstationRoot, modulePath -ErrorAction SilentlyContinue
function Owner-Command { 'owner behavior preserved' }
'@
    }
    It 'replaces only the recognized module loader and preserves owner commands/preferences' {
        $changed = Update-RevkitWindowsProfile -Content $script:ProfileText
        $changed.Contains("`$ownerModel = 'owner-selected-model'") | Should -BeTrue
        $changed.Contains("`$ownerTrust = 'preserve-this-preference'") | Should -BeTrue
        $changed.Contains("function Owner-Command { 'owner behavior preserved' }") | Should -BeTrue
        $changed.Contains("GetEnvironmentVariable('REVEALUI_ROOT', 'User')") | Should -BeTrue
        $changed.Contains('Get-Volume') | Should -BeFalse
    }
    It 'is idempotent once its managed boundary is adopted' {
        $once = Update-RevkitWindowsProfile -Content $script:ProfileText
        Update-RevkitWindowsProfile -Content $once | Should -BeExactly $once
    }
    It 'refuses unknown profiles, ambiguous boundaries and custom commands inside the loader' {
        { Update-RevkitWindowsProfile -Content "function Owner-Only { 'keep me' }" } | Should -Throw
        { Update-RevkitWindowsProfile -Content ($script:ProfileText + "`n`$_revstationRoot = 'another-owner-value'") } | Should -Throw
        { Update-RevkitWindowsProfile -Content ($script:ProfileText.Replace('Import-Module RevealUI.RevStation', "Set-OwnerModel 'keep me'; Import-Module RevealUI.RevStation")) } | Should -Throw
    }
    It 'refuses hidden owner variable/method customizations inside the loader' {
        { Update-RevkitWindowsProfile -Content ($script:ProfileText.Replace('Import-Module RevealUI.RevStation', "`$ownerModel = 'new'; Import-Module RevealUI.RevStation")) } | Should -Throw
        { Update-RevkitWindowsProfile -Content ($script:ProfileText.Replace('Import-Module RevealUI.RevStation', "[Environment]::SetEnvironmentVariable('OWNER','value'); Import-Module RevealUI.RevStation")) } | Should -Throw
    }
    It 'creates a minimal pointer for a previously absent account profile' {
        $changed = Update-RevkitWindowsProfile -Content ''
        $changed.Contains('generated-by-revkit windows-module:start') | Should -BeTrue
        $changed.Contains('Import-Module') | Should -BeTrue
        $changed.Contains('Get-Volume') | Should -BeFalse
    }
}

Describe 'Windows deployment accepts the exact native package without Git linkage' {
    BeforeEach {
        $script:Package = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Package | Out-Null
        $policy = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'scripts' 'windows-artifact-scope.json') -Raw | ConvertFrom-Json
        $files = @()
        foreach ($relative in $policy.required) {
            $path = Join-Path $script:Package $relative
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
            [IO.File]::WriteAllText($path, 'synthetic maintained source bytes')
            $files += @{ path = $relative; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); bytes = (Get-Item -LiteralPath $path).Length }
        }
        $script:Manifest = @{ schemaVersion = 1; kind = 'revealfleet-windows-artifact-source'; sourceCommit = '1' * 40; files = $files }
        $script:ManifestPath = Join-Path $script:Package 'artifact-source-manifest.json'
        $script:Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ManifestPath
        $script:ManifestHash = (Get-FileHash -LiteralPath $script:ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    It 'accepts only a checksum-bound package and rehashes each source artifact' {
        $files = @(Get-RevkitWindowsArtifactFiles -SourceRoot $script:Package -ExpectedSourceManifestSha256 $script:ManifestHash)
        $files.Count | Should -Be $script:Manifest.files.Count
        $files[0].SourceCommit | Should -Be ('1' * 40)
    }
    It 'refuses an absent/wrong independently recorded manifest digest' {
        { Get-RevkitWindowsArtifactFiles -SourceRoot $script:Package } | Should -Throw
        { Get-RevkitWindowsArtifactFiles -SourceRoot $script:Package -ExpectedSourceManifestSha256 ('0' * 64) } | Should -Throw
    }
    It 'refuses changed bytes before any artifact release is activated' {
        [IO.File]::AppendAllText((Join-Path $script:Package $script:Manifest.files[0].path), 'changed')
        { Get-RevkitWindowsArtifactFiles -SourceRoot $script:Package -ExpectedSourceManifestSha256 $script:ManifestHash } | Should -Throw
    }
    It 'refuses path escapes even when the supplied manifest digest matches that malformed manifest' {
        $script:Manifest.files += @{ path = 'scripts/data\..\..\outside.ps1'; sha256 = '0' * 64; bytes = 0 }
        $script:Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ManifestPath
        $hash = (Get-FileHash -LiteralPath $script:ManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        { Get-RevkitWindowsArtifactFiles -SourceRoot $script:Package -ExpectedSourceManifestSha256 $hash } | Should -Throw
    }
}

Describe 'Explicit fleet profile reconciliation' {
    BeforeAll {
        $script:FleetProfile = @'
# Owner preferences stay intact
if ($env:_PROFILE_LOADED) { return }
$env:_PROFILE_LOADED = '1'
$ownerModel = 'owner-model'
# Always use Ubuntu (historical location comment)
wsl --set-default Ubuntu >$null 2>&1
# Historical launcher documentation
function revealfleet {
    param([string]$Sub = '')
    $target = if ($Sub) { "~/revealfleet/$Sub" } else { '~/revealfleet' }
    wsl.exe -d Ubuntu --cd $target -- bash -lc claude
}
function Owner-Command { 'keep me' }
'@
    }
    It 'removes recognized import-time distro mutation and launcher definition without invoking either' {
        $changed = Update-RevkitWindowsFleetProfile -Content $script:FleetProfile
        $changed.Contains('--set-default') | Should -BeFalse
        $changed.Contains('function revealfleet') | Should -BeFalse
        $changed.Contains('$env:_PROFILE_LOADED') | Should -BeFalse
        $changed.Contains('$script:_RevkitProfilePid = $PID') | Should -BeTrue
        $changed.Contains("`$ownerModel = 'owner-model'") | Should -BeTrue
        $changed.Contains("function Owner-Command { 'keep me' }") | Should -BeTrue
        Update-RevkitWindowsFleetProfile -Content $changed | Should -BeExactly $changed
    }
    It 'recognizes the exact launcher for both source and profile newline conventions' {
        $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' '..' 'scripts' 'lib' 'WindowsArtifactDeployment.ps1') -Raw
        $source = $source.Replace("`r`n", "`n")
        $profile = $script:FleetProfile.Replace("`r`n", "`n")
        foreach ($sourceNewline in @("`n", "`r`n")) {
            foreach ($profileNewline in @("`n", "`r`n")) {
                $changed = & {
                    param($library, $content)
                    . ([scriptblock]::Create($library))
                    Update-RevkitWindowsFleetProfile -Content $content
                } $source.Replace("`n", $sourceNewline) $profile.Replace("`n", $profileNewline)
                $changed.Contains('function revealfleet') | Should -BeFalse
                $changed.Contains('function Owner-Command') | Should -BeTrue
                $changed.Contains('$script:_RevkitProfilePid = $PID') | Should -BeTrue
            }
        }
    }
    It 'refuses a customized WSL launcher instead of silently replacing owner behavior' {
        { Update-RevkitWindowsFleetProfile -Content ($script:FleetProfile.Replace('-- bash -lc claude', '-- bash -lc claude --custom-option')) } | Should -Throw
    }
}

Describe 'Private Windows artifact directories' {
    It 'reconciles a new then existing protected directory without changing owner or group' -Skip:(-not $IsWindows) {
        $path = Join-Path $TestDrive 'private-artifacts'
        $null = [IO.Directory]::CreateDirectory($path)
        $sections = [Security.AccessControl.AccessControlSections]::Access -bor [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group
        $item = Get-Item -LiteralPath $path
        $original = [IO.FileSystemAclExtensions]::GetAccessControl($item, $sections)
        $owner = $original.GetOwner([Security.Principal.SecurityIdentifier])
        $group = $original.GetGroup([Security.Principal.SecurityIdentifier])
        $first = $null
        foreach ($attempt in 1..3) {
            Set-RevkitPrivateDirectory -Path $path
            $after = [IO.FileSystemAclExtensions]::GetAccessControl($item, $sections)
            $after.GetOwner([Security.Principal.SecurityIdentifier]) | Should -Be $owner
            $after.GetGroup([Security.Principal.SecurityIdentifier]) | Should -Be $group
            $after.AreAccessRulesProtected | Should -BeTrue
            $rules = @($after.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
            $rules.Count | Should -Be 3
            $allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
            foreach ($rule in $rules) {
                $rule.IdentityReference.Value | Should -BeIn $allowed
                $rule.AccessControlType | Should -Be 'Allow'
                $rule.FileSystemRights | Should -Be ([Security.AccessControl.FileSystemRights]::FullControl)
                $rule.InheritanceFlags | Should -Be ([Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit')
                $rule.IsInherited | Should -BeFalse
            }
            $dacl = $after.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)
            if ($attempt -eq 1) { $first = $dacl } else { $dacl | Should -BeExactly $first }
        }
    }
}

Describe 'Cold authority deployment is distinct from private user artifacts' {
    It 'plans only a new protected namespace without touching profiles, ACLs or source files' {
        $file=Join-Path $TestDrive '.public-runtime';[IO.File]::WriteAllBytes($file,[byte[]]::new(512))
        Mock Get-RevkitWindowsArtifactFiles { @([pscustomobject]@{SourcePath=$file;SourceCommit=('a'*40);RelativePath='scripts/public';Sha256=('b'*64)}) }
        $plan=Install-RevkitColdAuthority -SourceRoot $TestDrive -ExpectedSourceManifestSha256 ('c'*64)
        $plan.PayloadBytes|Should -Be 512
        $plan.Parent|Should -Be '%ProgramFiles%'
        $plan.Owner|Should -Be 'S-1-5-32-544'
        $plan.ExistingPathsChanged.Count|Should -Be 0
        $plan.PolicyInstalled|Should -BeFalse
        $plan.Applied|Should -BeFalse
        (Get-ChildItem -LiteralPath $TestDrive -Force).Count|Should -Be 1
        [IO.File]::ReadAllBytes($file).Length|Should -Be 512
    }
    It 'refuses package provenance before any provisioning' {
        $before=@(Get-ChildItem -LiteralPath $TestDrive -Force).Count
        Mock Get-RevkitWindowsArtifactFiles { throw 'manifest mismatch' }
        {Install-RevkitColdAuthority -SourceRoot $TestDrive -ExpectedSourceManifestSha256 ('c'*64) -Apply}|Should -Throw -ExpectedMessage '*manifest mismatch*'
        (Get-ChildItem -LiteralPath $TestDrive -Force).Count|Should -Be $before
    }
}

Describe 'Atomic authority namespace creation on actual Windows only' {
    It 'refuses existing paths without changing their descriptor or contents' -Skip:(-not $IsWindows) {
        . (Join-Path $PSScriptRoot '..' '..' 'scripts' 'lib' 'WslBackup.ps1')
        Initialize-WslColdWorkerProtocol
        $path=Join-Path $TestDrive 'new-synthetic-authority'
        $descriptor=[Security.AccessControl.DirectorySecurity]::new()
        $descriptor.SetAccessRuleProtection($true,$false)
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $descriptor.SetOwner($sid)
        $descriptor.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
        [Revealfleet.Backup.ColdSourceLease]::CreateProtectedDirectory($path,$descriptor.GetSecurityDescriptorBinaryForm())
        $sentinel=Join-Path $path 'synthetic-public';[IO.File]::WriteAllText($sentinel,'preserve')
        $before=(Get-Acl -LiteralPath $path).Sddl
        {[Revealfleet.Backup.ColdSourceLease]::CreateProtectedDirectory($path,$descriptor.GetSecurityDescriptorBinaryForm())}|Should -Throw
        (Get-Acl -LiteralPath $path).Sddl|Should -BeExactly $before
        [IO.File]::ReadAllText($sentinel)|Should -BeExactly 'preserve'
    }
}

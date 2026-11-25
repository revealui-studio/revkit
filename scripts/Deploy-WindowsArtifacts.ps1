#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SourceRoot = (Join-Path $PSScriptRoot '..'),
    [string]$ExpectedSourceManifestSha256,
    [string]$ArtifactRoot = 'E:\AI\windows\revkit',
    [string]$GhConfigDir = 'E:\AI\windows\gh',
    [Parameter(Mandatory)][string]$IgnorePatternsSource,
    [string]$ProfilePath = (Join-Path $env:USERPROFILE '.config\shell\profile.ps1'),
    [string]$LegacyModulePath = (Join-Path ([IO.Path]::GetDirectoryName($PROFILE.CurrentUserCurrentHost)) 'Modules\RevealUI.RevStation\RevealUI.RevStation.psm1'),
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib' 'WindowsArtifactDeployment.ps1')
$files = @(Get-RevkitWindowsArtifactFiles -SourceRoot $SourceRoot -ExpectedSourceManifestSha256 $ExpectedSourceManifestSha256)
$ignore = Get-Item -LiteralPath $IgnorePatternsSource -ErrorAction Stop
if ($ignore.PSIsContainer -or ($ignore.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Ignore patterns must come from a preserved regular data file, not a live link into WSL.'
}
$profileExists = Test-Path -LiteralPath $ProfilePath
$oldProfile = if ($profileExists) { [IO.File]::ReadAllText($ProfilePath) } else { '' }
$newProfile = Update-RevkitWindowsProfile -Content $oldProfile
$sourceRef = $files[0].SourceCommit
$manifest = [ordered]@{
    schemaVersion = 1; sourceCommit = $sourceRef
    files = @($files | ForEach-Object { [ordered]@{ path = $_.RelativePath; sha256 = $_.Sha256 } })
    ignorePatternsSha256 = (Get-FileHash -LiteralPath $ignore.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    moduleIncludesDismount = $true
}
$manifestText = $manifest | ConvertTo-Json -Depth 8
$releaseId = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($manifestText))).ToLowerInvariant()
$release = Join-Path $ArtifactRoot ('releases\' + $releaseId)
$plan = [ordered]@{ SourceCommit = $sourceRef; ArtifactRoot = $ArtifactRoot; Release = $release; Files = $files.Count; GhConfigDir = $GhConfigDir; ProfilePath = $ProfilePath; ProfileChanges = ($oldProfile -cne $newProfile); ZedSettingsPreserved = $true; CredentialsCopied = $false; ScheduleActivated = $false; Applied = $false }
if (-not $Apply) { $plan | ConvertTo-Json -Depth 6; return }
if (-not $IsWindows) { throw 'Windows artifact activation requires Windows; planning and source tests remain cross-platform.' }
if (-not $PSCmdlet.ShouldProcess($ArtifactRoot, 'Deploy reviewed Windows artifacts, preserve profile/module originals and activate supported user configuration')) { return }
if (-not (Test-Path -LiteralPath $GhConfigDir -PathType Container)) { throw 'The approved existing Windows GH configuration must already be present; auth is never copied by this adapter.' }
$ghItem = Get-Item -LiteralPath $GhConfigDir
if (($ghItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'GH_CONFIG_DIR cannot be a reparse link.' }
$allowedSids = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
foreach ($access in (Get-Acl -LiteralPath $GhConfigDir).Access) {
    if ($access.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
        $access.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $allowedSids) { throw 'Existing GH configuration must retain private permissions.' }
}
Set-RevkitPrivateDirectory -Path $ArtifactRoot
$preserved = Join-Path $ArtifactRoot ('preserved\' + [Guid]::NewGuid().ToString('N'))
Set-RevkitPrivateDirectory -Path $preserved
if ($profileExists) { [IO.File]::WriteAllBytes((Join-Path $preserved 'profile.ps1'), [IO.File]::ReadAllBytes($ProfilePath)) }
if (Test-Path -LiteralPath $LegacyModulePath) { [IO.File]::WriteAllBytes((Join-Path $preserved 'legacy-module.psm1'), [IO.File]::ReadAllBytes($LegacyModulePath)) }
if (Test-Path -LiteralPath $release) {
    if (((Get-Item -LiteralPath $release).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Existing artifact release cannot be a reparse link.' }
    foreach ($file in $files) {
        $deployed = Join-Path $release $file.RelativePath
        if (-not (Test-Path -LiteralPath $deployed -PathType Leaf) -or (Get-FileHash -LiteralPath $deployed -Algorithm SHA256).Hash -ine $file.Sha256) {
            throw 'Existing release differs from reviewed source; no files were overwritten.'
        }
    }
} else {
    $staging = Join-Path $ArtifactRoot ('staging-' + [Guid]::NewGuid().ToString('N'))
    Set-RevkitPrivateDirectory -Path $staging
    foreach ($file in $files) {
        $destination = Join-Path $staging $file.RelativePath
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
        [IO.File]::Copy($file.SourcePath, $destination, $false)
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ine $file.Sha256) { throw 'Windows artifact copy verification failed.' }
    }
    [IO.File]::WriteAllText((Join-Path $staging 'artifact-manifest.json'), $manifestText, [Text.UTF8Encoding]::new($false))
    $stagedIgnore = Join-Path $staging 'shell\config\gitignore-global'
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($stagedIgnore))
    [IO.File]::Copy($ignore.FullName, $stagedIgnore, $false)
    if ((Get-FileHash -LiteralPath $stagedIgnore -Algorithm SHA256).Hash -ine $manifest.ignorePatternsSha256) { throw 'Ignore data copy verification failed.' }
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($release))
    [IO.Directory]::Move($staging, $release)
}
$ignoreTarget = Join-Path $release 'shell\config\gitignore-global'
if (Test-Path -LiteralPath $ignoreTarget) {
    if ((Get-FileHash -LiteralPath $ignoreTarget -Algorithm SHA256).Hash -ine $manifest.ignorePatternsSha256) { throw 'Existing ignore data differs from the reviewed data snapshot.' }
} else { [IO.File]::Copy($ignore.FullName, $ignoreTarget, $false) }
if ($profileExists -and [IO.File]::ReadAllText($ProfilePath) -cne $oldProfile) { throw 'Owner profile changed during deployment; activation refused.' }
$previous = [ordered]@{
    revealuiRoot = [Environment]::GetEnvironmentVariable('REVEALUI_ROOT', 'User')
    ghConfigDir = [Environment]::GetEnvironmentVariable('GH_CONFIG_DIR', 'User')
    excludesFile = @(& git config --global --get core.excludesFile) -join ''
}
if ($LASTEXITCODE -gt 1) { throw 'Cannot inspect the previous Windows Git ignore setting.' }
$previous | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $preserved 'previous-settings.json')
$profileWritten = $false
try {
    [Environment]::SetEnvironmentVariable('REVEALUI_ROOT', $release, 'User')
    [Environment]::SetEnvironmentVariable('GH_CONFIG_DIR', $GhConfigDir, 'User')
    & git config --global core.excludesFile $ignoreTarget
    if ($LASTEXITCODE -ne 0) { throw 'Windows-local Git ignore activation failed.' }
    $parent = [IO.Path]::GetDirectoryName($ProfilePath)
    $null = [IO.Directory]::CreateDirectory($parent)
    $temporary = Join-Path $parent ('revkit-profile-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temporary, $newProfile, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, $ProfilePath, $true)
    $profileWritten = $true
    $plan.Applied = $true
    $plan.PreservationDirectory = $preserved
    $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $preserved 'deployment-result.json')
} catch {
    [Environment]::SetEnvironmentVariable('REVEALUI_ROOT', $previous.revealuiRoot, 'User')
    [Environment]::SetEnvironmentVariable('GH_CONFIG_DIR', $previous.ghConfigDir, 'User')
    if ([string]::IsNullOrWhiteSpace($previous.excludesFile)) { & git config --global --unset core.excludesFile } else { & git config --global core.excludesFile $previous.excludesFile }
    if ($profileWritten -and [IO.File]::ReadAllText($ProfilePath) -ceq $newProfile) {
        if ($profileExists) { [IO.File]::WriteAllBytes($ProfilePath, [IO.File]::ReadAllBytes((Join-Path $preserved 'profile.ps1'))) } else { [IO.File]::Delete($ProfilePath) }
    }
    throw
}
$plan | ConvertTo-Json -Depth 6

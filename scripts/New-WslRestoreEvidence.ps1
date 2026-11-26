#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ArtifactPath,
    [Parameter(Mandatory)][string]$RecoveryDistro,
    [Parameter(Mandatory)][string]$ExpectedUser,
    [Parameter(Mandatory)][string]$ExpectedUbuntuVersion,
    [Parameter(Mandatory)][string]$ExpectedRepository,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$SourceDistro = 'Ubuntu',
    [int]$ExpectedUid = 1000
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib' 'WslBackup.ps1')
. (Join-Path $PSScriptRoot '..' 'powershell' 'Modules' 'RevealUI.RevStation' 'Private' 'Invoke-WslProbe.ps1')
if ($RecoveryDistro -ieq $SourceDistro) { throw 'Restore verification requires a separate recovery registration.' }
$sourceVhdx = Get-WslRegisteredVhdx -Distro $SourceDistro
$recoveryVhdx = Get-WslRegisteredVhdx -Distro $RecoveryDistro
$artifact = Get-WslBackupArtifact $ArtifactPath
if ([IO.Path]::GetFullPath($sourceVhdx) -ieq [IO.Path]::GetFullPath($recoveryVhdx)) {
    throw 'Recovery registration cannot share the source VHD.'
}
$verificationLayout = 'independent-copy'
if ([IO.Path]::GetFullPath($recoveryVhdx) -ieq $artifact.FullName) {
    if (($artifact.Attributes -band [IO.FileAttributes]::ReadOnly) -eq 0) {
        throw 'Import-in-place verification requires the immutable artifact already protected read-only.'
    }
    $verificationLayout = 'read-only-import-in-place'
}
$running = Invoke-WslProbe -Arguments @('--list', '--running', '--quiet')
if ($running.ExitCode -ne 0) { throw 'Cannot inspect recovery execution state.' }
$names = @($running.Output | ForEach-Object { $_.Replace([string][char]0, '').Trim() })
if ($SourceDistro -cin $names -or $RecoveryDistro -cnotin $names) {
    throw 'Source must already be stopped and the isolated recovery already running. This verifier never boots or terminates a distribution.'
}
if (-not $PSCmdlet.ShouldProcess($RecoveryDistro, 'Probe an already isolated restoration and hash the preserved recovery artifact')) { return }
$hash = (Get-FileHash -LiteralPath $artifact.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$probeCode = @'
import json, os, pathlib, pwd, subprocess, sys
user, expected_version, repository, expected_uid = sys.argv[1:]
pid1 = pathlib.Path('/proc/1/comm').read_text().strip()
if not (pid1 == 'init' or pid1.startswith('init(')):
    raise SystemExit('Recovery must use an isolated maintenance boot with systemd disabled')
allowed = {'init', 'SessionLeader', 'bash', 'sh', 'python3', 'python3.14', 'sleep', 'timeout'}
unexpected = []
for proc in pathlib.Path('/proc').iterdir():
    if not proc.name.isdecimal():
        continue
    try:
        name = (proc / 'comm').read_text().strip()
    except FileNotFoundError:
        continue
    if name not in allowed and not name.startswith(('init(', 'Relay(')):
        unexpected.append(name)
if unexpected:
    raise SystemExit('Unexpected recovery processes; service isolation is unproven')
release = {}
for line in pathlib.Path('/etc/os-release').read_text().splitlines():
    key, separator, value = line.partition('=')
    if separator:
        release[key] = value.strip('"')
if release.get('ID') != 'ubuntu' or release.get('VERSION_ID') != expected_version:
    raise SystemExit('Restored Ubuntu identity differs from expected snapshot')
account = pwd.getpwnam(user)
if account.pw_uid != int(expected_uid) or account.pw_uid <= 0 or not account.pw_dir.startswith('/home/'):
    raise SystemExit('Restored user identity differs from expected snapshot')
rootfs = subprocess.run(['findmnt', '--json', '--target', '/', '--output', 'FSTYPE'], capture_output=True, text=True, timeout=10, check=True)
rows = json.loads(rootfs.stdout)['filesystems']
if len(rows) != 1 or rows[0]['fstype'] != 'ext4':
    raise SystemExit('Restored root is not the expected ext4 filesystem')
repo = pathlib.Path(repository)
if not repo.is_absolute() or not repo.is_dir() or not pathlib.Path(account.pw_dir).is_dir():
    raise SystemExit('Restored home or repository is unavailable')
print(json.dumps({'protocol': 'revealfleet-isolated-restore-probe-v1', 'pid1Comm': pid1,
                  'rootFilesystem': 'ext4', 'ubuntuVersion': expected_version,
                  'user': user, 'uid': account.pw_uid, 'homeExists': True,
                  'repositoryExists': True, 'unexpectedProcesses': []}))
'@
$probe = Invoke-WslProbe -Arguments @('-d', $RecoveryDistro, '-u', 'root', '--exec', '/usr/bin/python3', '-I', '-c',
    $probeCode, $ExpectedUser, $ExpectedUbuntuVersion, $ExpectedRepository, [string]$ExpectedUid)
if ($probe.ExitCode -ne 0) { throw 'Independent restoration probe failed; no successful evidence was recorded.' }
$observed = ($probe.Output -join "`n") | ConvertFrom-Json -ErrorAction Stop
$afterHash = (Get-FileHash -LiteralPath $artifact.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
if ($afterHash -cne $hash) { throw 'Recovery artifact changed during validation; original artifact preservation failed.' }
$evidence = [ordered]@{
    schemaVersion = 1
    kind = 'revealfleet-wsl-restore-validation'
    verificationLayout = $verificationLayout
    verifierProtocol = 'revealfleet-isolated-restore-probe-v1'
    verifierSourceSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    sourceDistro = $SourceDistro
    recoveryDistro = $RecoveryDistro
    artifactSha256 = $hash
    artifactBytes = $artifact.Length
    artifactPreserved = $true
    verifiedAt = [DateTimeOffset]::UtcNow.ToString('o')
    probe = $observed
    checks = @{ registration = $true; filesystem = $true; boot = $true; identity = $true; servicesIsolated = $true }
}
$null = Assert-WslRestoreEvidence -Evidence ([pscustomobject]$evidence) -Sha256 $hash -Bytes $artifact.Length -Distro $SourceDistro
Write-WslBackupJsonNew -Path $OutputPath -Value $evidence
Write-Output $OutputPath

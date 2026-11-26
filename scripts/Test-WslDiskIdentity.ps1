#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$IdentityPath,
    [Parameter(Mandatory)][string]$LinuxIdentityPath,
    [string]$Distro = 'Ubuntu'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib' 'WslDiskIdentity.ps1')
. (Join-Path $PSScriptRoot '..' 'powershell' 'Modules' 'RevealUI.RevStation' 'Private' 'Invoke-WslProbe.ps1')
$identity = Get-Content -LiteralPath $IdentityPath -Raw | ConvertFrom-Json -ErrorAction Stop
$disk = Assert-WslDiskHardwareIdentity -Identity $identity -Disks @(Get-Disk) -Partitions @(Get-Partition)
if (-not $PSCmdlet.ShouldProcess("PHYSICALDRIVE$($disk.Number)", 'Verify the already attached disk using the maintained read-only root probe')) { return }
$result = Invoke-WslProbe -Arguments @('-d', $Distro, '-u', 'root', '--exec', '/usr/bin/python3', '-I',
    '/usr/local/lib/revealfleet/wsl-disk-identity.py', '--identity', $LinuxIdentityPath, '--deadline-seconds', '25') -TimeoutSeconds 30
if ($result.ExitCode -ne 0) { throw 'Maintained Linux read-only identity verification failed or exceeded its deadline.' }
$verified = ($result.Output -join "`n") | ConvertFrom-Json -ErrorAction Stop
if ($verified.schemaVersion -ne 1 -or $verified.identityVerified -ne $true -or
    $verified.serial -cne $identity.serial -or $verified.model -cne $identity.model -or
    $verified.diskBytes -ne $identity.diskBytes -or $verified.partitionBytes -ne $identity.partitionBytes -or
    $verified.partitionUuid -cne $identity.partitionUuid -or $verified.filesystemUuid -cne $identity.filesystemUuid -or
    $verified.mountPoint -cne $identity.mountPoint -or $verified.mountState -cnotin @('MOUNTED', 'NOT_MOUNTED')) {
    throw 'Windows and Linux approved disk identities disagree.'
}
$verified | ConvertTo-Json -Depth 6

#Requires -Version 7.0

function Dismount-WSLDev {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$IdentityPath,
        [Parameter(Mandatory)][string]$LinuxIdentityPath,
        [string]$MountPath,
        [int]$DiskNumber = -1,
        [string]$Distro = 'Ubuntu'
    )
    $approved = Get-ApprovedDriveIdentity -IdentityPath $IdentityPath
    if ([string]::IsNullOrWhiteSpace($MountPath)) { $MountPath = $approved.Identity.mountPoint }
    if ($MountPath -cne $approved.Identity.mountPoint -or ($DiskNumber -ge 0 -and $DiskNumber -ne $approved.Disk.Number)) {
        throw 'Dismount target differs from the explicitly approved disk identity.'
    }
    $DiskNumber = $approved.Disk.Number
    if (-not $PSCmdlet.ShouldProcess("$MountPath (disk $DiskNumber)", 'Sync, unmount, detach and take the approved disk offline')) { return }
    if (-not (Test-IsAdmin)) { throw 'Dismount requires an already approved elevated Windows session.' }
    $probeArguments = @('-d', $Distro, '-u', 'root', '--exec', '/usr/bin/python3', '-I',
        '/usr/local/lib/revealfleet/wsl-disk-identity.py', '--identity', $LinuxIdentityPath,
        '--require-mount-point', $MountPath, '--deadline-seconds', '25')
    $probe = Invoke-WslProbe -Arguments $probeArguments -TimeoutSeconds 30
    if ($probe.ExitCode -ne 0) { throw 'Approved Linux device identity could not be established.' }
    $identity = ($probe.Output -join "`n") | ConvertFrom-Json -ErrorAction Stop
    foreach ($field in @('serial', 'model', 'diskBytes', 'partitionBytes', 'partitionUuid', 'filesystemUuid', 'mountPoint')) {
        if ([string]$identity.$field -cne [string]$approved.Identity.$field) { throw "Dismount identities disagree: $field" }
    }
    if ($identity.identityVerified -ne $true -or $identity.mountState -cnotin @('MOUNTED', 'NOT_MOUNTED')) {
        throw 'Linux mount identity is unverified.'
    }
    if ($identity.mountState -ceq 'MOUNTED') {
        $handles = Invoke-WslProbe -Arguments @('-d', $Distro, '-u', 'root', '--exec', '/usr/bin/fuser', '-m', '--', $MountPath)
        if ($handles.ExitCode -eq 0) { throw 'Approved mount has active consumers; quiesce them through their maintained service owner before dismounting.' }
        if ($handles.ExitCode -ne 1) { throw 'Cannot establish whether the approved mount has active consumers.' }
        $sync = Invoke-WslProbe -Arguments @('-d', $Distro, '-u', 'root', '--exec', '/usr/bin/sync', '-f', '--', $MountPath)
        if ($sync.ExitCode -ne 0) { throw 'Filesystem sync failed; disk was not detached.' }
        $unmount = Invoke-WslProbe -Arguments @('-d', $Distro, '-u', 'root', '--exec', '/usr/bin/umount', '--', $MountPath)
        if ($unmount.ExitCode -ne 0) { throw 'Filesystem unmount failed; disk was not detached.' }
        $after = Invoke-WslProbe -Arguments $probeArguments -TimeoutSeconds 30
        if ($after.ExitCode -ne 0 -or (($after.Output -join "`n") | ConvertFrom-Json).mountState -cne 'NOT_MOUNTED') {
            throw 'Filesystem unmount was not verified; disk was not detached.'
        }
    }
    $detach = Invoke-WslProbe -Arguments @('--unmount', ('\\.\PHYSICALDRIVE' + $DiskNumber))
    if ($detach.ExitCode -ne 0) { throw 'WSL detachment failed; Windows disk state was not changed.' }
    $current = Get-ApprovedDriveIdentity -IdentityPath $IdentityPath
    if ($current.Disk.Number -ne $DiskNumber) { throw 'Physical disk registration changed before offline transition.' }
    Set-Disk -Number $DiskNumber -IsOffline $true -ErrorAction Stop
    [pscustomobject]@{ DiskNumber = $DiskNumber; MountPath = $MountPath; Detached = $true; Offline = $true }
}

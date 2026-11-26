#Requires -Version 7.0

function Get-ApprovedDriveIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$IdentityPath)
    . (Join-Path $PSScriptRoot '..' '..' '..' '..' 'scripts' 'lib' 'WslDiskIdentity.ps1')
    $identity = Get-Content -LiteralPath $IdentityPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $disk = Assert-WslDiskHardwareIdentity -Identity $identity -Disks @(Get-Disk) -Partitions @(Get-Partition)
    [pscustomobject]@{ Identity = $identity; Disk = $disk }
}

function Assert-SandboxLinuxIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Identity)
    if ($Identity.mountPoint -cne '/mnt/sandbox' -or $Identity.filesystemLabel -cne 'Sandbox') {
        throw 'The Sandbox command cannot adopt another filesystem label or mountpoint.'
    }
    $probe = Invoke-WslProbe -Arguments @('-d', 'Ubuntu', '--exec', '/usr/bin/cat', '/etc/revealfleet/disks/sandbox.json')
    if ($probe.ExitCode -ne 0) { throw 'Approved root-owned Sandbox identity is not deployed; configure it through RevKit provisioning.' }
    $linux = ($probe.Output -join "`n") | ConvertFrom-Json -ErrorAction Stop
    foreach ($field in @('schemaVersion', 'serial', 'model', 'diskBytes', 'partitionBytes', 'partitionStartSectors', 'partitionSectors', 'partitionUuid', 'filesystemUuid', 'filesystemLabel', 'mountPoint')) {
        if ([string]$linux.$field -cne [string]$Identity.$field) { throw "Windows/Linux approved Sandbox identities disagree: $field" }
    }
}

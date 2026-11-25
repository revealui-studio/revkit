#Requires -Version 7.0

function Assert-WslDiskHardwareIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Identity,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Disks,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Partitions
    )
    if ($Identity.schemaVersion -ne 1 -or [string]::IsNullOrWhiteSpace($Identity.serial) -or
        [string]::IsNullOrWhiteSpace($Identity.model) -or $Identity.diskBytes -le 0 -or
        $Identity.partitionBytes -le 0 -or $Identity.partitionStartSectors -le 0 -or
        $Identity.partitionSectors * 512 -ne $Identity.partitionBytes) {
        throw 'Expected complete configured hardware and GPT identity.'
    }
    $matching = @($Disks | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.SerialNumber) -and $_.SerialNumber.Trim() -ceq $Identity.serial -and $_.FriendlyName -ceq $Identity.model -and $_.Size -eq $Identity.diskBytes
    })
    if ($matching.Count -ne 1) { throw 'Physical disk hardware identity is missing or ambiguous.' }
    $disk = $matching[0]
    if ($disk.IsBoot -or $disk.IsSystem -or $disk.BusType.ToString() -cne 'USB' -or $disk.PartitionStyle.ToString() -cne 'GPT') {
        throw 'Configured disk is not the expected independent USB GPT device.'
    }
    $rows = @($Partitions | Where-Object { $_.DiskNumber -eq $disk.Number })
    if ($rows.Count -ne 1) { throw 'Configured physical disk must have exactly its approved partition.' }
    $partition = $rows[0]
    if ($partition.Size -ne $Identity.partitionBytes -or $partition.Offset -ne $Identity.partitionStartSectors * 512 -or
        [Guid]$partition.Guid -ne [Guid]$Identity.partitionUuid -or
        [Guid]$partition.GptType -ne [Guid]'0fc63daf-8483-4772-8e79-3d69d8477de4' -or
        -not [string]::IsNullOrWhiteSpace([string]$partition.DriveLetter)) {
        throw 'Windows GPT geometry or partition identity differs from the approved disk.'
    }
    return $disk
}

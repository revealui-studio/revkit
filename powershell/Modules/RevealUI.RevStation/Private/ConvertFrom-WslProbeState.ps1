#Requires -Version 7.0

function ConvertFrom-WslProbeState {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Output,
        [Parameter(Mandatory)][string[]]$AllowedStates,
        [int]$ExitCode = 0
    )
    if ($ExitCode -ne 0) { return $null }
    $lines = @($Output | ForEach-Object { $_.ToString().Replace([string][char]0, '').Trim() } | Where-Object { $_.Length -gt 0 })
    if ($lines.Count -ne 1 -or $lines[0] -cnotin $AllowedStates) { return $null }
    return $lines[0]
}

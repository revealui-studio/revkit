#Requires -Version 7.0

function Get-SavedRevkitRoot {
    [CmdletBinding()]
    param()
    return [Environment]::GetEnvironmentVariable('REVEALUI_ROOT', 'User')
}

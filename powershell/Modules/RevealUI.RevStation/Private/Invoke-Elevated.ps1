#Requires -Version 7.0
#Requires -PSEdition Core

function Invoke-Elevated {
    <#
    .SYNOPSIS
        Runs a PowerShell command in an elevated pwsh.exe process with module discovery.
    .DESCRIPTION
        Launches pwsh.exe as admin, discovers the RevealUI.RevStation module on any drive,
        imports it, and executes the supplied command string. Uses -EncodedCommand to
        avoid escaping issues with Start-Process argument passing.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [switch]$Wait
    )

    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..' '..'))
    $manifest = Join-Path $root 'powershell\Modules\RevealUI.RevStation\RevealUI.RevStation.psd1'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw 'Active maintained Windows module artifact is unavailable.' }
    $quotedManifest = $manifest.Replace("'", "''")
    $script = @"
Import-Module -Name '$quotedManifest' -Force -ErrorAction Stop
$Command
"@

    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script))

    $arguments = @(
        '-NonInteractive'
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-EncodedCommand', $encoded
    )

    $startParams = @{
        FilePath     = 'pwsh.exe'
        Verb         = 'RunAs'
        ArgumentList = $arguments
    }

    if ($Wait) {
        $startParams['Wait'] = $true
    }

    Start-Process @startParams
}

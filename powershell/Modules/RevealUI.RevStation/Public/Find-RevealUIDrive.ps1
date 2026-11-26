#Requires -Version 7.0
#Requires -PSEdition Core

function Find-RevealUIDrive {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [switch]$UpdateEnv
    )

    $marker = "powershell\Modules\RevealUI.RevStation\RevealUI.RevStation.psd1"

    $savedRoot = Get-SavedRevkitRoot
    if (-not [string]::IsNullOrWhiteSpace($savedRoot)) {
        if (-not (Test-Path -LiteralPath (Join-Path $savedRoot $marker) -PathType Leaf)) {
            throw 'Configured RevKit Windows artifact is unavailable; legacy checkout discovery is not a replacement.'
        }
        if ($UpdateEnv) { $env:REVEALUI_ROOT = $savedRoot }
        return $savedRoot
    }

    # Layer 1: Check existing env var
    if ($env:REVEALUI_ROOT -and (Test-Path (Join-Path $env:REVEALUI_ROOT $marker) -ErrorAction SilentlyContinue)) {
        return $env:REVEALUI_ROOT
    }

    # Layer 2: Check user home (C: drive, always available)
    $homeRoot = Join-Path $env:USERPROFILE ".revealui"
    if (Test-Path (Join-Path $homeRoot $marker) -ErrorAction SilentlyContinue) {
        if ($UpdateEnv) {
            $env:REVEALUI_ROOT = $homeRoot
            [System.Environment]::SetEnvironmentVariable('REVEALUI_ROOT', $homeRoot, 'User')
            Write-Verbose "Updated REVEALUI_ROOT to: $homeRoot"
        }
        return $homeRoot
    }

    # Layer 3: Scan available drives for .revealui folder with our marker (SSD fallback)
    $found = Get-Volume | Where-Object { $_.DriveLetter } |
             ForEach-Object { "$($_.DriveLetter):\.revealui"; "$($_.DriveLetter):\professional\.revealui" } |
             Where-Object { Test-Path (Join-Path $_ $marker) -ErrorAction SilentlyContinue } |
             Select-Object -First 1

    if ($found -and $UpdateEnv) {
        $env:REVEALUI_ROOT = $found
        [System.Environment]::SetEnvironmentVariable('REVEALUI_ROOT', $found, 'User')
        Write-Verbose "Updated REVEALUI_ROOT to: $found"
    }

    return $found
}

#Requires -Version 7.0

function ConvertFrom-WslPlatformVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Output)
    $lines = @($Output | ForEach-Object { $_.Replace([string][char]0, '').Trim() } | Where-Object { $_.Length -gt 0 })
    if ($lines.Count -eq 0) { throw 'WSL platform version output was empty.' }
    $separator = $lines[0].IndexOf(':')
    if ($separator -lt 0) { throw 'WSL platform version output is unsupported.' }
    $text = $lines[0].Substring($separator + 1).Trim()
    $parts = $text.Split('.')
    if ($parts.Count -ne 4) { throw 'Expected the four-part WSL platform version.' }
    foreach ($part in $parts) {
        if ($part.Length -eq 0) { throw 'Invalid WSL platform version component.' }
        foreach ($character in $part.ToCharArray()) {
            if ($character -lt '0' -or $character -gt '9') { throw 'Invalid WSL platform version component.' }
        }
    }
    $version = $null
    if (-not [Version]::TryParse($text, [ref]$version)) { throw 'Invalid WSL platform version.' }
    return $version
}

function Get-WslPlatformVersion {
    [CmdletBinding()]
    param()
    $output = @(& wsl.exe --version)
    if ($LASTEXITCODE -ne 0) { throw 'The installed WSL provider does not expose supported platform version detection.' }
    return ConvertFrom-WslPlatformVersion -Output $output
}

function Assert-WslPlatformVersion {
    [CmdletBinding()]
    param([Version]$Version = (Get-WslPlatformVersion), [Version]$Minimum = '3.0.5.0')
    if ($Version -lt $Minimum) {
        throw "WSL platform $Version is below required $Minimum. Update the supported WSL platform before Ubuntu 26 setup; no local cgroup change or automatic update was applied."
    }
    return $Version
}

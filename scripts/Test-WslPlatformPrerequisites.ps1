#Requires -Version 7.0

[CmdletBinding()]
param([Version]$Minimum = '3.0.5.0')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib' 'WslPlatform.ps1')
$version = Assert-WslPlatformVersion -Minimum $Minimum
[pscustomobject]@{ PlatformVersion = $version.ToString(); RequiredMinimum = $Minimum.ToString(); Passed = $true; Mutated = $false } | ConvertTo-Json -Compress

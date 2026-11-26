# Apply-WslHostFix.ps1
# One elevated operator entry: wrap the weekly backup task (headless + WakeToRun),
# then move the Ubuntu VHD off C: onto E: if it is still on C:.
# The move shuts WSL down. Skip it when the VHD is already at $Destination.

#Requires -Version 7.0

[CmdletBinding()]
param(
  [string]$Distro = 'Ubuntu',
  [string]$Destination = 'E:\WSL\Ubuntu'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
. (Join-Path $here 'lib' 'WslPlatform.ps1')
$null = Assert-WslPlatformVersion

$src = "C:\WSL\$Distro\ext4.vhdx"
$already = Join-Path $Destination 'ext4.vhdx'
$vhdAlreadyMoved = -not (Test-Path -LiteralPath $src) -and (Test-Path -LiteralPath $already)

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  # Pin to %TEMP%: Start-Process -Verb RunAs from a WSL UNC cwd is canceled.
  Start-Process -FilePath 'pwsh.exe' -Verb RunAs -WorkingDirectory $env:TEMP -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
    '-Distro', $Distro, '-Destination', $Destination
  )
  return
}

$register = Join-Path $here 'Register-WeeklyBackupTask.ps1'
$move = Join-Path $here 'Move-WslVhdx.ps1'
if (-not (Test-Path $register)) { throw "Missing $register" }
if (-not (Test-Path $move)) { throw "Missing $move" }

Write-Host '=== 1/2 Register-WeeklyBackupTask (conhost --headless, WakeToRun) ==='
& $register
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Register-WeeklyBackupTask failed: $LASTEXITCODE" }

if ($vhdAlreadyMoved) {
  Write-Host "=== 2/2 Move-WslVhdx skipped: VHD already at $already (will not shut WSL down) ==="
} else {
  Write-Host '=== 2/2 Move-WslVhdx (wsl --shutdown, then --manage --move) ==='
  & $move -Distro $Distro -Destination $Destination
  if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Move-WslVhdx failed: $LASTEXITCODE" }
}

Write-Host 'Apply-WslHostFix DONE'

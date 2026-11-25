# Register-WeeklyBackupTask.ps1
# Registers the headless backup task disabled until recovery acceptance passes.
# Run elevated (admin). Idempotent.
#
# Bare pwsh.exe flashes a window when Windows Terminal is the default console host.
# LastTaskResult 0x40 (64) on a sleeping laptop is the host-sleep kill class;
# WakeToRun=true is required so Sunday 03:00 actually wakes the machine.

#Requires -Version 7.0

[CmdletBinding()]
param(
  [string]$TaskName = 'RevealUI-WSL-Weekly-Backup',
  [string]$ScriptPath = (Join-Path $PSScriptRoot 'weekly-wsl-backup.ps1')
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  $self = $PSCommandPath
  Start-Process -FilePath 'pwsh.exe' -Verb RunAs -Wait -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $self,
    '-TaskName', $TaskName, '-ScriptPath', $ScriptPath
  )
  exit $LASTEXITCODE
}

if (-not (Test-Path -LiteralPath $ScriptPath)) {
  throw "Backup script not found: $ScriptPath"
}

$action = New-ScheduledTaskAction `
  -Execute 'conhost.exe' `
  -Argument "--headless pwsh.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 3am

$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -StartWhenAvailable `
  -WakeToRun `
  -Disable `
  -ExecutionTimeLimit (New-TimeSpan -Hours 4)

# LogonType lives on the principal, not Register-ScheduledTask (PS 7 ScheduledTasks).
$principal = New-ScheduledTaskPrincipal `
  -UserId $env:USERNAME `
  -LogonType S4U `
  -RunLevel Highest

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $action `
  -Trigger $trigger `
  -Settings $settings `
  -Principal $principal `
  -Description 'Weekly wsl --export of Ubuntu distro to the SnapshotDir used by weekly-wsl-backup.ps1. Headless conhost; WakeToRun for the 03:00 sleep-kill class.' `
  -Force | Out-Null

$t = Get-ScheduledTask -TaskName $TaskName
Write-Host "Registered $TaskName disabled; recurring backup acceptance requires verified recovery and adequate staging capacity."
Write-Host "  Execute: $($t.Actions.Execute) $($t.Actions.Arguments)"
Write-Host "  WakeToRun: $($t.Settings.WakeToRun)"

#Requires -Version 7.0
#Requires -PSEdition Core

function Register-DevMountTask {
    <#
    .SYNOPSIS
        Registers a Task Scheduler task to auto-mount the Sandbox drive to WSL.
    .DESCRIPTION
        Creates a scheduled task with three triggers (logon, USB insertion, periodic 30-min)
        that runs Mount-WSLDev via pwsh.exe with inline module discovery. Requires elevation.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param()

    $taskName = 'WSL-Mount-DevDrive'

    if (-not (Test-IsAdmin)) {
        if (-not $PSCmdlet.ShouldProcess($taskName, 'Elevate to register scheduled task')) {
            return
        }
        Write-DevLog 'Elevating to register mount task...' -Level WARN -Source 'TaskReg'
        Invoke-Elevated -Command 'Register-DevMountTask' -Wait
        return
    }

    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' '..' '..'))
    $manifest = Join-Path $root 'powershell\Modules\RevealUI.RevStation\RevealUI.RevStation.psd1'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw 'Active maintained Windows module artifact is unavailable.' }
    $quotedManifest = $manifest.Replace("'", "''")
    $command = @"
Import-Module -Name '$quotedManifest' -Force -ErrorAction Stop
Mount-WSLDev -TriggerSource scheduled
"@

    # Base64 encode to avoid XML escaping issues
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))

    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Auto-mount WD My Passport SSD to WSL at /mnt/sandbox via RevealUI.RevStation module</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$($env:USERDOMAIN)\$($env:USERNAME)</UserId>
      <Delay>PT10S</Delay>
    </LogonTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-Kernel-PnP/Configuration"&gt;&lt;Select Path="Microsoft-Windows-Kernel-PnP/Configuration"&gt;*[System[EventID=400]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
      <Delay>PT10S</Delay>
    </EventTrigger>
    <TimeTrigger>
      <Enabled>true</Enabled>
      <StartBoundary>2026-01-01T00:00:00</StartBoundary>
      <Repetition>
        <Interval>PT30M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$($env:USERDOMAIN)\$($env:USERNAME)</UserId>
      <LogonType>S4U</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>false</Enabled>
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>conhost.exe</Command>
      <Arguments>--headless pwsh.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded</Arguments>
    </Exec>
  </Actions>
</Task>
"@

    if (-not $PSCmdlet.ShouldProcess($taskName, 'Register scheduled task')) {
        return
    }

    # Remove existing task if present
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    try {
        Register-ScheduledTask -TaskName $taskName -Xml $taskXml -Force | Out-Null
        Write-DevLog "Scheduled task '$taskName' registered disabled; approved identity and device acceptance are required before activation" -Source 'TaskReg'
    } catch {
        $err = [System.Management.Automation.ErrorRecord]::new(
            $_.Exception, 'TaskRegistrationFailed',
            [System.Management.Automation.ErrorCategory]::InvalidOperation, $taskName)
        $PSCmdlet.ThrowTerminatingError($err)
    }

    # Verify
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-DevLog 'Task registration failed — task not found after creation' -Level ERROR -Source 'TaskReg'
        return
    }

    $triggerCount = $task.Triggers.Count
    Write-Host ''
    Write-DevLog "Verification:" -Source 'TaskReg'
    Write-Host "  Triggers: $triggerCount (logon, USB, periodic 30min)"
    Write-Host "  Engine:   conhost --headless pwsh.exe (PS7, no window)"
    Write-Host "  RunLevel: $($task.Principal.RunLevel)"
    Write-Host ''

    if ($triggerCount -lt 3) {
        Write-DevLog "Expected 3 triggers but found $triggerCount" -Level WARN -Source 'TaskReg'
    }
}

#Requires -Version 7.0
#Requires -PSEdition Core

function Mount-WSLDev {
    <#
    .SYNOPSIS
        Finds the Sandbox SSD by serial number, attaches it to WSL, and mounts at /mnt/sandbox.
    .DESCRIPTION
        All mount logic is inline. No external script dependency. When run without elevation,
        self-elevates via pwsh.exe with module discovery. Includes WSL readiness polling,
        retry loop for wsl --mount, and block device wait.
    .ALIASES
        Mount-Sandbox
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [switch]$SkipWait,

        [ValidateSet('logon', 'usb', 'periodic', 'scheduled', 'manual')]
        [string]$TriggerSource = 'manual'
    )

    $logDir = Get-ModuleLogPath
    $logFile = Join-Path $logDir 'mount-sandbox.log'

    # Load local-config.ps1 (gitignored) for hardware-specific values
    $localConfig = Join-Path $PSScriptRoot '..' 'local-config.ps1'
    if (Test-Path $localConfig) {
        . (Resolve-Path $localConfig)
    }
    if (-not $DevDriveSerial) {
        $err = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new(
                'DevDriveSerial is not set. Create powershell/Modules/RevealUI.RevStation/local-config.ps1 from local-config.example.ps1 and set $DevDriveSerial to your SSD serial number.'),
            'SerialNotConfigured',
            [System.Management.Automation.ErrorCategory]::InvalidOperation,
            $null)
        $PSCmdlet.ThrowTerminatingError($err)
    }

    # --- Self-elevation if not admin ---
    if (-not (Test-IsAdmin)) {
        if (-not $PSCmdlet.ShouldProcess('Mount-WSLDev', 'Elevate to administrator')) {
            return
        }
        Write-DevLog 'Elevating to mount Sandbox drive...' -Level WARN -Source 'Mount' -LogFile $logFile
        $cmd = "Mount-WSLDev -SkipWait -TriggerSource $TriggerSource"
        Invoke-Elevated -Command $cmd -Wait

        # Verify from non-elevated session
        Write-DevLog 'Checking mount status...' -Source 'Mount' -LogFile $logFile
        $status = wsl.exe -d Ubuntu -e bash -c "mountpoint -q /mnt/sandbox && echo 'YOURMOUNT_YES' || echo 'YOURMOUNT_NO'" 2>&1
        if ($status -match 'YOURMOUNT_YES') {
            Write-DevLog 'Sandbox drive: MOUNTED' -Source 'Mount' -LogFile $logFile
        } else {
            Write-DevLog 'Sandbox drive: NOT MOUNTED' -Level ERROR -Source 'Mount' -LogFile $logFile
        }
        return
    }

    # --- Running elevated from here ---

    # Wait for system stabilization (skip when called from Restart-WSL or scheduled)
    if (-not $SkipWait) {
        Write-DevLog 'Waiting for system stabilization (8s)...' -Source 'Mount' -LogFile $logFile
        Start-Sleep -Seconds 8
    }

    # --- Check if already mounted ---
    $mountCheck = (wsl.exe -d Ubuntu -e bash -c "mountpoint -q /mnt/sandbox && echo YOURMOUNT_YES || echo YOURMOUNT_NO" 2>&1) -join ' '
    if ($mountCheck -match 'YOURMOUNT_YES') {
        Write-DevLog 'Sandbox drive already mounted at /mnt/sandbox' -Source 'Mount' -LogFile $logFile
        return
    }

    # --- Handle WSL not ready ---
    if ($mountCheck -match 'WSL_E_|Wsl/|not running|not found') {
        Write-DevLog "WSL not ready: $mountCheck" -Level WARN -Source 'Mount' -LogFile $logFile
        Write-DevLog 'Waiting for WSL to become available...' -Source 'Mount' -LogFile $logFile
        $wslReady = $false
        for ($i = 1; $i -le 6; $i++) {
            Start-Sleep -Seconds 5
            $check = wsl.exe -d Ubuntu -e echo READY 2>&1
            if ($check -match 'READY') {
                $wslReady = $true
                Write-DevLog "WSL ready after $($i * 5)s" -Source 'Mount' -LogFile $logFile
                break
            }
        }
        if (-not $wslReady) {
            Write-DevLog 'WSL did not become available after 30s. Aborting.' -Level ERROR -Source 'Mount' -LogFile $logFile
            $err = [System.Management.Automation.ErrorRecord]::new(
                [System.TimeoutException]::new('WSL did not become available after 30s'),
                'WSLTimeout', [System.Management.Automation.ErrorCategory]::ResourceUnavailable, $null)
            $PSCmdlet.ThrowTerminatingError($err)
        }
    }

    # --- Find the Sandbox drive by serial number ---
    # Exact match after trim. -match would treat the serial as a regex and
    # could attach a different disk whose serial merely contains this string.
    $wantedSerial = $DevDriveSerial.Trim()
    $devDisk = Get-Disk | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.SerialNumber) -and
        $_.SerialNumber.Trim() -eq $wantedSerial
    } | Select-Object -First 1

    if (-not $devDisk) {
        Write-DevLog "Sandbox drive not found (serial: $DevDriveSerial). Is it plugged in?" -Level WARN -Source 'Mount' -LogFile $logFile
        return  # Not an error. The drive is simply not connected
    }

    $driveNumber = $devDisk.Number
    Write-DevLog "Found Sandbox drive at PHYSICALDRIVE$driveNumber (Status: $($devDisk.OperationalStatus))" -Source 'Mount' -LogFile $logFile

    if (-not $PSCmdlet.ShouldProcess("PHYSICALDRIVE$driveNumber", 'Attach and mount to WSL')) {
        return
    }

    # --- Clean up any stale attachment ---
    wsl.exe --unmount "\\.\PHYSICALDRIVE$driveNumber" 2>&1 | Out-Null

    # --- Attach with retry ---
    $maxRetries = 3
    $attached = $false

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        Write-DevLog "Attaching PHYSICALDRIVE$driveNumber to WSL (attempt $attempt/$maxRetries)..." -Source 'Mount' -LogFile $logFile
        $attachOutput = wsl.exe --mount "\\.\PHYSICALDRIVE$driveNumber" --bare 2>&1

        if ($LASTEXITCODE -eq 0) {
            $attached = $true
            Write-DevLog 'Disk attached successfully' -Source 'Mount' -LogFile $logFile
            break
        }

        Write-DevLog "Attach attempt $attempt failed (exit $LASTEXITCODE): $attachOutput" -Level WARN -Source 'Mount' -LogFile $logFile

        if ($attempt -lt $maxRetries) {
            Write-DevLog 'Retrying in 5s...' -Source 'Mount' -LogFile $logFile
            Start-Sleep -Seconds 5
            wsl.exe --unmount "\\.\PHYSICALDRIVE$driveNumber" 2>&1 | Out-Null
        }
    }

    if (-not $attached) {
        Write-DevLog "Failed to attach Sandbox drive after $maxRetries attempts" -Level ERROR -Source 'Mount' -LogFile $logFile
        $err = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new("Failed to attach PHYSICALDRIVE$driveNumber after $maxRetries attempts"),
            'AttachFailed', [System.Management.Automation.ErrorCategory]::ResourceUnavailable, $null)
        $PSCmdlet.ThrowTerminatingError($err)
    }

    # --- Wait for block device to appear in WSL ---
    Write-DevLog 'Waiting for block device to appear in WSL...' -Source 'Mount' -LogFile $logFile
    $deviceReady = $false
    for ($i = 1; $i -le 10; $i++) {
        Start-Sleep -Seconds 1
        $blkCheck = wsl.exe -d Ubuntu -e bash -c "blkid -L Sandbox 2>/dev/null && echo FOUND || echo NOTFOUND" 2>&1
        if ($blkCheck -match 'FOUND') {
            $deviceReady = $true
            Write-DevLog "Block device detected after ${i}s" -Source 'Mount' -LogFile $logFile
            break
        }
    }

    if (-not $deviceReady) {
        # The Sandbox-labeled partition never showed up. Do not run the mount
        # helper anyway. The helper also refuses when the Sandbox label is
        # missing, and a bare WSL attach with no label is not a mount. Abort.
        # A drive that was only slow to publish its label is recovered on the
        # next trigger (logon/usb/periodic) once the label settles.
        Write-DevLog 'Sandbox-labeled block device did not appear after 10s. Refusing to run the mount helper.' -Level ERROR -Source 'Mount' -LogFile $logFile
        $err = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('Sandbox-labeled block device (blkid -L Sandbox) did not appear after 10s. Refusing to run the mount helper.'),
            'SandboxDeviceMissing', [System.Management.Automation.ErrorCategory]::ResourceUnavailable, $null)
        $PSCmdlet.ThrowTerminatingError($err)
    }

    # --- Mount the partition inside WSL ---
    # Always pass --mount-only so the NOPASSWD sudoers rule matches; the rule
    # is pinned to this exact arg list (see revkit/bootstrap.sh + GAP-119).
    # First-time marker setup is `sudo mount-sandbox-drive.sh --init` (manual,
    # interactive sudo) and is documented in revkit/docs/tier-capabilities.md.
    Write-DevLog 'Mounting partition inside WSL at /mnt/sandbox...' -Source 'Mount' -LogFile $logFile
    $wslResult = wsl.exe -d Ubuntu -e sudo /usr/local/bin/mount-sandbox-drive.sh --mount-only 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-DevLog "WSL mount helper failed (exit $LASTEXITCODE): $wslResult" -Level ERROR -Source 'Mount' -LogFile $logFile
        $err = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new("WSL mount helper failed (exit $LASTEXITCODE): $wslResult"),
            'MountHelperFailed', [System.Management.Automation.ErrorCategory]::InvalidResult, $null)
        $PSCmdlet.ThrowTerminatingError($err)
    }

    # --- Verify ---
    $verify = (wsl.exe -d Ubuntu -e bash -c "mountpoint -q /mnt/sandbox && echo SUCCESS || echo FAILED" 2>&1) -join ' '
    if ($verify -match 'SUCCESS') {
        Write-DevLog 'WSL Sandbox drive mounted successfully at /mnt/sandbox' -Source 'Mount' -LogFile $logFile
    } else {
        Write-DevLog 'Mount verification failed' -Level ERROR -Source 'Mount' -LogFile $logFile
        $err = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('Mount verification failed. /mnt/sandbox not mounted'),
            'VerifyFailed', [System.Management.Automation.ErrorCategory]::InvalidResult, $null)
        $PSCmdlet.ThrowTerminatingError($err)
    }
}

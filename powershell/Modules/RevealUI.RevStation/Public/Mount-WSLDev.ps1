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

        [string]$IdentityPath,

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
    if ([string]::IsNullOrWhiteSpace($IdentityPath)) {
        $configured = Get-Variable -Name DevDriveIdentityPath -ErrorAction SilentlyContinue
        if ($null -ne $configured) { $IdentityPath = [string]$configured.Value }
    }
    if ([string]::IsNullOrWhiteSpace($IdentityPath)) {
        throw 'Configure the approved Sandbox disk/GPT/filesystem identity and pass -IdentityPath; no disk was attached or mounted.'
    }

    # --- Self-elevation if not admin ---
    if (-not (Test-IsAdmin)) {
        if (-not $PSCmdlet.ShouldProcess('Mount-WSLDev', 'Elevate to administrator')) {
            return
        }
        Write-DevLog 'Elevating to mount Sandbox drive...' -Level WARN -Source 'Mount' -LogFile $logFile
        $quotedIdentity = $IdentityPath.Replace("'", "''")
        $cmd = "Mount-WSLDev -SkipWait -TriggerSource $TriggerSource -IdentityPath '$quotedIdentity'"
        Invoke-Elevated -Command $cmd -Wait

        # Verify from non-elevated session
        Write-DevLog 'Checking mount status...' -Source 'Mount' -LogFile $logFile
        $status = Invoke-WslProbe -Arguments @('-d', 'Ubuntu', '-e', 'bash', '-c', "mountpoint -q /mnt/sandbox && echo YOURMOUNT_YES || echo YOURMOUNT_NO")
        if ((ConvertFrom-WslProbeState -Output $status.Output -AllowedStates @('YOURMOUNT_YES', 'YOURMOUNT_NO') -ExitCode $status.ExitCode) -ceq 'YOURMOUNT_YES') {
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

    $approved = Get-ApprovedDriveIdentity -IdentityPath $IdentityPath
    Assert-SandboxLinuxIdentity -Identity $approved.Identity
    $devDisk = $approved.Disk
    $driveNumber = $devDisk.Number

    # --- Check if already mounted ---
    $mountCheck = Invoke-WslProbe -Arguments @('-d', 'Ubuntu', '-e', 'bash', '-c', 'mountpoint -q /mnt/sandbox && echo YOURMOUNT_YES || echo YOURMOUNT_NO')
    $mountState = ConvertFrom-WslProbeState -Output $mountCheck.Output -AllowedStates @('YOURMOUNT_YES', 'YOURMOUNT_NO') -ExitCode $mountCheck.ExitCode
    if ($mountState -ceq 'YOURMOUNT_YES') {
        & wsl.exe -d Ubuntu -e sudo /usr/local/bin/mount-sandbox-drive.sh --mount-only
        if ($LASTEXITCODE -ne 0) { throw 'Existing Sandbox mount did not pass the privileged identity/marker check.' }
        Write-DevLog 'Sandbox drive already mounted with approved identity at /mnt/sandbox' -Source 'Mount' -LogFile $logFile
        return
    }

    # --- Handle WSL not ready ---
    if ($null -eq $mountState) {
        Write-DevLog "WSL not ready: $mountCheck" -Level WARN -Source 'Mount' -LogFile $logFile
        Write-DevLog 'Waiting for WSL to become available...' -Source 'Mount' -LogFile $logFile
        $wslReady = $false
        for ($i = 1; $i -le 5; $i++) {
            Start-Sleep -Seconds 5
            $check = Invoke-WslProbe -Arguments @('-d', 'Ubuntu', '-e', 'echo', 'READY') -TimeoutSeconds 1
            if ((ConvertFrom-WslProbeState -Output $check.Output -AllowedStates @('READY') -ExitCode $check.ExitCode) -ceq 'READY') {
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

    Write-DevLog "Found Sandbox drive at PHYSICALDRIVE$driveNumber (Status: $($devDisk.OperationalStatus))" -Source 'Mount' -LogFile $logFile

    if (-not $PSCmdlet.ShouldProcess("PHYSICALDRIVE$driveNumber", 'Attach and mount to WSL')) {
        return
    }

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
        }
    }

    if (-not $attached) {
        Write-DevLog "Failed to attach Sandbox drive after $maxRetries attempts" -Level ERROR -Source 'Mount' -LogFile $logFile
        $err = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new("Failed to attach PHYSICALDRIVE$driveNumber after $maxRetries attempts"),
            'AttachFailed', [System.Management.Automation.ErrorCategory]::ResourceUnavailable, $null)
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
    $verify = Invoke-WslProbe -Arguments @('-d', 'Ubuntu', '-e', 'bash', '-c', 'mountpoint -q /mnt/sandbox && echo SUCCESS || echo FAILED')
    if ((ConvertFrom-WslProbeState -Output $verify.Output -AllowedStates @('SUCCESS', 'FAILED') -ExitCode $verify.ExitCode) -ceq 'SUCCESS') {
        Write-DevLog 'WSL Sandbox drive mounted successfully at /mnt/sandbox' -Source 'Mount' -LogFile $logFile
    } else {
        Write-DevLog 'Mount verification failed' -Level ERROR -Source 'Mount' -LogFile $logFile
        $err = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('Mount verification failed. /mnt/sandbox not mounted'),
            'VerifyFailed', [System.Management.Automation.ErrorCategory]::InvalidResult, $null)
        $PSCmdlet.ThrowTerminatingError($err)
    }
}

#Requires -Version 7.0
#Requires -PSEdition Core

function Get-Secret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [string]$Distribution = 'Ubuntu',

        [switch]$AsPlainText,

        [switch]$AsSecureString
    )

    if (-not $AsPlainText -and -not $AsSecureString) {
        $err = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new(
                'Specify -AsPlainText or -AsSecureString. Plaintext secrets may be logged or captured.'),
            'OutputModeRequired',
            [System.Management.Automation.ErrorCategory]::InvalidArgument,
            $null)
        $PSCmdlet.ThrowTerminatingError($err)
    }

    # Defence in depth: a vault entry name is a store-relative path, so a
    # newline or other control character is never legitimate and could only
    # come from a malformed or hostile caller. Reject it up front with a clear
    # error. The out-of-band env-var hand-off below already makes any value
    # non-injectable; this just fails fast rather than querying an impossible
    # key. Single quotes / semicolons / backticks are intentionally allowed
    # through (they are inert via the env-var hand-off) so legitimate exotic
    # entry names are not blocked.
    if ([string]::IsNullOrWhiteSpace($Path) -or
        $Path.IndexOfAny([char[]]@("`0", "`r", "`n")) -ge 0) {
        $err = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('Invalid secret path: must be a non-empty, single-line value.'),
            'InvalidPath', [System.Management.Automation.ErrorCategory]::InvalidArgument, $Path)
        $PSCmdlet.ThrowTerminatingError($err)
    }

    # Code artifacts do not select credential storage. The existing native
    # revvault client selects its configured store. Pass only the opaque key.
    $previous = @{
        RV_PATH  = $env:RV_PATH
        WSLENV   = $env:WSLENV
    }
    try {
        $env:RV_PATH = $Path
        # Forward the opaque entry name without Windows path translation.
        $forward = 'RV_PATH'
        $env:WSLENV = if ([string]::IsNullOrEmpty($previous.WSLENV)) {
            $forward
        } else {
            "$($previous.WSLENV):$forward"
        }

        $raw = wsl.exe -d $Distribution -- bash -lc 'revvault get --json "$RV_PATH"' 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        # Restore the prior process environment exactly: remove vars that were
        # unset before, otherwise set them back to their previous value.
        foreach ($name in 'RV_PATH', 'WSLENV') {
            $prev = $previous[$name]
            if ($null -eq $prev) {
                Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            } else {
                Set-Item "Env:$name" -Value $prev
            }
        }
    }

    try {
        $secret = ConvertFrom-RevvaultJson (($raw -join "`n").Trim())
    } catch {
        $err = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new("revvault get failed for '$Path' (exit $exitCode): $($_.Exception.Message)"),
            'RevvaultFailed', [System.Management.Automation.ErrorCategory]::InvalidResult, $Path)
        $PSCmdlet.ThrowTerminatingError($err)
    }

    if ($AsSecureString) {
        return ($secret | ConvertTo-SecureString -AsPlainText -Force)
    }

    return $secret
}

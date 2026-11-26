#Requires -Version 7.0

function Invoke-WslProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateRange(0.05, 30)][double]$TimeoutSeconds = 30,
        [string]$Executable = (Get-Command wsl.exe -ErrorAction Stop).Source
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit([int][Math]::Ceiling($TimeoutSeconds * 1000))) {
            $process.Kill($true)
            $process.WaitForExit()
            return [pscustomobject]@{ Output = @(); ExitCode = 124; TimedOut = $true }
        }
        $text = $stdout.GetAwaiter().GetResult()
        $null = $stderr.GetAwaiter().GetResult()
        $reader = [IO.StringReader]::new($text)
        $lines = [Collections.Generic.List[string]]::new()
        try {
            while ($null -ne ($line = $reader.ReadLine())) { $lines.Add($line) }
        } finally { $reader.Dispose() }
        [pscustomobject]@{ Output = $lines.ToArray(); ExitCode = $process.ExitCode; TimedOut = $false }
    } finally { $process.Dispose() }
}

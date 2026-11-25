#Requires -Version 7.0
[CmdletBinding()]
param([string]$RequestPath, [string]$ExpectedRequestSha256)

# Keep the source home out of this runner's command line: the offline writer
# census deliberately treats source-referencing processes as possible writers.
$script:CodexOfflineScriptDirectory = $PSScriptRoot
$script:CodexOfflineRequiredFiles = @(
    'Invoke-CodexOfflineCopy.ps1', 'codex-home-migrate.py', 'codex_adapter_lib.py',
    'codex-state-layout-v1.json', 'codex-desktop-layout-v1.json',
    'lib/WindowsArtifactDeployment.ps1'
)

function Assert-CodexOfflineDigest {
    param([string]$Value)
    if ($Value.Length -ne 64) { throw 'Expected a SHA-256 digest.' }
    foreach ($letter in $Value.ToLowerInvariant().ToCharArray()) {
        if ('0123456789abcdef'.IndexOf($letter) -lt 0) { throw 'Expected a SHA-256 digest.' }
    }
}

function Get-CodexOfflineRegularPath {
    param([Parameter(Mandatory)][string]$Path, [switch]$Directory, [switch]$Absent)
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or $Path.StartsWith('\\')) {
        throw 'Offline copy requires fully qualified local filesystem paths.'
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $exists = Test-Path -LiteralPath $full
    if ($Absent -and $exists) { throw 'Offline destination already exists; preserve it for review.' }
    if (-not $Absent -and -not $exists) { throw 'Required offline path is missing.' }
    if ($exists) {
        $entry = Get-Item -LiteralPath $full -Force
        if ($Directory.IsPresent -ne $entry.PSIsContainer) { throw 'Unexpected offline path type.' }
    }
    $ancestor = $full
    while (-not [string]::IsNullOrEmpty($ancestor)) {
        if (Test-Path -LiteralPath $ancestor) {
            if (((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Offline paths and ancestors cannot be links.'
            }
        }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    if (-not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($full)) -PathType Container)) {
        throw 'Offline destination parent must exist.'
    }
    return $full
}

function Test-CodexOfflineOverlap {
    param([string]$First, [string]$Second)
    $separator = [IO.Path]::DirectorySeparatorChar
    return $First.Equals($Second, [StringComparison]::OrdinalIgnoreCase) -or
        $First.StartsWith($Second + $separator, [StringComparison]::OrdinalIgnoreCase) -or
        $Second.StartsWith($First + $separator, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-CodexOfflinePinnedFiles {
    param([System.Collections.IDictionary]$Request)
    foreach ($relative in $script:CodexOfflineRequiredFiles) {
        $expected = $Request.adapterHashes[$relative]
        Assert-CodexOfflineDigest $expected
        $file = Get-CodexOfflineRegularPath (Join-Path $Request.adapterDirectory $relative)
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ine $expected) {
            throw "Pinned offline adapter changed: $relative"
        }
    }
    if ((Get-FileHash -LiteralPath $Request.pythonPath -Algorithm SHA256).Hash -ine $Request.pythonSha256) {
        throw 'Pinned Python executable changed.'
    }
}

function Get-CodexOfflineRequest {
    param([string]$Path, [string]$ExpectedSha256)
    if (-not $IsWindows) { throw 'This offline executor requires Windows.' }
    Assert-CodexOfflineDigest $ExpectedSha256
    $requestFile = Get-CodexOfflineRegularPath $Path
    $requestBytes = [IO.File]::ReadAllBytes($requestFile)
    $requestHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($requestBytes))
    if ($requestHash -ine $ExpectedSha256) {
        throw 'Offline request digest differs from the reviewed request.'
    }
    $requestText = [Text.UTF8Encoding]::new($false, $true).GetString($requestBytes).TrimStart([char]0xFEFF)
    $request = $requestText | ConvertFrom-Json -AsHashtable
    $fields = @('schemaVersion','sourceHome','targetHome','adapterDirectory','adapterHashes',
        'pythonPath','pythonSha256','receiptDirectory','waitTimeoutSeconds','pollSeconds')
    if ($request -isnot [System.Collections.IDictionary] -or $request.Count -ne $fields.Count) {
        throw 'Unsupported offline request shape.'
    }
    foreach ($key in $fields) { if (-not $request.Contains($key)) { throw "Missing request field: $key" } }
    if ($request.schemaVersion -ne 1 -or $request.adapterHashes -isnot [System.Collections.IDictionary] -or
        $request.adapterHashes.Count -ne $script:CodexOfflineRequiredFiles.Count) { throw 'Unsupported request version or pins.' }
    foreach ($key in $script:CodexOfflineRequiredFiles) {
        if (-not $request.adapterHashes.Contains($key)) { throw "Missing adapter pin: $key" }
    }
    foreach ($key in @('waitTimeoutSeconds','pollSeconds')) {
        if ($request[$key] -isnot [long] -and $request[$key] -isnot [int]) { throw 'Wait bounds must be integers.' }
    }
    if ($request.waitTimeoutSeconds -lt 1 -or $request.waitTimeoutSeconds -gt 3600 -or
        $request.pollSeconds -lt 1 -or $request.pollSeconds -gt 30 -or
        $request.pollSeconds -gt $request.waitTimeoutSeconds) { throw 'Offline wait bounds are invalid.' }
    foreach ($key in @('sourceHome','adapterDirectory')) {
        $request[$key] = Get-CodexOfflineRegularPath $request[$key] -Directory
    }
    foreach ($key in @('targetHome','receiptDirectory')) {
        $request[$key] = Get-CodexOfflineRegularPath $request[$key] -Directory -Absent
    }
    $request.pythonPath = Get-CodexOfflineRegularPath $request.pythonPath
    Assert-CodexOfflineDigest $request.pythonSha256
    if (-not $request.adapterDirectory.Equals($script:CodexOfflineScriptDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Request must pin this executor and its sibling maintained adapter.'
    }
    $roots = @($request.sourceHome,$request.targetHome,$request.receiptDirectory,$request.adapterDirectory)
    for ($i=0; $i -lt $roots.Count; $i++) {
        for ($j=$i+1; $j -lt $roots.Count; $j++) {
            if (Test-CodexOfflineOverlap $roots[$i] $roots[$j]) { throw 'Offline roots overlap.' }
        }
    }
    foreach ($root in @($request.sourceHome,$request.targetHome,$request.receiptDirectory)) {
        if (Test-CodexOfflineOverlap $root $requestFile) { throw 'Request must be outside homes and new receipts.' }
    }
    Assert-CodexOfflinePinnedFiles $request
    return $request
}

function Write-CodexOfflineReceipt {
    param([string]$Directory, [string]$Name, [object]$Value)
    $temporary = Join-Path $Directory ([Guid]::NewGuid().ToString('N') + '.tmp')
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, (Join-Path $Directory $Name), $true)
}

function Test-CodexOfflineWriters {
    param([string]$SourceHome)
    $writers = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        $_.Name -in @('ChatGPT.exe','Codex.exe','codex.exe','codex-browser-client.exe','codex-browser-service.exe') -or
        ($_.ProcessId -ne $PID -and $_.CommandLine -and
         $_.CommandLine.IndexOf($SourceHome, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    })
    return $writers.Count -gt 0
}

function Wait-CodexOfflineQuit {
    param([System.Collections.IDictionary]$Request)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (Test-CodexOfflineWriters $Request.sourceHome) {
        if ($watch.Elapsed.TotalSeconds -ge $Request.waitTimeoutSeconds) {
            throw 'Timed out waiting for normal application Quit; no processes were stopped.'
        }
        Start-Sleep -Seconds $Request.pollSeconds
    }
}

function Invoke-CodexOfflineAdapter {
    param([System.Collections.IDictionary]$Request, [ValidateSet('plan','prepare','verify')][string]$Action)
    Assert-CodexOfflinePinnedFiles $Request
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Request.pythonPath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-E','-s','-B',(Join-Path $Request.adapterDirectory 'codex-home-migrate.py'),$Action,'--target',$Request.targetHome)) {
        $start.ArgumentList.Add($argument)
    }
    if ($Action -ne 'verify') { $start.ArgumentList.Add('--source'); $start.ArgumentList.Add($Request.sourceHome) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Offline adapter did not start.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $Request.receiptDirectory ($Action + '.stdout.json')), $output, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $Request.receiptDirectory ($Action + '.stderr.log')), $errorText, [Text.UTF8Encoding]::new($false))
        $result = $output | ConvertFrom-Json -AsHashtable
        $expectedStatus = @{plan='planned';prepare='prepared';verify='verified'}[$Action]
        if ($result -isnot [System.Collections.IDictionary] -or -not $result.Contains('pending') -or
            $result.pending -isnot [System.Collections.IList] -or
            $process.ExitCode -notin @(0,2) -or $result.status -cne $expectedStatus -or
            $result.ready_for_activation -ne $false -or $result.source_unchanged -ne $true -or
            ($Action -ne 'plan' -and $result.storage_copy_verified -ne $true) -or
            ($process.ExitCode -eq 2 -and $result.pending.Count -eq 0) -or
            ($process.ExitCode -eq 0 -and $result.pending.Count -gt 0)) {
            throw "Offline adapter $Action refused or returned an inconsistent result; inspect retained receipts."
        }
        return $result
    } finally { $process.Dispose() }
}

function Invoke-CodexOfflineCopy {
    param([string]$Path, [string]$ExpectedSha256)
    $request = Get-CodexOfflineRequest $Path $ExpectedSha256
    . (Join-Path $request.adapterDirectory 'lib/WindowsArtifactDeployment.ps1')
    Set-RevkitPrivateDirectory $request.receiptDirectory
    $state = [ordered]@{schemaVersion=1;status='waiting-for-normal-quit';observedAt=(Get-Date).ToString('o');
        sourceHome=$request.sourceHome;targetHome=$request.targetHome;requestSha256=$ExpectedSha256;
        adapterHashes=$request.adapterHashes;pythonSha256=$request.pythonSha256;
        storageCopyVerified=$false;activationPerformed=$false;environmentChanged=$false;
        processesStopped=$false;originalsRetained=$true;uiProfileCopied=$false}
    Write-CodexOfflineReceipt $request.receiptDirectory 'executor.json' $state
    try {
        Wait-CodexOfflineQuit $request
        foreach ($action in @('plan','prepare','verify')) {
            $state.status = $action
            $state.observedAt = (Get-Date).ToString('o')
            Write-CodexOfflineReceipt $request.receiptDirectory 'executor.json' $state
            $result = Invoke-CodexOfflineAdapter $request $action
            Write-CodexOfflineReceipt $request.receiptDirectory ($action + '.json') $result
        }
        $state.status = 'copy-verified-awaiting-operator-review'
        $state.storageCopyVerified = $true
        $state.pending = $result.pending
        $state.observedAt = (Get-Date).ToString('o')
        Write-CodexOfflineReceipt $request.receiptDirectory 'executor.json' $state
        return $state
    } catch {
        $state.status = 'stopped-for-review'
        $state.reason = $_.Exception.Message
        $state.observedAt = (Get-Date).ToString('o')
        Write-CodexOfflineReceipt $request.receiptDirectory 'executor.json' $state
        throw
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $ErrorActionPreference = 'Stop'
        Invoke-CodexOfflineCopy $RequestPath $ExpectedRequestSha256 | ConvertTo-Json -Depth 40
    } catch { Write-Error -Message $_.Exception.Message -ErrorAction Continue; exit 1 }
}

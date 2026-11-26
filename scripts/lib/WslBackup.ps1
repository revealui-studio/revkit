#Requires -Version 7.0

function Get-WslBackupCapacityPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][long]$SourceBytes,
        [Parameter(Mandatory)][long]$AvailableBytes,
        [long]$ReserveBytes = 1GB
    )
    if ($SourceBytes -le 0 -or $AvailableBytes -lt 0 -or $ReserveBytes -lt 0) {
        throw 'Source size and available capacity must be known and nonnegative.'
    }
    $required = [decimal]$SourceBytes + [decimal]$ReserveBytes
    [pscustomobject]@{
        SourceBytes = $SourceBytes
        AvailableBytes = $AvailableBytes
        RequiredBytes = $required
        ReserveBytes = $ReserveBytes
        CanExport = ([decimal]$AvailableBytes -ge $required)
        ReclaimBeforeExportBytes = 0L
        Reason = if ([decimal]$AvailableBytes -ge $required) { 'New full image fits without deleting existing recovery.' } else { 'Insufficient independent staging capacity; existing recovery must remain intact.' }
    }
}

function Assert-WslBackupHash {
    param([Parameter(Mandatory)][string]$Value)
    if ($Value.Length -ne 64) { throw 'Expected a SHA256 digest.' }
    foreach ($character in $Value.ToLowerInvariant().ToCharArray()) {
        if (-not '0123456789abcdef'.Contains([string]$character)) { throw 'Invalid SHA256 digest.' }
    }
}

function Assert-WslBackupLeaf {
    param([Parameter(Mandatory)][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Contains('/') -or $Name.Contains('\') -or
        $Name.Contains(':') -or $Name -in @('.', '..')) { throw 'Expected a literal artifact filename.' }
}

function Assert-WslRestoreEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Evidence,
        [Parameter(Mandatory)][string]$Sha256,
        [Parameter(Mandatory)][long]$Bytes,
        [Parameter(Mandatory)][string]$Distro
    )
    Assert-WslBackupHash $Sha256
    if ($Evidence.schemaVersion -ne 1 -or $Evidence.kind -cne 'revealfleet-wsl-restore-validation' -or
        $Evidence.artifactSha256 -ine $Sha256 -or $Evidence.artifactBytes -ne $Bytes -or
        $Evidence.sourceDistro -cne $Distro -or [string]::IsNullOrWhiteSpace($Evidence.recoveryDistro) -or
        $Evidence.recoveryDistro -ceq $Distro -or ($Evidence.artifactPreserved -isnot [bool] -or $Evidence.artifactPreserved -ne $true)) {
        throw 'Restore evidence is not bound to this preserved artifact and a separate recovery registration.'
    }
    if ($Evidence.verifierProtocol -cne 'revealfleet-isolated-restore-probe-v1' -or
        $Evidence.probe.protocol -cne 'revealfleet-isolated-restore-probe-v1' -or
        $Evidence.probe.rootFilesystem -cne 'ext4' -or $Evidence.probe.uid -le 0 -or
        $Evidence.probe.homeExists -isnot [bool] -or -not $Evidence.probe.homeExists -or
        $Evidence.probe.repositoryExists -isnot [bool] -or -not $Evidence.probe.repositoryExists -or
        $null -eq $Evidence.probe.unexpectedProcesses -or @($Evidence.probe.unexpectedProcesses).Count -ne 0 -or
        -not ($Evidence.probe.pid1Comm -ceq 'init' -or $Evidence.probe.pid1Comm.StartsWith('init('))) {
        throw 'Restore verification requires observations from the maintained isolated recovery probe.'
    }
    Assert-WslBackupHash $Evidence.verifierSourceSha256
    $verifiedAt = [DateTimeOffset]::Parse($Evidence.verifiedAt)
    if ($verifiedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) { throw 'Restore evidence is dated in the future.' }
    foreach ($check in @('registration', 'filesystem', 'boot', 'identity', 'servicesIsolated')) {
        if ($Evidence.checks.$check -isnot [bool] -or $Evidence.checks.$check -ne $true) { throw "Restore verification did not pass: $check" }
    }
    return $verifiedAt
}

function Read-WslBackupJson {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Backup metadata must be a regular local file.'
    }
    if ($item.Length -gt 1MB) { throw 'Backup metadata exceeds its supported size.' }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
}

function Write-WslBackupJsonNew {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 12) + "`n")
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}

function Get-WslBackupArtifact {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -le 0 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Backup artifact must be a nonempty regular file.'
    }
    return $item
}

function Confirm-WslBackupArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArtifactPath,
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$RestoreEvidencePath
    )
    $item = Get-WslBackupArtifact $ArtifactPath
    $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $evidence = Read-WslBackupJson $RestoreEvidencePath
    $verifiedAt = Assert-WslRestoreEvidence -Evidence $evidence -Sha256 $hash -Bytes $item.Length -Distro $Distro
    $proofPath = $item.FullName + '.restore.json'
    $receiptPath = $item.FullName + '.verified.json'
    if ((Test-Path -LiteralPath $proofPath) -or (Test-Path -LiteralPath $receiptPath)) {
        throw 'Verification metadata already exists; refusing to overwrite evidence.'
    }
    Write-WslBackupJsonNew -Path $proofPath -Value $evidence
    $proofHash = (Get-FileHash -LiteralPath $proofPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $after = Get-WslBackupArtifact $item.FullName
    if ($after.Length -ne $item.Length -or $after.LastWriteTimeUtc.Ticks -ne $item.LastWriteTimeUtc.Ticks) {
        throw 'Artifact changed during verification; no verified receipt was written.'
    }
    $receipt = [ordered]@{
        schemaVersion = 1
        kind = 'revealfleet-wsl-verified-artifact'
        artifactFile = $item.Name
        artifactBytes = $item.Length
        artifactLastWriteUtcTicks = $item.LastWriteTimeUtc.Ticks
        artifactSha256 = $hash
        distro = $Distro
        verifiedAt = $verifiedAt.ToUniversalTime().ToString('o')
        restoreEvidenceFile = [IO.Path]::GetFileName($proofPath)
        restoreEvidenceSha256 = $proofHash
    }
    Write-WslBackupJsonNew -Path $receiptPath -Value $receipt
    return Get-WslVerifiedBackup -ReceiptPath $receiptPath
}

function Get-WslVerifiedBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ReceiptPath, [switch]$VerifyContent)
    $receipt = Read-WslBackupJson $ReceiptPath
    if ($receipt.schemaVersion -ne 1 -or $receipt.kind -cne 'revealfleet-wsl-verified-artifact') {
        throw 'Unsupported backup verification receipt.'
    }
    Assert-WslBackupLeaf $receipt.artifactFile
    Assert-WslBackupLeaf $receipt.restoreEvidenceFile
    Assert-WslBackupHash $receipt.artifactSha256
    Assert-WslBackupHash $receipt.restoreEvidenceSha256
    $directory = [IO.Path]::GetDirectoryName((Get-Item -LiteralPath $ReceiptPath).FullName)
    $artifact = Get-WslBackupArtifact (Join-Path $directory $receipt.artifactFile)
    if ($artifact.FullName + '.verified.json' -cne (Get-Item -LiteralPath $ReceiptPath).FullName -or
        $receipt.restoreEvidenceFile -cne ($artifact.Name + '.restore.json') -or
        $artifact.Length -ne $receipt.artifactBytes -or
        $artifact.LastWriteTimeUtc.Ticks -ne $receipt.artifactLastWriteUtcTicks) {
        throw 'Artifact identity or metadata no longer matches its verification receipt.'
    }
    $proofPath = Join-Path $directory $receipt.restoreEvidenceFile
    $proof = Read-WslBackupJson $proofPath
    $proofHash = (Get-FileHash -LiteralPath $proofPath -Algorithm SHA256).Hash
    if ($proofHash -ine $receipt.restoreEvidenceSha256) { throw 'Restore evidence checksum differs from the verification receipt.' }
    $verifiedAt = Assert-WslRestoreEvidence -Evidence $proof -Sha256 $receipt.artifactSha256 -Bytes $artifact.Length -Distro $receipt.distro
    if ($verifiedAt -ne [DateTimeOffset]::Parse($receipt.verifiedAt)) { throw 'Restore verification dates disagree.' }
    if ($VerifyContent -and (Get-FileHash -LiteralPath $artifact.FullName -Algorithm SHA256).Hash -ine $receipt.artifactSha256) {
        throw 'Artifact checksum differs from the verified recovery.'
    }
    [pscustomobject]@{
        ArtifactPath = $artifact.FullName
        ReceiptPath = (Get-Item -LiteralPath $ReceiptPath).FullName
        RestoreEvidencePath = $proofPath
        Distro = $receipt.distro
        Bytes = $artifact.Length
        Sha256 = $receipt.artifactSha256
        VerifiedAt = $verifiedAt
        ContentRehashed = [bool]$VerifyContent
    }
}

function Get-WslVerifiedBackups {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Distro, [switch]$VerifyContent)
    foreach ($file in Get-ChildItem -LiteralPath $Directory -File -Filter '*.verified.json' -ErrorAction Stop) {
        try {
            $backup = Get-WslVerifiedBackup -ReceiptPath $file.FullName -VerifyContent:$VerifyContent
            if ($backup.Distro -ceq $Distro) { $backup }
        } catch {
            Write-Warning "Ignoring unverified backup receipt '$($file.Name)': $($_.Exception.Message)"
        }
    }
}

function Get-WslBackupRetentionPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$VerifiedBackups,
        [Parameter(Mandatory)][string]$NewVerifiedArtifact,
        [ValidateRange(1, 1000)][int]$KeepCount = 1
    )
    $new = @($VerifiedBackups | Where-Object { $_.ArtifactPath -ceq $NewVerifiedArtifact })
    if ($new.Count -ne 1) { throw 'Retention requires exactly one newly verified artifact.' }
    $ordered = @($VerifiedBackups | Sort-Object VerifiedAt -Descending)
    if ($ordered[0].ArtifactPath -cne $NewVerifiedArtifact) { throw 'New verification must be the newest recovery before retention.' }
    @($ordered | Select-Object -Skip $KeepCount)
}

function Get-WslRegisteredVhdx {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Distro)
    $matches = @(Get-ChildItem -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' | ForEach-Object {
        $entry = Get-ItemProperty -LiteralPath $_.PSPath
        if ($entry.DistributionName -ceq $Distro) { $entry }
    })
    if ($matches.Count -ne 1) { throw 'Expected exactly one registered source distribution.' }
    $vhdxName = if ($matches[0].PSObject.Properties['VhdFileName']) { $matches[0].VhdFileName } else { 'ext4.vhdx' }
    Assert-WslBackupLeaf $vhdxName
    return (Join-Path $matches[0].BasePath $vhdxName)
}

function Invoke-WslBackupExport {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Distro, [Parameter(Mandatory)][string]$Target)
    & wsl.exe --export $Distro $Target --vhd
    if ($LASTEXITCODE -ne 0) { throw "WSL export failed with exit code $LASTEXITCODE; partial artifact retained." }
}

function Invoke-WslColdBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Distro,
        [Parameter(Mandatory)][string]$SourceVhdx,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][long]$AvailableBytes,
        [long]$ReserveBytes = 1GB,
        [switch]$Execute
    )
    $source = Get-WslBackupArtifact $SourceVhdx
    $plan = Get-WslBackupCapacityPlan -SourceBytes $source.Length -AvailableBytes $AvailableBytes -ReserveBytes $ReserveBytes
    if (-not $plan.CanExport) { throw $plan.Reason }
    if (-not $Execute) { return $plan }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { throw 'Backup directory must already exist with private permissions.' }
    $stamp = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-dd-HHmmss')
    $target = Join-Path $Directory ($Distro + '-' + $stamp + '-' + [Guid]::NewGuid().ToString('N') + '.partial.vhdx')
    Invoke-WslBackupExport -Distro $Distro -Target $target
    $artifact = Get-WslBackupArtifact $target
    $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    $final = $target.Substring(0, $target.Length - '.partial.vhdx'.Length) + '.vhdx'
    Move-Item -LiteralPath $target -Destination $final -ErrorAction Stop
    Write-WslBackupJsonNew -Path ($final + '.pending.json') -Value ([ordered]@{
        schemaVersion = 1
        kind = 'revealfleet-wsl-export-awaiting-restore'
        distro = $Distro
        artifactFile = [IO.Path]::GetFileName($final)
        artifactBytes = $artifact.Length
        artifactSha256 = $hash
        exportedAt = [DateTimeOffset]::UtcNow.ToString('o')
        verified = $false
    })
    [pscustomobject]@{ ArtifactPath = $final; Sha256 = $hash; Bytes = $artifact.Length; Verified = $false; RetentionApplied = $false }
}

function Set-WslBackupAwake {
    if (-not ('revealfleet.BackupPower' -as [type])) {
        Add-Type -Namespace revealfleet -Name BackupPower -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
    }
    if ([revealfleet.BackupPower]::SetThreadExecutionState([uint32]0x80000001L) -eq 0) {
        throw 'The Windows power request failed; refusing an export vulnerable to host sleep.'
    }
}

function Clear-WslBackupAwake {
    if ('revealfleet.BackupPower' -as [type]) {
        [void][revealfleet.BackupPower]::SetThreadExecutionState([uint32]0x80000000L)
    }
}

# Borg admission is a data/evidence contract only. It never launches a backend,
# mounts a source, initializes keys/repositories, or promotes a verified backup.
function Assert-WslRecoveryFields {
    param($Value, [string[]]$Fields, [string]$Label)
    if ($Value -isnot [Collections.IDictionary]) { throw "Expected an object: $Label" }
    $actual = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $Value.Keys) { [void]$actual.Add([string]$name) }
    if (-not $actual.SetEquals($Fields)) { throw "Unexpected or missing fields: $Label" }
}

function Assert-WslRecoveryInteger {
    param($Value, [long]$Minimum = 0)
    if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt $Minimum) {
        throw 'Expected a bounded nonnegative integer, not a coerced string or boolean.'
    }
}

function Read-WslRecoveryDocument {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -gt 1MB -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Recovery contract must be a bounded regular JSON file.'
    }
    $bytes = [IO.File]::ReadAllBytes($item.FullName)
    if ($bytes.Length -gt 1MB) { throw 'Recovery contract exceeds its supported size.' }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $document = [Text.Json.JsonDocument]::Parse($text)
    function Assert-UniqueRecoveryKeys($Element, [int]$Depth = 0) {
        if ($Depth -gt 24) { throw 'Recovery contract nesting exceeds its limit.' }
        if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($property in $Element.EnumerateObject()) {
                if (-not $names.Add($property.Name)) { throw 'Duplicate recovery contract field.' }
                Assert-UniqueRecoveryKeys $property.Value ($Depth + 1)
            }
        } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
            foreach ($entry in $Element.EnumerateArray()) { Assert-UniqueRecoveryKeys $entry ($Depth + 1) }
        }
    }
    try { Assert-UniqueRecoveryKeys $document.RootElement } finally { $document.Dispose() }
    [pscustomobject]@{
        Value = ($text | ConvertFrom-Json -AsHashtable -Depth 24 -ErrorAction Stop)
        Sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    }
}

function Get-WslRecoveryPathKey {
    param([Parameter(Mandatory)][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.IndexOfAny([char[]]@(0, 10, 13)) -ge 0) {
        throw 'Expected a literal absolute recovery path.'
    }
    $key = $Value.Replace('\', '/').TrimEnd('/')
    $windows = $key.Length -gt 3 -and $key[1] -eq ':' -and $key[2] -eq '/' -and
        'abcdefghijklmnopqrstuvwxyz'.Contains(([string]$key[0]).ToLowerInvariant())
    if ($windows) { $key = $key.ToLowerInvariant(); $parts = $key.Substring(3).Split('/') }
    elseif ($key.StartsWith('/') -and -not $key.StartsWith('//')) { $parts = $key.Substring(1).Split('/') }
    else { throw 'Recovery paths require an absolute local drive or POSIX path.' }
    foreach ($part in $parts) {
        if ($part -in @('', '.', '..') -or $part.Contains(':')) { throw 'Ambiguous recovery path component.' }
    }
    return $key
}

function Assert-WslRecoveryDisjoint {
    param([string[]]$Paths)
    $keys = @($Paths | ForEach-Object { Get-WslRecoveryPathKey $_ })
    for ($i = 0; $i -lt $keys.Count; $i++) {
        for ($j = $i + 1; $j -lt $keys.Count; $j++) {
            if ($keys[$i] -ceq $keys[$j] -or $keys[$i].StartsWith($keys[$j] + '/', [StringComparison]::Ordinal) -or
                $keys[$j].StartsWith($keys[$i] + '/', [StringComparison]::Ordinal)) {
                throw 'Source, repository and protected recovery paths must be disjoint.'
            }
        }
    }
}

function Get-WslBorgCapacityPlan {
    param(
        [Parameter(Mandatory)][long]$LogicalBytes,
        [Parameter(Mandatory)][long]$MetadataUpperBoundBytes,
        [Parameter(Mandatory)][long]$AvailableBytes,
        [long]$ReserveBytes = 64GB
    )
    if ($LogicalBytes -le 0 -or $MetadataUpperBoundBytes -le 0 -or $AvailableBytes -lt 0 -or $ReserveBytes -lt 64GB) {
        throw 'Known logical data/metadata upper bounds and at least 64 GiB reserve are required.'
    }
    $required = [decimal]$LogicalBytes + [decimal]$MetadataUpperBoundBytes + [decimal]$ReserveBytes
    [pscustomobject]@{
        RequiredBytes = $required; AvailableBytes = $AvailableBytes; ReserveBytes = $ReserveBytes
        CanStageArchive = ([decimal]$AvailableBytes -ge $required)
        DeduplicationCreditBytes = 0L; ReclaimOriginalBytes = 0L
        IndependentRestoreAccepted = $false
    }
}

function Get-WslBorgReadinessPlan {
    [CmdletBinding()]
    param([string]$ConfigurationPath, [string]$ObservationPath, [string]$ReviewedConfigurationSha256)
    $blockers = [Collections.Generic.List[string]]::new()
    $result = [ordered]@{
        SchemaVersion = 1; Kind = 'revealfleet-wsl-borg-readiness-v1'; Backend = 'borg-1.4.5'
        InputBindingsValid = $false; CanExecute = $false; BackendExecuted = $false
        FullRestoreAccepted = $false; ConfigurationSha256 = $null; ObservationSha256 = $null
        Capacity = $null; Blockers = @()
        RequiredExecutionGates = @(
            'Reviewed native Borg installation and actual version/metadata round-trip proof',
            'Controller-acquired stopped, clean, read-only source view and held exclusive VHD lease',
            'Approved exact disk/repository identity and independent key recovery drill',
            'Bounded cache/workspace placement and per-filesystem growth accounting',
            'Reviewed executor with held repository lock and complete source inventory',
            'Approved fresh isolated full-restore target, explicit hardware guarantee and restore acceptance'
        )
    }
    if (-not $ConfigurationPath -or -not $ObservationPath -or -not $ReviewedConfigurationSha256) {
        $result.Blockers = @('Explicit configuration, its reviewed SHA256, and fresh operator observation are required.')
        return [pscustomobject]$result
    }
    Assert-WslBackupHash $ReviewedConfigurationSha256
    $configDocument = Read-WslRecoveryDocument $ConfigurationPath
    $observationDocument = Read-WslRecoveryDocument $ObservationPath
    $c = $configDocument.Value; $o = $observationDocument.Value
    $result.ConfigurationSha256 = $configDocument.Sha256; $result.ObservationSha256 = $observationDocument.Sha256
    if ($configDocument.Sha256 -cne $ReviewedConfigurationSha256) { throw 'Configuration differs from the reviewed digest.' }
    Assert-WslRecoveryFields $c @('schemaVersion', 'backend', 'tool', 'source', 'repository', 'keyRecovery', 'original', 'budget') 'configuration'
    Assert-WslRecoveryFields $o @('schemaVersion', 'configurationSha256', 'capturedAt', 'transactionId', 'tool', 'source', 'repository', 'keyRecovery', 'original') 'observation'
    foreach ($value in @($c.schemaVersion, $o.schemaVersion)) { Assert-WslRecoveryInteger $value 1 }
    if ($c.schemaVersion -ne 1 -or $o.schemaVersion -ne 1 -or $c.backend -cne 'borg-1.4.5') { throw 'Unsupported incremental recovery contract.' }
    Assert-WslRecoveryFields $c.tool @('path', 'version', 'sha256', 'provenanceSha256') 'configured tool'
    Assert-WslRecoveryFields $o.tool @('version', 'sha256', 'provenanceSha256') 'observed tool'
    Assert-WslRecoveryFields $c.source @('distro', 'vhdx', 'view', 'filesystemUuid', 'physicalDeviceId', 'inventorySha256') 'configured source'
    Assert-WslRecoveryFields $o.source @('state', 'vhdx', 'view', 'filesystemUuid', 'physicalDeviceId', 'inventorySha256', 'readOnly', 'clean', 'exclusiveLease', 'leaseId', 'inventoryComplete', 'producerExitCode', 'readErrors') 'observed source'
    Assert-WslRecoveryFields $c.repository @('path', 'id', 'physicalDeviceId', 'partitionUuid', 'filesystemUuid', 'identitySha256', 'encryption') 'configured repository'
    Assert-WslRecoveryFields $o.repository @('path', 'id', 'physicalDeviceId', 'partitionUuid', 'filesystemUuid', 'identitySha256', 'encryption', 'private', 'availableBytes') 'observed repository'
    Assert-WslRecoveryFields $c.keyRecovery @('reference', 'drillSha256') 'configured key recovery'
    Assert-WslRecoveryFields $o.keyRecovery @('reference', 'drillSha256', 'sourceUnavailable') 'observed key recovery'
    Assert-WslRecoveryFields $c.original @('path', 'sha256', 'bytes', 'physicalDeviceId') 'configured original'
    Assert-WslRecoveryFields $o.original @('path', 'sha256', 'bytes', 'readOnly') 'observed original'
    Assert-WslRecoveryFields $c.budget @('logicalBytes', 'metadataUpperBoundBytes', 'reserveBytes') 'capacity budget'
    foreach ($value in @($c.tool.path, $c.source.distro, $c.source.filesystemUuid, $c.source.physicalDeviceId,
        $c.repository.physicalDeviceId, $c.repository.partitionUuid, $c.repository.filesystemUuid,
        $c.keyRecovery.reference, $c.original.physicalDeviceId, $o.source.leaseId)) {
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or $value.Trim() -cne $value) { throw 'Required canonical identity or key-recovery reference is absent.' }
    }
    foreach ($value in @($c.tool.sha256, $c.tool.provenanceSha256, $c.source.inventorySha256, $c.repository.id,
        $c.repository.identitySha256, $c.keyRecovery.drillSha256, $c.original.sha256)) { Assert-WslBackupHash $value }
    foreach ($value in @($c.budget.logicalBytes, $c.budget.metadataUpperBoundBytes, $c.budget.reserveBytes,
        $o.repository.availableBytes, $c.original.bytes, $o.original.bytes, $o.source.producerExitCode, $o.source.readErrors)) {
        Assert-WslRecoveryInteger $value
    }
    $transaction = [Guid]::Empty
    if (-not [Guid]::TryParseExact($o.transactionId, 'D', [ref]$transaction)) { throw 'Expected a unique transaction UUID.' }
    Assert-WslBackupLeaf $c.source.distro
    $null = Get-WslRecoveryPathKey $c.tool.path
    Assert-WslRecoveryInteger $c.original.bytes 1
    Assert-WslRecoveryDisjoint @($c.source.vhdx, $c.source.view, $c.repository.path, $c.original.path)
    if ($c.repository.physicalDeviceId -ieq $c.source.physicalDeviceId -or
        $c.repository.physicalDeviceId -ieq $c.original.physicalDeviceId) { throw 'Repository must be on independent approved hardware.' }
    $now = [DateTimeOffset]::UtcNow; $captured = [DateTimeOffset]::Parse($o.capturedAt)
    if ($captured -lt $now.AddMinutes(-5) -or $captured -gt $now.AddSeconds(30)) { $blockers.Add('Operator observation is stale or future-dated.') }
    if ($o.configurationSha256 -cne $configDocument.Sha256) { $blockers.Add('Observation is not bound to this configuration.') }
    if ($c.tool.version -cne '1.4.5' -or $o.tool.version -cne $c.tool.version -or
        $o.tool.sha256 -cne $c.tool.sha256 -or $o.tool.provenanceSha256 -cne $c.tool.provenanceSha256) {
        $blockers.Add('Pinned Borg tool version, executable or provenance differs.')
    }
    foreach ($field in @('vhdx', 'view', 'filesystemUuid', 'physicalDeviceId', 'inventorySha256')) {
        if ($o.source[$field] -cne $c.source[$field]) { $blockers.Add("Source binding differs: $field") }
    }
    foreach ($field in @('path', 'id', 'physicalDeviceId', 'partitionUuid', 'filesystemUuid', 'identitySha256', 'encryption')) {
        if ($o.repository[$field] -cne $c.repository[$field]) { $blockers.Add("Repository binding differs: $field") }
    }
    if ($c.repository.encryption -cne 'repokey-blake2') { $blockers.Add('Reviewed encrypted repository profile is required.') }
    foreach ($field in @('readOnly', 'clean', 'exclusiveLease', 'inventoryComplete')) {
        if ($o.source[$field] -isnot [bool] -or -not $o.source[$field]) { $blockers.Add("Offline source proof missing: $field") }
    }
    if ($o.source.state -cne 'Stopped' -or $o.source.producerExitCode -ne 0 -or $o.source.readErrors -ne 0) {
        $blockers.Add('Source is active, incomplete, unreadable or its producer failed.')
    }
    if ($o.repository.private -isnot [bool] -or -not $o.repository.private) { $blockers.Add('Private destination approval is absent.') }
    if ($o.keyRecovery.reference -cne $c.keyRecovery.reference -or $o.keyRecovery.drillSha256 -cne $c.keyRecovery.drillSha256 -or
        $o.keyRecovery.sourceUnavailable -isnot [bool] -or -not $o.keyRecovery.sourceUnavailable) {
        $blockers.Add('Independent escrow recovery with source unavailable is unproved.')
    }
    if ($o.original.path -cne $c.original.path -or $o.original.sha256 -cne $c.original.sha256 -or
        $o.original.bytes -ne $c.original.bytes -or $o.original.readOnly -isnot [bool] -or -not $o.original.readOnly) {
        $blockers.Add('Protected last-good original differs or is writable.')
    }
    $result.Capacity = Get-WslBorgCapacityPlan -LogicalBytes $c.budget.logicalBytes -MetadataUpperBoundBytes $c.budget.metadataUpperBoundBytes -AvailableBytes $o.repository.availableBytes -ReserveBytes $c.budget.reserveBytes
    if (-not $result.Capacity.CanStageArchive) { $blockers.Add('Insufficient capacity without reclaiming originals or assuming deduplication.') }
    $result.TransactionId = $o.transactionId
    $result.InputBindingsValid = ($blockers.Count -eq 0); $result.Blockers = @($blockers.ToArray())
    return [pscustomobject]$result
}

function Assert-WslBorgArchiveEvidence {
    param($Evidence, $Plan, $Configuration, $Observation)
    Assert-WslRecoveryFields $Evidence @('schemaVersion', 'kind', 'configurationSha256', 'observationSha256',
        'transactionId', 'repositoryId', 'archiveId', 'sourceInventoryBefore', 'sourceInventoryAfter',
        'originalSha256Before', 'originalSha256After', 'sourceLeaseId', 'sourceLeaseHeldThroughout',
        'repositoryLockHeldThroughout', 'steps') 'archive attempt'
    Assert-WslRecoveryInteger $Evidence.schemaVersion 1
    if ($Evidence.schemaVersion -ne 1 -or $Evidence.kind -cne 'revealfleet-wsl-borg-attempt-v1' -or
        $Evidence.configurationSha256 -cne $Plan.ConfigurationSha256 -or
        $Evidence.observationSha256 -cne $Plan.ObservationSha256 -or
        $Evidence.transactionId -cne $Plan.TransactionId -or $Evidence.repositoryId -cne $Configuration.repository.id) {
        throw 'Archive attempt is not bound to this configuration, observation and transaction.'
    }
    Assert-WslBackupHash $Evidence.archiveId
    if ($Evidence.sourceInventoryBefore -cne $Configuration.source.inventorySha256 -or
        $Evidence.sourceInventoryAfter -cne $Evidence.sourceInventoryBefore -or
        $Evidence.originalSha256Before -cne $Configuration.original.sha256 -or
        $Evidence.originalSha256After -cne $Evidence.originalSha256Before -or
        $Evidence.sourceLeaseId -cne $Observation.source.leaseId) {
        throw 'Source inventory, source lease or protected original changed.'
    }
    foreach ($field in @('sourceLeaseHeldThroughout', 'repositoryLockHeldThroughout')) {
        if ($Evidence[$field] -isnot [bool] -or -not $Evidence[$field]) { throw 'Continuous source and repository locking is unproved.' }
    }
    $expected = @('create', 'check-verify-data', 'extract-dry-run')
    if ($Evidence.steps -isnot [array] -or $Evidence.steps.Count -ne $expected.Count) { throw 'Incomplete archive verification stages.' }
    for ($i = 0; $i -lt $expected.Count; $i++) {
        $step = $Evidence.steps[$i]
        Assert-WslRecoveryFields $step @('name', 'exitCode', 'warningCount', 'complete') 'archive stage'
        Assert-WslRecoveryInteger $step.exitCode
        Assert-WslRecoveryInteger $step.warningCount
        if ($step.name -cne $expected[$i] -or $step.exitCode -ne 0 -or $step.warningCount -ne 0 -or
            $step.complete -isnot [bool] -or -not $step.complete) {
            throw 'Archive producer or verification was incomplete, warned or failed.'
        }
    }
}

function Register-WslBorgArchiveEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigurationPath,
        [Parameter(Mandatory)][string]$ObservationPath,
        [Parameter(Mandatory)][string]$ReviewedConfigurationSha256,
        [Parameter(Mandatory)][string]$AttemptPath,
        [Parameter(Mandatory)][string]$JournalDirectory
    )
    $plan = Get-WslBorgReadinessPlan -ConfigurationPath $ConfigurationPath -ObservationPath $ObservationPath -ReviewedConfigurationSha256 $ReviewedConfigurationSha256
    if (-not $plan.InputBindingsValid) { throw 'Archive evidence admission requires complete matching input bindings.' }
    $configDocument = Read-WslRecoveryDocument $ConfigurationPath
    $observationDocument = Read-WslRecoveryDocument $ObservationPath
    $config = $configDocument.Value; $observation = $observationDocument.Value
    $attempt = Read-WslRecoveryDocument $AttemptPath
    # Re-read documents are bound before recording anything, including a pending attempt.
    if ($configDocument.Sha256 -cne $plan.ConfigurationSha256 -or $observationDocument.Sha256 -cne $plan.ObservationSha256) {
        throw 'Input documents changed before evidence admission.'
    }
    $directory = Get-Item -LiteralPath $JournalDirectory -Force -ErrorAction Stop
    if (-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Evidence journal must be an existing private directory.'
    }
    if (-not $IsWindows) {
        if (([IO.File]::GetUnixFileMode($directory.FullName) -band [IO.UnixFileMode]63) -ne 0) {
            throw 'Evidence journal grants group or other access.'
        }
    } else {
        $allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
        foreach ($entry in (Get-Acl -LiteralPath $directory.FullName).Access) {
            if ($entry.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                $entry.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $allowed) {
                throw 'Evidence journal grants access outside the owner, SYSTEM and Administrators.'
            }
        }
    }
    Assert-WslRecoveryDisjoint @($directory.FullName, $config.source.vhdx, $config.source.view, $config.repository.path, $config.original.path)
    $lockPath = Join-Path $directory.FullName '.wsl-recovery-evidence.lock'
    $lockItem = [IO.FileInfo]::new($lockPath)
    if ($null -ne $lockItem.LinkTarget -or (Test-Path -LiteralPath $lockPath -PathType Container) -or
        ($lockItem.Exists -and ($lockItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw 'Unsafe evidence lock path.'
    }
    $lease = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $prefix = Join-Path $directory.FullName $plan.TransactionId
        Write-WslBackupJsonNew ($prefix + '.pending.json') ([ordered]@{
            kind = 'revealfleet-wsl-borg-pending-evidence-v1'; transactionId = $plan.TransactionId
            configurationSha256 = $plan.ConfigurationSha256; attemptSha256 = $attempt.Sha256
        })
        try {
            Assert-WslBorgArchiveEvidence $attempt.Value $plan $config $observation
            if ((Read-WslRecoveryDocument $ConfigurationPath).Sha256 -cne $plan.ConfigurationSha256 -or
                (Read-WslRecoveryDocument $ObservationPath).Sha256 -cne $plan.ObservationSha256) {
                throw 'Input documents changed during evidence admission.'
            }
            $path = $prefix + '.archive-evidence.json'
            Write-WslBackupJsonNew $path ([ordered]@{
                schemaVersion = 1; kind = 'revealfleet-wsl-borg-archive-evidence-v1'
                transactionId = $plan.TransactionId; configurationSha256 = $plan.ConfigurationSha256
                observationSha256 = $plan.ObservationSha256; attemptSha256 = $attempt.Sha256
                repositoryId = $config.repository.id; archiveId = $attempt.Value.archiveId
                toolSha256 = $config.tool.sha256
                sourcePhysicalDeviceId = $config.source.physicalDeviceId
                repositoryPhysicalDeviceId = $config.repository.physicalDeviceId
                originalPhysicalDeviceId = $config.original.physicalDeviceId
                sourceView = $config.source.view; sourceVhdx = $config.source.vhdx
                sourceFilesystemUuid = $config.source.filesystemUuid
                repositoryPath = $config.repository.path
                originalPath = $config.original.path
                sourceInventorySha256 = $config.source.inventorySha256
                keyRecoveryDrillSha256 = $config.keyRecovery.drillSha256
                protectedOriginalSha256 = $config.original.sha256
                verified = $false; fullRestoreAccepted = $false
                evidenceTrust = 'local operator-supplied observations; no backend executed by this recorder'
            })
            return [pscustomobject]@{ EvidencePath = $path; Verified = $false; FullRestoreAccepted = $false; RetentionApplied = $false }
        } catch {
            $failure = $_
            Write-WslBackupJsonNew ($prefix + '.failed.json') ([ordered]@{
                kind = 'revealfleet-wsl-borg-rejected-evidence-v1'; transactionId = $plan.TransactionId
                attemptSha256 = $attempt.Sha256; reason = 'archive-evidence-rejected'; verified = $false
            })
            throw $failure
        }
    } finally { $lease.Dispose() }
}

function Test-WslBorgRestoreInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ArchiveEvidencePath,
        [Parameter(Mandatory)][string]$SourceInventoryPath,
        [Parameter(Mandatory)][string]$RestoredInventoryPath,
        [Parameter(Mandatory)][string]$RestoreObservationPath
    )
    $archive = Read-WslRecoveryDocument $ArchiveEvidencePath
    if ($archive.Value.kind -cne 'revealfleet-wsl-borg-archive-evidence-v1' -or
        $archive.Value.verified -isnot [bool] -or $archive.Value.verified) { throw 'Expected unpromoted archive evidence.' }
    $restore = (Read-WslRecoveryDocument $RestoreObservationPath).Value
    $restoreFields = @('schemaVersion', 'scope', 'archiveEvidenceSha256', 'repositoryId',
        'archiveId', 'toolSha256', 'keyRecoveryDrillSha256', 'sourceUnavailable', 'originalPreserved', 'target')
    if ($restore.schemaVersion -eq 2) { $restoreFields += @('hardwareGuarantee', 'freshTarget') }
    Assert-WslRecoveryFields $restore $restoreFields 'bounded restore observation'
    Assert-WslRecoveryFields $restore.target @('path', 'physicalDeviceId', 'filesystemUuid') 'bounded restore target'
    Assert-WslRecoveryInteger $restore.schemaVersion 1
    if ($restore.schemaVersion -notin @(1, 2) -or $restore.scope -cne 'bounded-fixture' -or
        $restore.archiveEvidenceSha256 -cne $archive.Sha256 -or $restore.repositoryId -cne $archive.Value.repositoryId -or
        $restore.archiveId -cne $archive.Value.archiveId -or $restore.toolSha256 -cne $archive.Value.toolSha256 -or
        $restore.keyRecoveryDrillSha256 -cne $archive.Value.keyRecoveryDrillSha256) {
        throw 'Bounded restore observation is not bound to this archive/tool/key profile.'
    }
    foreach ($field in @('sourceUnavailable', 'originalPreserved')) {
        if ($restore[$field] -isnot [bool] -or -not $restore[$field]) { throw 'Recovery must not depend on the source or replace the last-good original.' }
    }
    foreach ($value in @($restore.target.physicalDeviceId, $restore.target.filesystemUuid)) {
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or $value.Trim() -cne $value) { throw 'Missing independent restore identity.' }
    }
    $sharesSource = $restore.target.physicalDeviceId -ieq $archive.Value.sourcePhysicalDeviceId
    $sharesOriginal = $restore.target.physicalDeviceId -ieq $archive.Value.originalPhysicalDeviceId
    if ($restore.target.physicalDeviceId -ieq $archive.Value.repositoryPhysicalDeviceId) {
        throw 'Restore target must not share backup repository hardware.'
    }
    $guarantee = 'third-hardware-copy'
    $paths = @($restore.target.path, $archive.Value.sourceView, $archive.Value.repositoryPath, $archive.Value.originalPath)
    if ($restore.schemaVersion -eq 2) {
        $guarantee = $restore.hardwareGuarantee
        if ($guarantee -cnotin @('isolated-restore-test', 'third-hardware-copy') -or
            $restore.freshTarget -isnot [bool] -or -not $restore.freshTarget) {
            throw 'Version 2 requires an explicit hardware guarantee and fresh target.'
        }
        if (-not $archive.Value.sourceVhdx -or -not $archive.Value.sourceFilesystemUuid -or
            $restore.target.filesystemUuid -ieq $archive.Value.sourceFilesystemUuid) {
            throw 'Fresh restore filesystem and source-image identity are unproved.'
        }
        $paths += $archive.Value.sourceVhdx
    }
    if ($guarantee -ceq 'third-hardware-copy' -and ($sharesSource -or $sharesOriginal)) {
        throw 'Third-hardware recovery copy requires hardware disjoint from source, repository and original.'
    }
    Assert-WslRecoveryDisjoint $paths
    $source = Read-WslRecoveryDocument $SourceInventoryPath
    $restored = Read-WslRecoveryDocument $RestoredInventoryPath
    if ($source.Sha256 -cne $archive.Value.sourceInventorySha256) { throw 'Source inventory is not bound to the archive evidence.' }
    $fields = @('path', 'type', 'uid', 'gid', 'mode', 'mtimeNs', 'atimeNs', 'contentSha256', 'linkTarget',
        'hardlinkGroup', 'aclSha256', 'xattrsSha256', 'flags', 'sparse', 'deviceMajor', 'deviceMinor')
    foreach ($inventory in @($source.Value, $restored.Value)) {
        Assert-WslRecoveryFields $inventory @('schemaVersion', 'complete', 'entries') 'restore inventory'
        Assert-WslRecoveryInteger $inventory.schemaVersion 1
        if ($inventory.schemaVersion -ne 1 -or $inventory.complete -isnot [bool] -or -not $inventory.complete -or
            $inventory.entries -isnot [array] -or $inventory.entries.Count -eq 0 -or $inventory.entries.Count -gt 4096) {
            throw 'Restore inventory is incomplete or exceeds the bounded contract.'
        }
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($row in $inventory.entries) {
            Assert-WslRecoveryFields $row $fields 'metadata entry'
            if ($row.path -isnot [string] -or -not $names.Add($row.path)) { throw 'Duplicate or missing inventory path.' }
            if ($row.path -ceq '.') {
                if ($row.type -cne 'directory') { throw 'Root inventory entry must describe a directory.' }
            } else {
                foreach ($part in $row.path.Split('/')) {
                    if ($part -in @('', '.', '..') -or $part.Contains('\') -or $part.Contains(':') -or $part.IndexOfAny([char[]]@(0, 10, 13)) -ge 0) { throw 'Unsafe inventory path.' }
                }
            }
            if ($row.type -cnotin @('file', 'directory', 'symlink', 'fifo', 'block', 'character')) { throw 'Unsupported filesystem entry needs explicit disposition.' }
            foreach ($number in @($row.uid, $row.gid, $row.mode, $row.flags, $row.deviceMajor, $row.deviceMinor)) { Assert-WslRecoveryInteger $number }
            Assert-WslRecoveryInteger $row.mtimeNs ([long]::MinValue)
            Assert-WslRecoveryInteger $row.atimeNs ([long]::MinValue)
            if ($row.type -cnotin @('block', 'character') -and ($row.deviceMajor -ne 0 -or $row.deviceMinor -ne 0)) {
                throw 'Only device entries may declare device numbers.'
            }
            foreach ($text in @($row.type, $row.linkTarget, $row.hardlinkGroup)) {
                if ($text -isnot [string]) { throw 'Expected literal inventory type/link values.' }
            }
            foreach ($hash in @($row.contentSha256, $row.aclSha256, $row.xattrsSha256)) { Assert-WslBackupHash $hash }
            if ($row.sparse -isnot [bool]) { throw 'Missing sparse restoration observation.' }
        }
    }
    if ($source.Value.entries.Count -ne $restored.Value.entries.Count) { throw 'Restored inventory does not cover the complete source inventory.' }
    $index = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($row in $restored.Value.entries) { $index[$row.path] = $row }
    foreach ($row in $source.Value.entries) {
        if (-not $index.ContainsKey($row.path)) { throw 'Restored inventory is missing a source path.' }
        foreach ($field in $fields) {
            if ($row[$field] -cne $index[$row.path][$field]) { throw "Restored content or metadata differs: $field" }
        }
    }
    [pscustomobject]@{
        InventoryComparisonPassed = $true; Entries = $source.Value.entries.Count
        ArchiveEvidenceSha256 = $archive.Sha256; FullRestoreAccepted = $false
        HardwareGuarantee = $guarantee; SharesSourceHardware = $sharesSource
        SharesProtectedOriginalHardware = $sharesOriginal
        ThirdHardwareTopologyObserved = (-not $sharesSource -and -not $sharesOriginal)
        ThirdHardwareRecoveryCopyAccepted = $false
        Scope = 'bounded inventory contract only; actual Borg round-trip and independent WSL restore remain required'
    }
}

# Explicit opaque-byte profile; request validation only, never operational admission.
function Get-WslColdContainerReadinessPlan {
    [CmdletBinding()]
    param([string]$ConfigurationPath, [string]$ReviewedConfigurationSha256)
    $result = [ordered]@{
        SchemaVersion = 1; Profile = 'cold-vhd-container-v1'; CanExecute = $false
        Encryption = 'repokey-blake2'; LiveLeaseHeld = $false; ToolBindingVerified = $false
        BackendExecuted = $false; FullRestoreAccepted = $false; RequestBindingsValid = $false
        GuestFileCensusRequired = $false; WholeContainerByteVerificationRequired = $true
        CreateOptions = @('--chunker-params=fixed,4194304', '--files-cache=disabled', '--compression=none', '--stdin-name=ext4.vhdx')
        ExtractOptions = @('--stdout'); Capacity = @(); Blockers = @(
            'Actual Windows registered/canonical source identity, saved work and stopped/quiesced state',
            'Live OS writer/delete-exclusion handle continuously held through source read and archive byte verification',
            'Approved distinct worker registration/runtime/source hashes; source must not be started by worker',
            'Approved independent repository and independent key recovery custody',
            'Reviewed per-filesystem repository/cache/restore overhead and fresh physical capacity',
            'Actual Windows binary process/lease acceptance and reviewed locked production executor',
            'Source-unavailable fresh dense NTFS image with exact bytes/hash before isolated import/boot'
        )
    }
    if (-not $ConfigurationPath -or -not $ReviewedConfigurationSha256) {
        $result.Blockers += 'Explicit cold-container request and reviewed SHA256 are absent.'
        return [pscustomobject]$result
    }
    Assert-WslBackupHash $ReviewedConfigurationSha256
    $doc = Read-WslRecoveryDocument $ConfigurationPath
    if ($doc.Sha256 -cne $ReviewedConfigurationSha256) { throw 'Container request differs from reviewed digest.' }
    $c = $doc.Value
    Assert-WslRecoveryFields $c @('schemaVersion','profile','source','worker','repository','restore','original','budget') 'container request'
    if ($c.schemaVersion -isnot [long] -or $c.schemaVersion -ne 1 -or $c.profile -cne 'cold-vhd-container-v1') { throw 'Unsupported cold-container profile.' }
    Assert-WslRecoveryFields $c.source @('distro','registrationId','vhdx','physicalDeviceId','containerBytes') 'container source'
    Assert-WslRecoveryFields $c.worker @('distro','registrationId','sourceSha256','toolSha256','capacityDomain','availableBytes') 'container worker'
    Assert-WslRecoveryFields $c.repository @('path','physicalDeviceId','capacityDomain','availableBytes') 'container repository'
    Assert-WslRecoveryFields $c.restore @('path','physicalDeviceId','capacityDomain','availableBytes','hardwareGuarantee') 'container restore'
    Assert-WslRecoveryFields $c.original @('path','physicalDeviceId') 'protected original'
    Assert-WslRecoveryFields $c.budget @('repositoryOverheadBytes','cacheWorkspaceBytes','restoreOverheadBytes','reserveBytes') 'container budget'
    Assert-WslBackupLeaf $c.source.distro; Assert-WslBackupLeaf $c.worker.distro
    foreach ($value in @($c.source.registrationId,$c.worker.registrationId)) {
        $guid = [Guid]::Empty
        if ($value -isnot [string] -or -not [Guid]::TryParseExact($value,'D',[ref]$guid)) { throw 'Canonical registration UUID required.' }
    }
    if ($c.source.registrationId -ieq $c.worker.registrationId -or $c.source.distro -ieq $c.worker.distro) { throw 'Worker must not be the source distribution.' }
    foreach ($value in @($c.worker.sourceSha256,$c.worker.toolSha256)) { Assert-WslBackupHash $value }
    foreach ($value in @($c.source.physicalDeviceId,$c.repository.physicalDeviceId,$c.restore.physicalDeviceId,
        $c.original.physicalDeviceId,$c.worker.capacityDomain,$c.repository.capacityDomain,$c.restore.capacityDomain)) {
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or $value.Trim() -cne $value) { throw 'Exact device/capacity identity required.' }
    }
    Assert-WslRecoveryDisjoint @($c.source.vhdx,$c.repository.path,$c.restore.path,$c.original.path)
    if ($c.repository.physicalDeviceId -ieq $c.source.physicalDeviceId -or $c.repository.physicalDeviceId -ieq $c.original.physicalDeviceId -or
        $c.restore.physicalDeviceId -ieq $c.repository.physicalDeviceId) { throw 'Independent repository hardware required.' }
    if ($c.restore.hardwareGuarantee -cnotin @('isolated-restore-test','third-hardware-copy')) { throw 'Explicit restore hardware guarantee required.' }
    $sharesSource = $c.restore.physicalDeviceId -ieq $c.source.physicalDeviceId
    $sharesOriginal = $c.restore.physicalDeviceId -ieq $c.original.physicalDeviceId
    if ($c.restore.hardwareGuarantee -ceq 'third-hardware-copy' -and ($sharesSource -or $sharesOriginal)) { throw 'Third-hardware guarantee is not met.' }
    foreach ($value in @($c.source.containerBytes,$c.budget.repositoryOverheadBytes,$c.budget.cacheWorkspaceBytes,$c.budget.restoreOverheadBytes)) { Assert-WslRecoveryInteger $value 1 }
    Assert-WslRecoveryInteger $c.budget.reserveBytes 64GB
    $domains = @{}
    foreach ($part in @(
        @{ Domain=$c.repository.capacityDomain; Available=$c.repository.availableBytes; Bytes=([decimal]$c.source.containerBytes + $c.budget.repositoryOverheadBytes) },
        @{ Domain=$c.worker.capacityDomain; Available=$c.worker.availableBytes; Bytes=[decimal]$c.budget.cacheWorkspaceBytes },
        @{ Domain=$c.restore.capacityDomain; Available=$c.restore.availableBytes; Bytes=([decimal]$c.source.containerBytes + $c.budget.restoreOverheadBytes) }
    )) {
        Assert-WslRecoveryInteger $part.Available
        if (-not $domains.ContainsKey($part.Domain)) {
            $domains[$part.Domain] = @{ Domain=$part.Domain; AvailableBytes=$part.Available; RequiredBytes=[decimal]$c.budget.reserveBytes }
        } elseif ($domains[$part.Domain].AvailableBytes -ne $part.Available) { throw 'Shared filesystem capacity observations disagree.' }
        $domains[$part.Domain].RequiredBytes += $part.Bytes
    }
    $result.Capacity = @($domains.Values | ForEach-Object {
        [pscustomobject]@{ Domain=$_.Domain; AvailableBytes=$_.AvailableBytes; RequiredBytes=$_.RequiredBytes
            ConditionalFit=([decimal]$_.AvailableBytes -ge $_.RequiredBytes); SavingsCreditBytes=0 }
    })
    $result.RequestBindingsValid = $true; $result.ConfigurationSha256 = $doc.Sha256
    $result.SharesSourceHardware = $sharesSource; $result.SharesProtectedHardware = $sharesOriginal
    $result.Blockers += @($result.Capacity | Where-Object { -not $_.ConditionalFit } | ForEach-Object { 'Insufficient conditional capacity: ' + $_.Domain })
    return [pscustomobject]$result
}

function Initialize-WslBackupBinaryTransport {
    # Only low-level binary mechanics. Never launches a child or opens a VHD.
    if (-not ('Revealfleet.Backup.BinaryTransport' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'WslBackupTransport.cs') -ErrorAction Stop
    }
}

function Initialize-WslColdWorkerProtocol {
    [CmdletBinding()]
    param()
    if (-not ('Revealfleet.Backup.ColdProtocol' -as [type])) {
        Add-Type -Path @((Join-Path $PSScriptRoot 'WslColdProtocol.cs'),(Join-Path $PSScriptRoot 'WslColdSourceLease.cs'),(Join-Path $PSScriptRoot 'WslColdVolumeCustody.cs')) -ErrorAction Stop
    }
}

function Get-WslColdWorkerLaunchPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$WorkerDistro,
          [Parameter(Mandatory)][Guid]$WorkerRegistrationId,
          [Parameter(Mandatory)][Guid]$SourceRegistrationId,
          [Parameter(Mandatory)][Guid]$ProtectedRegistrationId)
    Assert-WslBackupLeaf $WorkerDistro
    if ($WorkerRegistrationId -eq [Guid]::Empty -or $SourceRegistrationId -eq [Guid]::Empty -or
        $ProtectedRegistrationId -eq [Guid]::Empty -or $WorkerRegistrationId -eq $SourceRegistrationId -or
        $WorkerRegistrationId -eq $ProtectedRegistrationId) { throw 'Worker registration must be distinct from source and protected recovery.' }
    # Legacy read-only compatibility plan. Operational argv is derived from a
    # signed policy by Get-WslColdWorkerArguments, never from this old plan.
    # A plan is not a Process or authority to start a distribution. No registry or
    # wsl.exe access, default-distribution selection, shell strings or environment secrets.
    [pscustomobject]@{
        Protocol = 'revkit-cold-worker-v1'; Profile = 'cold-vhd-container-v1'; CanExecute = $false
        FileName = 'wsl.exe'; UseShellExecute = $false; CreateNoWindow = $true
        ArgumentList = @('--distribution',$WorkerDistro,'--exec','/usr/bin/python3','-I','-B',
            '/opt/revkit/wsl-cold-worker.py','--serve')
        WorkerRegistrationId = $WorkerRegistrationId.ToString('D')
        MissingAdmission = @('immutable worker/runtime deployment','authoritative registration and final-handle cold source lease',
            'actual selected-worker Windows protocol acceptance','exclusive repository/native lock plan',
            'fresh capacity and source-outage plan','independent key recovery custody')
    }
}

function Resolve-WslColdRegistrationBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Distro,[Parameter(Mandatory)][Guid]$ExpectedRegistrationId)
    if (-not $IsWindows) { throw 'Authoritative WSL registration resolution requires Windows.' }
    Assert-WslBackupLeaf $Distro
    if ($ExpectedRegistrationId -eq [Guid]::Empty) { throw 'Explicit registered UUID required.' }
    $rows = @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction Stop |
        ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop } |
        Where-Object { $_.DistributionName -ceq $Distro })
    if ($rows.Count -ne 1 -or [Guid]$rows[0].PSChildName -ne $ExpectedRegistrationId) { throw 'Distribution registration binding is missing, changed or ambiguous.' }
    $row=$rows[0]
    $leaf=if ($row.PSObject.Properties.Name -contains 'VhdFileName') { [string]$row.VhdFileName } else { 'ext4.vhdx' }
    Assert-WslBackupLeaf $leaf
    if ([string]::IsNullOrWhiteSpace([string]$row.BasePath)) { throw 'Registered VHD base path is absent.' }
    $path=[IO.Path]::GetFullPath((Join-Path $row.BasePath $leaf))
    if ($path.StartsWith('\\?\',[StringComparison]::Ordinal) -and $path.Length -gt 6 -and $path[5] -eq ':') { $path=$path.Substring(4) }
    if ($path.Length -lt 4 -or $path[1] -ne ':' -or $path[2] -ne '\') { throw 'Registered VHD must resolve to a local drive path.' }
    [pscustomobject]@{Distro=$Distro;RegistrationId=$ExpectedRegistrationId.ToString('D');CanonicalCandidate=$path;ColdProved=$false;LeaseHeld=$false}
}

function Assert-WslColdAclGrants {
    param([object[]]$Entries,[string[]]$Allowed,[switch]$PrivateData,[switch]$Leaf)
    $mask=[Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
    if($Leaf){$mask=$mask -bor [Security.AccessControl.FileSystemRights]::Write}
    if($Leaf -and $PrivateData){$mask=$mask -bor [Security.AccessControl.FileSystemRights]::ReadData}
    foreach($entry in $Entries) {
        # An inherit-only ACE has NO effect on its current ancestor. The
        # leaf is different: templates may expose future private children.
        if($entry.InheritOnly -and -not $Leaf){continue}
        # Only trusted creators can write the validated leaf; CREATOR OWNER
        # therefore maps to that trusted creator, not a public child reader.
        if($entry.Sid -ceq 'S-1-3-0' -and $entry.InheritOnly){continue}
        if($entry.Allow -and $entry.Sid -notin $Allowed -and ([int]$entry.Rights -band [int]$mask)) {throw 'Cold custody ACL grants data or mutation rights outside trusted principals.'}
    }
}

function Assert-WslColdProtectedPath {
    param([Parameter(Mandatory)][string]$Path,[switch]$Directory,[switch]$PrivateData)
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($Directory -ne [bool]$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Protected admission path type/reparse refused.' }
    $trustedInstaller=[Security.Principal.NTAccount]::new('NT SERVICE','TrustedInstaller').Translate([Security.Principal.SecurityIdentifier]).Value
    $allowed=@('S-1-5-18','S-1-5-32-544',$trustedInstaller)
    if($PrivateData){$allowed+=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}
    $current=$item
    while($null -ne $current) {
        if($current.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Admission ancestor reparse refused.'}
        $acl=Get-Acl -LiteralPath $current.FullName
        $owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        if($owner -notin $allowed){throw 'Admission/code ancestor owner is not a protected Windows principal.'}
        $entries=@($acl.Access | ForEach-Object { [pscustomobject]@{Sid=$_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value;Rights=$_.FileSystemRights;Allow=($_.AccessControlType -eq 'Allow');InheritOnly=([int]$_.PropagationFlags -band [int][Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0} })
        Assert-WslColdAclGrants -Entries $entries -Allowed $allowed -PrivateData:$PrivateData -Leaf:($current.FullName -ceq $item.FullName)
        $current=if($current -is [IO.FileInfo]){$current.Directory}else{$current.Parent}
    }
    return $item.FullName
}

function Invoke-WslColdFixedProcess {
    param([string]$FileName,[string[]]$Arguments,[byte[]]$InputBytes=@(),[int]$TimeoutMilliseconds=15000)
    Initialize-WslColdWorkerProtocol
    [Revealfleet.Backup.ColdProtocol]::RunControlAsync($FileName,$Arguments,$InputBytes,$TimeoutMilliseconds).GetAwaiter().GetResult()
}

function Get-WslColdVolumeIdentity {
    param($Disk,$Partition,$Volume)
    $style=$Disk.PartitionStyle.ToString()
    if($style -cnotin @('MBR','GPT')){throw 'Explicit MBR or GPT disk required.'}
    $volumePath=[string]$Volume.UniqueId
    if(-not $volumePath.StartsWith('\\?\Volume{',[StringComparison]::Ordinal) -or -not $volumePath.EndsWith('}\',[StringComparison]::Ordinal)){throw 'Canonical Windows volume identity required.'}
    $volumeId=([Guid]$volumePath.Substring(11,36)).ToString('D')
    if($volumeId -ceq [Guid]::Empty.ToString()){throw 'Empty filesystem capacity identity refused.'}
    $o=[ordered]@{serial=$Disk.SerialNumber.Trim();model=$Disk.FriendlyName;diskBytes=[long]$Disk.Size;
        partitionStyle=$style;logicalSectorBytes=[long]$Disk.LogicalSectorSize;physicalSectorBytes=[long]$Disk.PhysicalSectorSize;
        partitionOffsetBytes=[long]$Partition.Offset;partitionBytes=[long]$Partition.Size;
        volumeUuid=$volumeId;allocationUnitBytes=[long]$Volume.AllocationUnitSize}
    if($style -ceq 'GPT') {
        $o.diskId=([Guid]$Disk.Guid).ToString('D');$o.partitionUuid=([Guid]$Partition.Guid).ToString('D');$o.partitionType=([Guid]$Partition.GptType).ToString('D')
        if(@($o.diskId,$o.partitionUuid,$o.partitionType) -contains [Guid]::Empty.ToString()){throw 'Empty GPT identity refused.'}
    } else {
        if($null -eq $Disk.Signature -or [long]$Disk.Signature -le 0 -or [long]$Disk.Signature -gt [uint32]::MaxValue -or $null -eq $Partition.MbrType -or [long]$Partition.MbrType -le 0 -or [long]$Partition.MbrType -gt 255){throw 'Exact MBR signature/type required.'}
        $o.diskId=[long]$Disk.Signature;$o.partitionType=[long]$Partition.MbrType
    }
    foreach($key in @('diskBytes','logicalSectorBytes','physicalSectorBytes','partitionOffsetBytes','partitionBytes','allocationUnitBytes')){Assert-WslRecoveryInteger $o[$key] 1}
    if([string]::IsNullOrWhiteSpace($o.serial) -or [string]::IsNullOrWhiteSpace($o.model) -or $Volume.FileSystem.ToString() -cne 'NTFS'){throw 'Complete hardware and NTFS volume identity required.'}
    return $o
}

function Assert-WslColdVolumeObservation {
    param($Disk,$Partition,$Volume,$Expected)
    $actual=Get-WslColdVolumeIdentity $Disk $Partition $Volume
    Assert-WslRecoveryFields $Expected @($actual.Keys) 'Windows hardware'
    foreach($key in $actual.Keys){if($actual[$key] -is [string]){if($Expected[$key] -isnot [string]){throw 'Expected exact identity string.'}}else{Assert-WslRecoveryInteger $Expected[$key] 1};if($actual[$key] -cne $Expected[$key]){throw ('Windows hardware/volume drift: '+$key)}}
    # A capacity domain is an observed filesystem volume, not a partition GUID
    # or drive letter. Aliases share the same budget for MBR and GPT alike.
    return $actual.volumeUuid
}

function Assert-WslColdWindowsHardware {
    param([string]$Path,$Expected)
    $root=[IO.Path]::GetPathRoot($Path)
    if($root.Length -ne 3 -or $root[1] -ne ':'){throw 'Local Windows volume required.'}
    $partition=@(Get-Partition -DriveLetter $root[0] -ErrorAction Stop)
    if($partition.Count -ne 1){throw 'Windows target partition missing or ambiguous.'}
    $disk=Get-Disk -Number $partition[0].DiskNumber -ErrorAction Stop
    $volume=@($partition[0]|Get-Volume -ErrorAction Stop)
    if($volume.Count -ne 1){throw 'Windows filesystem volume missing or ambiguous.'}
    $domain=Assert-WslColdVolumeObservation $disk $partition[0] $volume[0] $Expected
    [pscustomobject]@{Domain=$domain;Free=[IO.DriveInfo]::new($root).AvailableFreeSpace;Root=$root}
}

function Assert-WslColdRepositoryHardware {
    param($Repository)
    # This is a fresh Windows observation, never a serial echoed by Linux.
    . (Join-Path $PSScriptRoot 'WslDiskIdentity.ps1')
    $identity=@{schemaVersion=1;serial=$Repository.deviceSerial;model=$Repository.deviceModel;diskBytes=$Repository.deviceBytes;
        partitionBytes=$Repository.partitionBytes;partitionStartSectors=$Repository.partitionOffsetBytes/512;
        partitionSectors=$Repository.partitionBytes/512;partitionUuid=$Repository.partitionUuid}
    [void](Assert-WslDiskHardwareIdentity -Identity $identity -Disks @(Get-Disk -ErrorAction Stop) -Partitions @(Get-Partition -ErrorAction Stop))
}

function Read-WslColdAdmission {
    param([string]$PolicyPath,[string]$ReviewedPolicySha256,[string]$AllowedSignersPath,[string]$ReviewedSignersSha256)
    if(-not $IsWindows){throw 'Production controller requires actual Windows.'}
    Assert-WslBackupHash $ReviewedPolicySha256;Assert-WslBackupHash $ReviewedSignersSha256
    [void](Assert-WslColdProtectedPath $PolicyPath)
    [void](Assert-WslColdProtectedPath ($PolicyPath+'.sig'))
    [void](Assert-WslColdProtectedPath $AllowedSignersPath)
    if((Get-FileHash -LiteralPath $AllowedSignersPath).Hash.ToLowerInvariant() -cne $ReviewedSignersSha256){throw 'Signer trust anchor differs.'}
    $doc=Read-WslRecoveryDocument $PolicyPath
    if($doc.Sha256 -cne $ReviewedPolicySha256){throw 'Policy differs from review.'}
    $ssh=Join-Path $env:SystemRoot 'System32/OpenSSH/ssh-keygen.exe'
    [void](Assert-WslColdProtectedPath $ssh)
    [void](Invoke-WslColdFixedProcess -FileName $ssh -Arguments @('-Y','verify','-f',$AllowedSignersPath,'-I','revkit-owner','-n','revkit-cold-deployment-v1','-s',($PolicyPath+'.sig')) -InputBytes ([IO.File]::ReadAllBytes($PolicyPath)))
    $p=$doc.Value
    Assert-WslRecoveryFields $p @('schemaVersion','profile','sourceCommit','expiresAt','controller','worker','repository','budget','acceptance','keyCustody','operation','transactionId','archiveId') 'signed admission'
    if($p.schemaVersion -isnot [long] -or $p.schemaVersion -ne 1 -or $p.profile -cne 'cold-vhd-container-v1' -or $p.keyCustody -cne 'keyfile-blake2-independent-v1'){throw 'Admission version/key custody differs.'}
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if($p.expiresAt -le $now -or $p.expiresAt -gt $now+86400){throw 'Signed admission must be fresh and at most one day.'}
    Assert-WslRecoveryFields $p.acceptance @('windowsReceiptSha256','selectedWorkerReceiptSha256','custodyReceiptSha256','capacityReceiptSha256') 'signed acceptance hashes'
    foreach($value in $p.acceptance.Values){if($p.operation -ceq 'prepare' -and $value -ceq ''){continue};Assert-WslBackupHash $value}
    if($p.operation -cnotin @('prepare','backup','restore') -or $p.transactionId -cne ([Guid]$p.transactionId).ToString('D') -or $p.archiveId -cne ([Guid]$p.archiveId).ToString('D')){throw 'Signed operation UUIDs required.'}
    if($p.operation -ceq 'backup' -and $p.transactionId -cne $p.archiveId){throw 'New archive required.'}
    Assert-WslRecoveryInteger $p.budget.timeoutSeconds 1
    if($p.budget.timeoutSeconds -gt 86400){throw 'Bounded operation timeout required.'}
    if(@($p.acceptance.Keys).Count -ne 4){throw 'Four independently reviewed acceptance/custody/capacity receipt hashes required.'}
    foreach($path in $p.controller.files.Keys){
        [void](Assert-WslColdProtectedPath $path)
        if((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $p.controller.files[$path]){throw 'Controller runtime bytes differ from signed deployment.'}
    }
    $required=@((Join-Path $PSScriptRoot 'WslBackup.ps1'),(Join-Path $PSScriptRoot 'WslColdProtocol.cs'),(Join-Path $PSScriptRoot 'WslColdSourceLease.cs'),(Join-Path $PSScriptRoot 'WslColdVolumeCustody.cs'),(Join-Path $PSScriptRoot 'WslDiskIdentity.ps1'),(Join-Path $PSScriptRoot '..' 'Test-WslColdHardware.ps1'))
    foreach($path in $required){if(-not $p.controller.files.Contains($path)){throw 'Signed controller source closure incomplete.'}}
    [void](Get-WslColdWorkerControlBudget $p prepare)
    if($p.worker.registrationId -in @($p.controller.source.registrationId,$p.controller.protected.registrationId) -or $p.worker.distro -in @($p.controller.source.distro,$p.controller.protected.distro)){throw 'Worker aliases source/protected registration.'}
    Assert-WslRecoveryDisjoint @($p.controller.source.vhdx,$p.controller.protected.vhdx,$p.controller.workerVhdx.path,$p.controller.restore.path)
    if($p.repository.deviceSerial -in @($p.controller.source.hardware.serial,$p.controller.protected.hardware.serial,$p.controller.restore.hardware.serial)){throw 'Repository hardware must be independent.'}
    if($p.controller.restore.hardwareGuarantee -cnotin @('isolated-restore-test','third-hardware-copy')){throw 'Explicit restore guarantee required.'}
    if($p.controller.restore.hardwareGuarantee -ceq 'third-hardware-copy' -and $p.controller.restore.hardware.serial -in @($p.controller.source.hardware.serial,$p.controller.protected.hardware.serial)){throw 'Third hardware guarantee is false.'}
    return $doc
}

function Assert-WslColdBindings {
    param($Policy,[switch]$RequireSourceAbsent,[long]$RestoredBytes=0,[switch]$AllowSourceRunning)
    foreach($record in @($Policy.controller.source,$Policy.controller.protected,@{distro=$Policy.worker.distro;registrationId=$Policy.worker.registrationId;vhdx=$Policy.controller.workerVhdx.path})) {
        $observed=Resolve-WslColdRegistrationBinding -Distro $record.distro -ExpectedRegistrationId $record.registrationId
        if($observed.CanonicalCandidate -ine $record.vhdx){throw 'Registered VHD path changed.'}
    }
    $running=Invoke-WslColdFixedProcess -FileName (Join-Path $env:SystemRoot 'System32/wsl.exe') -Arguments @('--list','--running','--quiet')
    $names=@($running.Replace([string][char]0,'').Split("`n")|ForEach-Object {$_.Trim()})
    if((-not $AllowSourceRunning -and $Policy.controller.source.distro -in $names) -or $Policy.controller.protected.distro -in $names){throw 'Source and protected recovery must remain stopped; nothing was terminated.'}
    # Source unavailability for restore is established by a continuously held
    # writer-excluding handle too: a stopped registration cannot open its VHD.
    if($RequireSourceAbsent -and $null -eq $script:WslColdActiveLease){throw 'Restore requires retained source exclusion through destination commit.'}
    Assert-WslColdRepositoryHardware $Policy.repository
    $domains=@{}
    foreach($part in @(
        @{Path=$Policy.controller.restore.path;Hardware=$Policy.controller.restore.hardware;Bytes=([decimal]$Policy.controller.restore.imageBytes-$RestoredBytes+$Policy.controller.restore.overheadBytes)},
        @{Path=$Policy.controller.workerVhdx.path;Hardware=$Policy.controller.workerVhdx.hardware;Bytes=[decimal]$Policy.budget.workspaceAdditionalBytes}
    )){
        $o=Assert-WslColdWindowsHardware $part.Path $part.Hardware
        if(-not $domains.ContainsKey($o.Domain)){$domains[$o.Domain]=@{Free=$o.Free;Required=[decimal]$Policy.budget.reserveBytes}}
        $domains[$o.Domain].Required+=$part.Bytes
    }
    Assert-WslRecoveryInteger $Policy.budget.reserveBytes 64GB
    foreach($domain in $domains.Values){if($domain.Free -lt $domain.Required){throw 'Fresh Windows per-filesystem capacity refuses full dense restore/workspace/reserve.'}}
}

function Get-WslColdWorkerControlBudget {
    param($Policy,[ValidateSet('prepare','status','reconcile','probe')][string]$Action)
    $b=$Policy.worker.controlBudget
    Assert-WslRecoveryFields $b @('bootInitMilliseconds','launchAllowanceMilliseconds','operationMilliseconds','reconciliationMilliseconds','frontendTeardownMilliseconds') 'selected-worker control budget'
    foreach($key in $b.Keys){Assert-WslRecoveryInteger $b[$key] 1}
    if($b.bootInitMilliseconds -lt 10000 -or $b.bootInitMilliseconds -gt 120000 -or $b.launchAllowanceMilliseconds -gt 60000 -or
        $b.operationMilliseconds -gt 60000 -or $b.reconciliationMilliseconds -gt 60000 -or $b.frontendTeardownMilliseconds -gt 10000){throw 'Selected-worker bounded boot/control/teardown policy refused.'}
    [pscustomobject]@{StartupMilliseconds=([int]$b.bootInitMilliseconds+[int]$b.launchAllowanceMilliseconds);
        OperationMilliseconds=$(if($Action -ceq 'reconcile'){$b.reconciliationMilliseconds}else{$b.operationMilliseconds});TeardownMilliseconds=$b.frontendTeardownMilliseconds}
}

function Invoke-WslColdSelectedControl {
    param($Policy,[ValidateSet('prepare','status','reconcile','probe')][string]$Action)
    $b=Get-WslColdWorkerControlBudget $Policy $Action
    Initialize-WslColdWorkerProtocol
    [Revealfleet.Backup.ColdProtocol]::RunSelectedWorkerControlAsync((Join-Path $env:SystemRoot 'System32/wsl.exe'),
        [string[]](Get-WslColdWorkerArguments $Policy $Action),[byte[]]@(),$b.StartupMilliseconds,$b.OperationMilliseconds,$b.TeardownMilliseconds).GetAwaiter().GetResult()
}

function Get-WslColdWorkerArguments {
    param($Policy,[string]$Action)
    $base=@('--distribution',$Policy.worker.distro,'--user','root','--exec')
    if($Action -ceq 'serve') {
        $unit='revkit-cold-'+$Policy.transactionId+'.service'
        return $base+@('/usr/bin/systemd-run','--quiet','--pipe','--wait','--collect','--service-type=exec',
            ('--unit='+$unit),'--property=Slice=system.slice','--property=KillMode=control-group',
            '--property=TimeoutStopSec=10s',('--property=RuntimeMaxSec='+([long]$Policy.budget.timeoutSeconds+30)+'s'),
            $Policy.worker.interpreter,'-I','-B',('/opt/revkit-wsl-backup/'+$Policy.sourceCommit+'/scripts/wsl-cold-worker.py'),'--serve')
    }
    if($Action -ceq 'probe'){return $base+@($Policy.worker.interpreter,'-I','-B',('/opt/revkit-wsl-backup/'+$Policy.sourceCommit+'/scripts/wsl-cold-worker.py'),'--control-probe')}
    if($Action -cin @('reconcile','status')) {return $base+@($Policy.worker.interpreter,'-I','-B',('/opt/revkit-wsl-backup/'+$Policy.sourceCommit+'/scripts/wsl-cold-worker.py'),('--control-'+$Action),$Policy.transactionId)}
    return $base+@($Policy.worker.interpreter,'-I','-B',('/opt/revkit-wsl-backup/'+$Policy.sourceCommit+'/scripts/wsl-cold-worker.py'),'--control-prepare')
}

function Read-WslColdArchiveReceipt {
    param([string]$Path,[string]$Sha256,[string]$Signers,$Policy)
    Assert-WslBackupHash $Sha256
    [void](Assert-WslColdProtectedPath $Path -PrivateData);[void](Assert-WslColdProtectedPath ($Path+'.sig') -PrivateData)
    $receipt=Read-WslRecoveryDocument $Path
    if($receipt.Sha256 -cne $Sha256 -or $Policy.controller.restore.archiveReceiptSha256 -cne $Sha256){throw 'Restore archive receipt differs from signed admission.'}
    [void](Invoke-WslColdFixedProcess -FileName (Join-Path $env:SystemRoot 'System32/OpenSSH/ssh-keygen.exe') -Arguments @('-Y','verify','-f',$Signers,'-I','revkit-owner','-n','revkit-cold-archive-v1','-s',($Path+'.sig')) -InputBytes ([IO.File]::ReadAllBytes($Path)))
    $r=$receipt.Value
    Assert-WslRecoveryFields $r @('profile','repositoryId','archiveId','imageBytes','imageSha256','sourceCommit','transactionId','workerReceiptSha256','bindingSha256','nativeArchiveId') 'archive receipt'
    Assert-WslBackupHash $r.imageSha256
    if($r.profile -cne $Policy.profile -or $r.repositoryId -cne $Policy.repository.id -or $r.archiveId -cne $Policy.archiveId -or $r.imageBytes -ne $Policy.controller.restore.imageBytes -or $r.nativeArchiveId -cne $Policy.controller.restore.nativeArchiveId){throw 'Archive/byte identity differs from reviewed restore.'}
    return $r
}

function Complete-WslColdCustody {
    param([string]$TransactionId,[switch]$ObserveOnly)
    if(-not $script:WslColdRetained -or -not $script:WslColdRetained.ContainsKey($TransactionId)){throw 'No retained transaction in this controller process.'}
    $held=$script:WslColdRetained[$TransactionId]
    $stage='signed-worker-kernel-reconciliation'
    try {
        $text=Invoke-WslColdSelectedControl $held.Policy $(if($ObserveOnly){'status'}else{'reconcile'})
        $r=$text|ConvertFrom-Json -AsHashtable
        Assert-WslRecoveryFields $r @('transactionId','bindingSha256','linuxUnitEmpty','futureLaunchCancelled') 'kernel reconciliation'
        if($r.transactionId -cne $TransactionId -or $r.bindingSha256 -cne $held.Binding -or $r.linuxUnitEmpty -ne $true -or $r.futureLaunchCancelled -ne $true -or
            -not [Revealfleet.Backup.ColdProtocol]::CallerIoSettled($TransactionId)){throw 'Actual unit/stream lifetime is still unconfirmed.'}
        $stage='caller-io-and-frontend-exit'
        $held.Guard.StopAsync().GetAwaiter().GetResult();$held.Guard.Dispose()
        if(-not $held.Child.HasExited){$held.Child.Kill($true);[void]$held.Child.WaitForExit([int]$held.Policy.worker.controlBudget.frontendTeardownMilliseconds)}
        if(-not $held.Child.HasExited){throw 'Owned Windows frontend exit unconfirmed.'}
        $held.Lease.ValidateUnchanged()
        $held.Secret.Dispose();if($null -ne $held.Output){$held.Output.Dispose()}
        $held.Lease.Dispose();$held.Child.Dispose();$held.Cancellation.Dispose()
        $script:WslColdRetained.Remove($TransactionId)
        [pscustomobject]@{TransactionId=$TransactionId;CustodyRetained=$false;FailedAttemptPreserved=$true;LinuxUnitReconciled=$true}
    } catch {
        # Never dispose a lease/partial merely because status or permission failed.
        [pscustomobject]@{TransactionId=$TransactionId;CustodyRetained=$true;FailedAttemptPreserved=$true;LinuxUnitReconciled=$false;Gate=$stage}
    }
}

function Invoke-WslColdContainerOperation {
    [CmdletBinding()]
    param([ValidateSet('prepare','backup','restore','reconcile')][string]$Phase='prepare',
        [Parameter(Mandatory)][string]$PolicyPath,[Parameter(Mandatory)][string]$ReviewedPolicySha256,
        [Parameter(Mandatory)][string]$AllowedSignersPath,[Parameter(Mandatory)][string]$ReviewedSignersSha256,
        [Security.SecureString]$Passphrase,[IO.Stream]$IndependentKey,
        [string]$TransactionId,[string]$BackupReceiptPath,[string]$ReviewedBackupReceiptSha256,[switch]$Execute,[switch]$ObserveOnly)
    if($Phase -ceq 'reconcile') {
        if(-not $Execute){return [pscustomobject]@{Phase=$Phase;BackendExecuted=$false}}
        return Complete-WslColdCustody $TransactionId -ObserveOnly:$ObserveOnly
    }
    # Immutable signature, code, identities and positive budgets precede effects.
    $doc=Read-WslColdAdmission $PolicyPath $ReviewedPolicySha256 $AllowedSignersPath $ReviewedSignersSha256
    $p=$doc.Value
    if($TransactionId -and $TransactionId -cne $p.transactionId){throw 'Transaction differs from signed admission.'}
    if(-not $Execute){return [pscustomobject]@{Phase=$Phase;SignedPolicyVerified=$true;BackendExecuted=$false;FullRestoreAccepted=$false}}
    if($Phase -cne 'prepare' -and $Phase -cne $p.operation){throw 'Operation differs from signed admission.'}
    $restore=$null
    if($Phase -cne 'prepare') {
    if($null -eq $Passphrase -or $Passphrase.Length -eq 0 -or $null -eq $IndependentKey -or -not $IndependentKey.CanRead){throw 'Private caller passphrase and independent encrypted key stream required; no scheduled broker/fallback.'}
    if($Phase -ceq 'restore'){$restore=Read-WslColdArchiveReceipt $BackupReceiptPath $ReviewedBackupReceiptSha256 $AllowedSignersPath $p}
    }
    Assert-WslColdBindings $p -AllowSourceRunning:($Phase -ceq 'prepare')
    [void](Assert-WslColdWindowsHardware $p.controller.source.vhdx $p.controller.source.hardware)
    [void](Assert-WslColdWindowsHardware $p.controller.protected.vhdx $p.controller.protected.hardware)
    $worker=Invoke-WslColdSelectedControl $p prepare
    $probe=$worker|ConvertFrom-Json -AsHashtable
    if($probe.bindingSha256 -cne $doc.Sha256 -or $probe.repositoryId -cne $p.repository.id -or $probe.runtimeAdmitted -ne $true){throw 'Actual immutable worker admission differs.'}
    if($Phase -ceq 'prepare'){return [pscustomobject]@{Phase=$Phase;RuntimeAdmitted=$true;RepositoryInitialized=$probe.repositoryInitialized;BackendExecuted=$false;FullRestoreAccepted=$false;ColdSourceProved=$false;BindingSha256=$doc.Sha256}}
    Initialize-WslColdWorkerProtocol
    $lease=$target=$guard=$secret=$child=$cts=$null;$launched=$false
    try {
        $lease=[Revealfleet.Backup.ColdSourceLease]::new($p.controller.source.vhdx,$p.controller.source.fileIdentity,($Phase -ceq 'restore'))
        if($lease.Length -ne $p.controller.source.containerBytes){throw 'Cold held-container size differs; no live-size estimate admitted.'}
        $script:WslColdActiveLease=$lease
        Assert-WslColdBindings $p -RequireSourceAbsent:($Phase -ceq 'restore')
        [void](Assert-WslColdProtectedPath $p.controller.journalDirectory -Directory -PrivateData)
        $journal=Join-Path $p.controller.journalDirectory $p.transactionId
        [Revealfleet.Backup.ColdSourceLease]::CreateTransactionDirectory($journal)
        Write-WslBackupJsonNew (Join-Path $journal 'pending.json') @{phase=$Phase;bindingSha256=$doc.Sha256;transactionId=$p.transactionId;sourceIdentity=$lease.FileIdentity}
        $cts=[Threading.CancellationTokenSource]::new([int]($p.budget.timeoutSeconds*1000))
        if($Phase -ceq 'restore') {
            [void](Assert-WslColdProtectedPath ([IO.Path]::GetDirectoryName($p.controller.restore.path)) -Directory -PrivateData)
            $target=[IO.File]::Open($p.controller.restore.path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read)
            $sha=$restore.imageSha256;$bytes=$restore.imageBytes;$incoming=[IO.Stream]::Null
        } else {$target=$null;$sha=$null;$bytes=$lease.Length;$incoming=$lease.Bytes}
        $guard=[Revealfleet.Backup.ColdCommitGuard]::new($lease,$target,$p.controller.restore.path,$sha,([IO.File]::ReadAllBytes($PolicyPath)),$cts)
        $probeScript=Join-Path $PSScriptRoot '..' 'Test-WslColdHardware.ps1'
        $probeHost=(Get-Process -Id $PID).Path
        [void](Assert-WslColdProtectedPath $probeHost)
        $guard.ConfigureHardwareProbe($probeHost,$probeScript,$PolicyPath,$doc.Sha256)
        $guard.StartMonitor()
        if($Phase -ceq 'backup') {
            $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashDataAsync($incoming,$cts.Token).GetAwaiter().GetResult()).ToLowerInvariant()
            $incoming.Position=0
        }
        $request=@{protocol='revkit-cold-worker-v1';profile=$p.profile;transactionId=$p.transactionId;archiveId=$p.archiveId;phase=$Phase;bindingSha256=$doc.Sha256;bytes=$bytes;sha256=$sha}
        $secret=[Revealfleet.Backup.ColdCommitGuard]::PrivateInput($Passphrase)
        $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/wsl.exe'))
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        foreach($arg in (Get-WslColdWorkerArguments $p 'serve')){$start.ArgumentList.Add($arg)}
        $child=[Diagnostics.Process]::new();$child.StartInfo=$start
        [void]$child.Start();$launched=$true
        $outgoing=if($null -eq $target){[IO.Stream]::Null}else{$target}
        $receipt=[Revealfleet.Backup.ColdProtocol]::ExchangeAsync($child,$incoming,$outgoing,$secret,([Text.Encoding]::UTF8.GetBytes(($request|ConvertTo-Json -Compress))),[int]($p.budget.timeoutSeconds*1000),$cts.Token,$guard.Callback(),$IndependentKey).GetAwaiter().GetResult()
        $guard.StopAsync().GetAwaiter().GetResult()
        $lease.ValidateUnchanged()
        Assert-WslColdBindings $p -RequireSourceAbsent:($Phase -ceq 'restore') -RestoredBytes $(if($null -ne $target){$target.Length}else{0})
        Write-WslBackupJsonNew (Join-Path $journal 'worker-final.json') ([Text.Encoding]::UTF8.GetString($receipt)|ConvertFrom-Json -AsHashtable)
        $archive=@{profile=$p.profile;repositoryId=$p.repository.id;archiveId=$p.archiveId;imageBytes=$bytes;imageSha256=$sha;sourceCommit=$p.sourceCommit;transactionId=$p.transactionId;nativeArchiveId=([Text.Encoding]::UTF8.GetString($receipt)|ConvertFrom-Json -AsHashtable).nativeArchiveId;workerReceiptSha256=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($receipt)).ToLowerInvariant());bindingSha256=$doc.Sha256}
        Write-WslBackupJsonNew (Join-Path $journal 'archive-receipt.json') $archive
        [pscustomobject]@{Phase=$Phase;TransactionId=$p.transactionId;CustodyRetained=$false;BackendExecuted=$true;ImageBytes=$bytes;ImageSha256=$sha;ArchiveReceipt=(Join-Path $journal 'archive-receipt.json');DenseRestoreVerified=($Phase -ceq 'restore');FullRestoreAccepted=$false;ImportPerformed=$false}
    } catch {
        if($launched) {
            if(-not $script:WslColdRetained){$script:WslColdRetained=@{}}
            $script:WslColdRetained[$p.transactionId]=@{Policy=$p;Binding=$doc.Sha256;Lease=$lease;Output=$target;Secret=$secret;Child=$child;Guard=$guard;Cancellation=$cts}
            $lease=$target=$secret=$child=$guard=$cts=$null
            return Complete-WslColdCustody $p.transactionId
        }
        throw 'Cold operation refused before worker execution; pending/partial custody preserved.'
    } finally {
        if($null -ne $guard){$guard.StopAsync().GetAwaiter().GetResult();$guard.Dispose()}
        if($null -ne $secret){$secret.Dispose()};if($null -ne $target){$target.Dispose()}
        if($null -ne $lease){$lease.Dispose()};if($null -ne $child){$child.Dispose()};if($null -ne $cts){$cts.Dispose()}
        $script:WslColdActiveLease=$null
    }
}

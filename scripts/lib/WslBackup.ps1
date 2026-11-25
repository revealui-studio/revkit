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
            'Additional approved independent full-restore target and isolated restore acceptance'
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
                sourceView = $config.source.view; repositoryPath = $config.repository.path
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
    Assert-WslRecoveryFields $restore @('schemaVersion', 'scope', 'archiveEvidenceSha256', 'repositoryId',
        'archiveId', 'toolSha256', 'keyRecoveryDrillSha256', 'sourceUnavailable', 'originalPreserved', 'target') 'bounded restore observation'
    Assert-WslRecoveryFields $restore.target @('path', 'physicalDeviceId', 'filesystemUuid') 'bounded restore target'
    Assert-WslRecoveryInteger $restore.schemaVersion 1
    if ($restore.schemaVersion -ne 1 -or $restore.scope -cne 'bounded-fixture' -or
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
    foreach ($identity in @($archive.Value.sourcePhysicalDeviceId, $archive.Value.repositoryPhysicalDeviceId, $archive.Value.originalPhysicalDeviceId)) {
        if ($restore.target.physicalDeviceId -ieq $identity) { throw 'Restore target is not independent of source, repository and original.' }
    }
    Assert-WslRecoveryDisjoint @($restore.target.path, $archive.Value.sourceView, $archive.Value.repositoryPath, $archive.Value.originalPath)
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
        Scope = 'bounded inventory contract only; actual Borg round-trip and independent WSL restore remain required'
    }
}

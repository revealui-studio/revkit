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

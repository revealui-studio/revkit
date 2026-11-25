#Requires -Version 7.0

BeforeAll {
    . (Join-Path $PSScriptRoot '..' '..' 'scripts' 'lib' 'WslBackup.ps1')
}

Describe 'Cold backup capacity preserves existing recovery' {
    It 'fits one measured full image with reserve' {
        $plan = Get-WslBackupCapacityPlan -SourceBytes 633995264000 -AvailableBytes 943636373504 -ReserveBytes 1073741824
        $plan.CanExport | Should -BeTrue
        $plan.RequiredBytes | Should -Be 635069005824
    }
    It 'refuses the next full image without reclaiming the last recovery' {
        $plan = Get-WslBackupCapacityPlan -SourceBytes 633995264000 -AvailableBytes 309641109504 -ReserveBytes 1073741824
        $plan.CanExport | Should -BeFalse
        $plan.ReclaimBeforeExportBytes | Should -Be 0
    }
    It 'rejects negative or unknown source capacity' {
        { Get-WslBackupCapacityPlan -SourceBytes 0 -AvailableBytes 1000 -ReserveBytes 0 } | Should -Throw
    }
}

Describe 'Verified artifacts require preserved content and restoration proof' {
    BeforeEach {
        $script:Artifact = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N') + '.vhdx')
        [IO.File]::WriteAllText($script:Artifact, 'synthetic recovery bytes')
        $script:Hash = (Get-FileHash -LiteralPath $script:Artifact -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:Proof = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N') + '.json')
        $script:Evidence = @{
            schemaVersion = 1; kind = 'revealfleet-wsl-restore-validation'; sourceDistro = 'Ubuntu'
            recoveryDistro = 'Ubuntu-synthetic-recovery'; artifactSha256 = $script:Hash
            artifactBytes = (Get-Item -LiteralPath $script:Artifact).Length
            artifactPreserved = $true; verifiedAt = [DateTimeOffset]::UtcNow.ToString('o')
            verifierProtocol = 'revealfleet-isolated-restore-probe-v1'; verifierSourceSha256 = '1' * 64
            probe = @{ protocol = 'revealfleet-isolated-restore-probe-v1'; pid1Comm = 'init'; rootFilesystem = 'ext4'; uid = 1000; homeExists = $true; repositoryExists = $true; unexpectedProcesses = @() }
            checks = @{ registration = $true; filesystem = $true; boot = $true; identity = $true; servicesIsolated = $true }
        }
    }
    It 'round trips a checksum-bound independent restoration result' {
        $script:Evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:Proof
        $confirmed = Confirm-WslBackupArtifact -ArtifactPath $script:Artifact -Distro Ubuntu -RestoreEvidencePath $script:Proof
        $confirmed.Sha256 | Should -Be $script:Hash
        (Get-WslVerifiedBackup -ReceiptPath $confirmed.ReceiptPath -VerifyContent).ContentRehashed | Should -BeTrue
    }
    It 'rejects a forged digest even when every restore check says true' {
        $script:Evidence.artifactSha256 = '0' * 64
        $script:Evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:Proof
        { Confirm-WslBackupArtifact -ArtifactPath $script:Artifact -Distro Ubuntu -RestoreEvidencePath $script:Proof } | Should -Throw
        Test-Path -LiteralPath ($script:Artifact + '.verified.json') | Should -BeFalse
    }
    It 'refuses success based only on a large artifact and no proof' {
        { Confirm-WslBackupArtifact -ArtifactPath $script:Artifact -Distro Ubuntu -RestoreEvidencePath ($script:Proof + '.missing') } | Should -Throw
    }
    It 'rejects bare success booleans without maintained recovery observations' {
        $script:Evidence.Remove('probe')
        $script:Evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:Proof
        { Confirm-WslBackupArtifact -ArtifactPath $script:Artifact -Distro Ubuntu -RestoreEvidencePath $script:Proof } | Should -Throw
    }
    It 'rejects incomplete service isolation or live-source restore claims' {
        $script:Evidence.checks.servicesIsolated = $false
        $script:Evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:Proof
        { Confirm-WslBackupArtifact -ArtifactPath $script:Artifact -Distro Ubuntu -RestoreEvidencePath $script:Proof } | Should -Throw
        $script:Evidence.checks.servicesIsolated = $true
        $script:Evidence.recoveryDistro = 'Ubuntu'
        $script:Evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:Proof
        { Confirm-WslBackupArtifact -ArtifactPath $script:Artifact -Distro Ubuntu -RestoreEvidencePath $script:Proof } | Should -Throw
    }
    It 'rejects a changed artifact and an altered proof' {
        $script:Evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:Proof
        $confirmed = Confirm-WslBackupArtifact -ArtifactPath $script:Artifact -Distro Ubuntu -RestoreEvidencePath $script:Proof
        [IO.File]::AppendAllText($script:Artifact, 'truncated or changed')
        { Get-WslVerifiedBackup -ReceiptPath $confirmed.ReceiptPath } | Should -Throw
    }
    It 'rejects changed evidence even when artifact metadata still matches' {
        $script:Evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:Proof
        $confirmed = Confirm-WslBackupArtifact -ArtifactPath $script:Artifact -Distro Ubuntu -RestoreEvidencePath $script:Proof
        [IO.File]::AppendAllText($confirmed.RestoreEvidencePath, ' ')
        { Get-WslVerifiedBackup -ReceiptPath $confirmed.ReceiptPath } | Should -Throw
    }
    It 'rejects unsupported receipt layouts and escaping artifact paths' {
        $script:Evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:Proof
        $confirmed = Confirm-WslBackupArtifact -ArtifactPath $script:Artifact -Distro Ubuntu -RestoreEvidencePath $script:Proof
        $receipt = Get-Content -LiteralPath $confirmed.ReceiptPath -Raw | ConvertFrom-Json
        $receipt.artifactFile = '../outside.vhdx'
        $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $confirmed.ReceiptPath
        { Get-WslVerifiedBackup -ReceiptPath $confirmed.ReceiptPath } | Should -Throw
    }
}

Describe 'Backup failures do not delete the last recovery' {
    BeforeEach {
        $script:Directory = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Directory | Out-Null
        $script:Source = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N') + '.vhdx')
        [IO.File]::WriteAllText($script:Source, 'source')
        $script:LastGood = Join-Path $script:Directory 'last-verified.vhdx'
        [IO.File]::WriteAllText($script:LastGood, 'preserved recovery')
    }
    It 'refuses capacity before running the exporter or deleting anything' {
        Mock Invoke-WslBackupExport { throw 'export must not be called' }
        { Invoke-WslColdBackup -Distro Ubuntu -SourceVhdx $script:Source -Directory $script:Directory -AvailableBytes 1 -ReserveBytes 0 -Execute } | Should -Throw
        Should -Invoke Invoke-WslBackupExport -Times 0 -Exactly
        [IO.File]::ReadAllText($script:LastGood) | Should -Be 'preserved recovery'
    }
    It 'preserves the partial artifact and the last recovery when export fails' {
        Mock Invoke-WslBackupExport { param($Distro, $Target) [IO.File]::WriteAllText($Target, 'partial'); throw 'producer failed' }
        { Invoke-WslColdBackup -Distro Ubuntu -SourceVhdx $script:Source -Directory $script:Directory -AvailableBytes 100 -ReserveBytes 0 -Execute } | Should -Throw
        @((Get-ChildItem -LiteralPath $script:Directory -Filter '*.partial.vhdx')).Count | Should -Be 1
        @((Get-ChildItem -LiteralPath $script:Directory -Filter '*.verified.json')).Count | Should -Be 0
        [IO.File]::ReadAllText($script:LastGood) | Should -Be 'preserved recovery'
    }
    It 'leaves even successful exports pending independent restore verification' {
        Mock Invoke-WslBackupExport { param($Distro, $Target) [IO.File]::WriteAllText($Target, 'completed synthetic export') }
        $result = Invoke-WslColdBackup -Distro Ubuntu -SourceVhdx $script:Source -Directory $script:Directory -AvailableBytes 100 -ReserveBytes 0 -Execute
        $result.Verified | Should -BeFalse
        $result.RetentionApplied | Should -BeFalse
        Test-Path -LiteralPath ($result.ArtifactPath + '.pending.json') | Should -BeTrue
        [IO.File]::ReadAllText($script:LastGood) | Should -Be 'preserved recovery'
    }
    It 'never prunes without a newly verified replacement' {
        $backups = @([pscustomobject]@{ ArtifactPath = $script:LastGood; VerifiedAt = [DateTimeOffset]::UtcNow })
        { Get-WslBackupRetentionPlan -VerifiedBackups $backups -NewVerifiedArtifact 'unknown' -KeepCount 1 } | Should -Throw
        Test-Path -LiteralPath $script:LastGood | Should -BeTrue
    }
    It 'selects only older verified images after a replacement passes' {
        $next = Join-Path $script:Directory 'new.vhdx'
        $backups = @(
            [pscustomobject]@{ ArtifactPath = $script:LastGood; VerifiedAt = [DateTimeOffset]::UtcNow.AddDays(-1) },
            [pscustomobject]@{ ArtifactPath = $next; VerifiedAt = [DateTimeOffset]::UtcNow }
        )
        $plan = @(Get-WslBackupRetentionPlan -VerifiedBackups $backups -NewVerifiedArtifact $next -KeepCount 1)
        $plan.Count | Should -Be 1
        $plan[0].ArtifactPath | Should -Be $script:LastGood
        Test-Path -LiteralPath $script:LastGood | Should -BeTrue
    }
}

Describe 'Health monitor consumes the same verified artifact contract' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'powershell' 'Modules' 'RevealUI.RevStation' 'Private' 'Invoke-WslProbe.ps1')
        $script:HealthScript = Join-Path $PSScriptRoot '..' '..' 'scripts' 'check-backup-staleness.ps1'
    }
    BeforeEach {
        $script:HealthDirectory = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:HealthDirectory | Out-Null
        $script:HealthArtifact = Join-Path $script:HealthDirectory 'Ubuntu-synthetic.vhdx'
        [IO.File]::WriteAllText($script:HealthArtifact, 'synthetic preserved recovery')
        $script:HealthProof = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N') + '.json')
        $script:HealthEvidence = @{
            schemaVersion = 1; kind = 'revealfleet-wsl-restore-validation'; sourceDistro = 'Ubuntu'
            recoveryDistro = 'Ubuntu-synthetic-recovery'
            artifactSha256 = (Get-FileHash -LiteralPath $script:HealthArtifact -Algorithm SHA256).Hash.ToLowerInvariant()
            artifactBytes = (Get-Item -LiteralPath $script:HealthArtifact).Length
            artifactPreserved = $true; verifiedAt = [DateTimeOffset]::UtcNow.ToString('o')
            verifierProtocol = 'revealfleet-isolated-restore-probe-v1'; verifierSourceSha256 = '1' * 64
            probe = @{ protocol = 'revealfleet-isolated-restore-probe-v1'; pid1Comm = 'init'; rootFilesystem = 'ext4'; uid = 1000; homeExists = $true; repositoryExists = $true; unexpectedProcesses = @() }
            checks = @{ registration = $true; filesystem = $true; boot = $true; identity = $true; servicesIsolated = $true }
        }
    }
    It 'does not accept a fresh unverified full-size image' {
        $result = Invoke-WslProbe -Executable (Get-Process -Id $PID).Path -Arguments @('-NoProfile', '-NonInteractive', '-File', $script:HealthScript, '-SnapshotDir', $script:HealthDirectory)
        $result.ExitCode | Should -Be 1
    }
    It 'accepts a current verified recovery' {
        $script:HealthEvidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:HealthProof
        $null = Confirm-WslBackupArtifact -ArtifactPath $script:HealthArtifact -Distro Ubuntu -RestoreEvidencePath $script:HealthProof
        $result = Invoke-WslProbe -Executable (Get-Process -Id $PID).Path -Arguments @('-NoProfile', '-NonInteractive', '-File', $script:HealthScript, '-SnapshotDir', $script:HealthDirectory)
        $result.ExitCode | Should -Be 0
    }
    It 'does not let a newer failed export hide stale recovery' {
        $script:HealthEvidence.verifiedAt = [DateTimeOffset]::UtcNow.AddDays(-30).ToString('o')
        $script:HealthEvidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:HealthProof
        $null = Confirm-WslBackupArtifact -ArtifactPath $script:HealthArtifact -Distro Ubuntu -RestoreEvidencePath $script:HealthProof
        [IO.File]::WriteAllText((Join-Path $script:HealthDirectory 'Ubuntu-new-failed.partial.vhdx'), 'new failed export')
        $result = Invoke-WslProbe -Executable (Get-Process -Id $PID).Path -Arguments @('-NoProfile', '-NonInteractive', '-File', $script:HealthScript, '-SnapshotDir', $script:HealthDirectory)
        $result.ExitCode | Should -Be 2
    }
}

Describe 'Borg readiness and restore-evidence contracts, without a backend' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..' '..' 'powershell' 'Modules' 'RevealUI.RevStation' 'Private' 'Invoke-WslProbe.ps1')
        function Write-RecoveryFixtureJson($Path, $Value) {
            [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        function Get-RecoveryFixtureInventory($Path) {
            $file = Get-Item -LiteralPath $Path
            $mode = if ($IsWindows) { 420 } else { [int][IO.File]::GetUnixFileMode($Path) }
            return [ordered]@{
                schemaVersion = 1; complete = $true; entries = @([ordered]@{
                    path = 'payload'; type = 'file'; uid = 1000; gid = 1000; mode = $mode
                    mtimeNs = ([DateTimeOffset]$file.LastWriteTimeUtc).ToUnixTimeMilliseconds() * 1000000L
                    atimeNs = 0L
                    contentSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
                    linkTarget = ''; hardlinkGroup = ''; aclSha256 = 'a' * 64; xattrsSha256 = 'b' * 64
                    flags = 0; sparse = $false; deviceMajor = 0; deviceMinor = 0
                })
            }
        }
        function Save-RecoveryFixtureInputs {
            $script:ConfigHash = Write-RecoveryFixtureJson $script:ConfigPath $script:Config
            $script:Observation.configurationSha256 = $script:ConfigHash
            $script:ObservationHash = Write-RecoveryFixtureJson $script:ObservationPath $script:Observation
            $script:Attempt.configurationSha256 = $script:ConfigHash
            $script:Attempt.observationSha256 = $script:ObservationHash
            $script:Attempt.transactionId = $script:Observation.transactionId
            $null = Write-RecoveryFixtureJson $script:AttemptPath $script:Attempt
        }
        function Read-FixtureReadiness {
            Get-WslBorgReadinessPlan -ConfigurationPath $script:ConfigPath -ObservationPath $script:ObservationPath -ReviewedConfigurationSha256 $script:ConfigHash
        }
        function Register-FixtureArchive {
            $record = Register-WslBorgArchiveEvidence -ConfigurationPath $script:ConfigPath -ObservationPath $script:ObservationPath -ReviewedConfigurationSha256 $script:ConfigHash -AttemptPath $script:AttemptPath -JournalDirectory $script:Journal
            $script:RestoreObservation = [ordered]@{
                schemaVersion = 1; scope = 'bounded-fixture'
                archiveEvidenceSha256 = (Get-FileHash $record.EvidencePath).Hash.ToLowerInvariant()
                repositoryId = $script:Config.repository.id; archiveId = $script:Attempt.archiveId
                toolSha256 = $script:Config.tool.sha256; keyRecoveryDrillSha256 = $script:Config.keyRecovery.drillSha256
                sourceUnavailable = $true; originalPreserved = $true
                target = @{ path = '/fixture/independent-restore'; physicalDeviceId = 'restore-hardware'; filesystemUuid = 'restore-filesystem' }
            }
            $null = Write-RecoveryFixtureJson $script:RestoreObservationPath $script:RestoreObservation
            return $record
        }
    }
    BeforeEach {
        $script:Fixture = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:Fixture
        if (-not $IsWindows) { [IO.File]::SetUnixFileMode($script:Fixture, [IO.UnixFileMode]448) }
        $script:Journal = Join-Path $script:Fixture 'journal'
        $null = New-Item -ItemType Directory -Path $script:Journal
        if (-not $IsWindows) { [IO.File]::SetUnixFileMode($script:Journal, [IO.UnixFileMode]448) }
        $script:Original = Join-Path $script:Fixture 'last-good.vhdx'
        [IO.File]::WriteAllText($script:Original, 'protected fixture original')
        $script:OriginalHash = (Get-FileHash $script:Original).Hash.ToLowerInvariant()
        $script:Payload = Join-Path $script:Fixture 'payload'
        $script:RestoredPayload = Join-Path $script:Fixture 'restored-payload'
        [IO.File]::WriteAllText($script:Payload, 'real bounded fixture data')
        [IO.File]::SetLastWriteTimeUtc($script:Payload, [DateTime]::new(2020, 1, 1, 0, 0, 0, [DateTimeKind]::Utc))
        [IO.File]::Copy($script:Payload, $script:RestoredPayload)
        $script:SourceInventory = Join-Path $script:Fixture 'source-inventory.json'
        $script:RestoredInventory = Join-Path $script:Fixture 'restored-inventory.json'
        $inventoryHash = Write-RecoveryFixtureJson $script:SourceInventory (Get-RecoveryFixtureInventory $script:Payload)
        $null = Write-RecoveryFixtureJson $script:RestoredInventory (Get-RecoveryFixtureInventory $script:RestoredPayload)
        $script:ConfigPath = Join-Path $script:Fixture 'configuration.json'
        $script:ObservationPath = Join-Path $script:Fixture 'observation.json'
        $script:AttemptPath = Join-Path $script:Fixture 'attempt.json'
        $script:RestoreObservationPath = Join-Path $script:Fixture 'restore-observation.json'
        $script:Config = [ordered]@{
            schemaVersion = 1; backend = 'borg-1.4.5'
            tool = @{ path = '/reviewed/tool/borg'; version = '1.4.5'; sha256 = '1' * 64; provenanceSha256 = '2' * 64 }
            source = @{ distro = 'Ubuntu'; vhdx = (Join-Path $script:Fixture 'source.vhdx'); view = '/fixture/offline-view'; filesystemUuid = 'source-filesystem'; physicalDeviceId = 'source-hardware'; inventorySha256 = $inventoryHash }
            repository = @{ path = '/fixture/repository'; id = '3' * 64; physicalDeviceId = 'repository-hardware'; partitionUuid = 'partition'; filesystemUuid = 'repository-filesystem'; identitySha256 = '4' * 64; encryption = 'repokey-blake2' }
            keyRecovery = @{ reference = 'vault-reference-placeholder'; drillSha256 = '5' * 64 }
            original = @{ path = $script:Original; sha256 = $script:OriginalHash; bytes = (Get-Item $script:Original).Length; physicalDeviceId = 'original-hardware' }
            budget = @{ logicalBytes = 604949360640L; metadataUpperBoundBytes = 1GB; reserveBytes = 64GB }
        }
        $script:Observation = [ordered]@{
            schemaVersion = 1; configurationSha256 = ''; capturedAt = [DateTimeOffset]::UtcNow.ToString('o'); transactionId = [Guid]::NewGuid().ToString('D')
            tool = $script:Config.tool.Clone(); source = $script:Config.source.Clone(); repository = $script:Config.repository.Clone()
            keyRecovery = $script:Config.keyRecovery.Clone(); original = $script:Config.original.Clone()
        }
        $script:Observation.tool.Remove('path')
        $script:Observation.source.Remove('distro')
        $script:Observation.source.state = 'Stopped'; $script:Observation.source.readOnly = $true
        $script:Observation.source.clean = $true; $script:Observation.source.exclusiveLease = $true
        $script:Observation.source.leaseId = 'fixture-only-lease'; $script:Observation.source.inventoryComplete = $true
        $script:Observation.source.producerExitCode = 0; $script:Observation.source.readErrors = 0
        $script:Observation.repository.private = $true; $script:Observation.repository.availableBytes = 943636373504L
        $script:Observation.keyRecovery.sourceUnavailable = $true
        $script:Observation.original.Remove('physicalDeviceId'); $script:Observation.original.readOnly = $true
        $script:Attempt = [ordered]@{
            schemaVersion = 1; kind = 'revealfleet-wsl-borg-attempt-v1'; configurationSha256 = ''; observationSha256 = ''; transactionId = ''
            repositoryId = $script:Config.repository.id; archiveId = '6' * 64
            sourceInventoryBefore = $inventoryHash; sourceInventoryAfter = $inventoryHash
            originalSha256Before = $script:OriginalHash; originalSha256After = $script:OriginalHash
            sourceLeaseId = 'fixture-only-lease'; sourceLeaseHeldThroughout = $true; repositoryLockHeldThroughout = $true
            steps = @('create', 'check-verify-data', 'extract-dry-run') | ForEach-Object { @{ name = $_; exitCode = 0; warningCount = 0; complete = $true } }
        }
        Save-RecoveryFixtureInputs
    }
    It 'never grants execution, even for internally consistent operator data' {
        $plan = Read-FixtureReadiness
        $plan.InputBindingsValid | Should -BeTrue
        $plan.CanExecute | Should -BeFalse
        $plan.BackendExecuted | Should -BeFalse
        $plan.FullRestoreAccepted | Should -BeFalse
        $plan.Capacity.DeduplicationCreditBytes | Should -Be 0
    }
    It 'keeps E and C capacity refused without assuming compression or deleting originals' {
        foreach ($free in @(271653101568L, 238336782336L)) {
            $script:Observation.repository.availableBytes = $free; Save-RecoveryFixtureInputs
            $plan = Read-FixtureReadiness
            $plan.InputBindingsValid | Should -BeFalse
            $plan.Capacity.CanStageArchive | Should -BeFalse
            $plan.Capacity.ReclaimOriginalBytes | Should -Be 0
        }
        (Get-FileHash $script:Original).Hash.ToLowerInvariant() | Should -Be $script:OriginalHash
        { Get-WslBorgCapacityPlan -LogicalBytes 1 -MetadataUpperBoundBytes 1 -AvailableBytes 100 -ReserveBytes 0 } | Should -Throw
        (Get-WslBorgCapacityPlan -LogicalBytes ([long]::MaxValue) -MetadataUpperBoundBytes ([long]::MaxValue) -AvailableBytes ([long]::MaxValue)).CanStageArchive | Should -BeFalse
    }
    It 'rejects active, stale, incomplete, failed-producer and changed tool observations' {
        foreach ($change in @('active', 'stale', 'incomplete', 'producer', 'tool', 'key', 'original', 'boolean-string')) {
            $saved = $script:Observation | ConvertTo-Json -Depth 20
            switch ($change) {
                active { $script:Observation.source.state = 'Running' }
                stale { $script:Observation.capturedAt = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('o') }
                incomplete { $script:Observation.source.inventoryComplete = $false }
                producer { $script:Observation.source.producerExitCode = 1 }
                tool { $script:Observation.tool.sha256 = 'f' * 64 }
                key { $script:Observation.keyRecovery.sourceUnavailable = $false }
                original { $script:Observation.original.sha256 = 'f' * 64 }
                boolean-string { $script:Observation.source.readOnly = 'true' }
            }
            Save-RecoveryFixtureInputs
            (Read-FixtureReadiness).InputBindingsValid | Should -BeFalse
            { Register-FixtureArchive } | Should -Throw
            @(Get-ChildItem $script:Journal -Force).Count | Should -Be 0
            $script:Observation = $saved | ConvertFrom-Json -AsHashtable
        }
    }
    It 'rejects config drift, duplicate JSON keys, aliases and shared destination hardware' {
        [IO.File]::AppendAllText($script:ConfigPath, ' ')
        { Read-FixtureReadiness } | Should -Throw
        Save-RecoveryFixtureInputs
        $script:Config.repository.physicalDeviceId = 'SOURCE-HARDWARE'; Save-RecoveryFixtureInputs
        { Read-FixtureReadiness } | Should -Throw
        $script:Config.repository.physicalDeviceId = 'repository-hardware'; $script:Config.repository.path = '/fixture/offline-view/hidden-repository'; Save-RecoveryFixtureInputs
        { Read-FixtureReadiness } | Should -Throw
        { Get-WslRecoveryPathKey '/fixture/../ambiguous' } | Should -Throw
        [IO.File]::WriteAllText($script:ConfigPath, '{"schemaVersion":1,"schemaVersion":2}')
        { Read-WslRecoveryDocument $script:ConfigPath } | Should -Throw
    }
    It 'serializes evidence writers without breaking locks or overwriting a transaction' {
        $lock = [IO.File]::Open((Join-Path $script:Journal '.wsl-recovery-evidence.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { { Register-FixtureArchive } | Should -Throw } finally { $lock.Dispose() }
        $record = Register-FixtureArchive
        $before = (Get-FileHash $record.EvidencePath).Hash
        { Register-FixtureArchive } | Should -Throw
        (Get-FileHash $record.EvidencePath).Hash | Should -Be $before
        $record.Verified | Should -BeFalse
        $record.FullRestoreAccepted | Should -BeFalse
        $record.RetentionApplied | Should -BeFalse
        @((Get-WslVerifiedBackups -Directory $script:Journal -Distro Ubuntu)).Count | Should -Be 0
    }
    It 'retains failures and last-good data for warning, partial, unlocked or drifting archive results' {
        foreach ($failure in @('warning', 'partial', 'lock', 'inventory', 'original')) {
            $saved = $script:Attempt | ConvertTo-Json -Depth 20
            $script:Observation.transactionId = [Guid]::NewGuid().ToString('D')
            switch ($failure) {
                warning { $script:Attempt.steps[0].exitCode = 1; $script:Attempt.steps[0].warningCount = 1 }
                partial { $script:Attempt.steps[1].complete = $false }
                lock { $script:Attempt.repositoryLockHeldThroughout = $false }
                inventory { $script:Attempt.sourceInventoryAfter = 'f' * 64 }
                original { $script:Attempt.originalSha256After = 'f' * 64 }
            }
            Save-RecoveryFixtureInputs
            { Register-FixtureArchive } | Should -Throw
            Test-Path (Join-Path $script:Journal ($script:Observation.transactionId + '.failed.json')) | Should -BeTrue
            Test-Path (Join-Path $script:Journal ($script:Observation.transactionId + '.archive-evidence.json')) | Should -BeFalse
            (Get-FileHash $script:Original).Hash.ToLowerInvariant() | Should -Be $script:OriginalHash
            $script:Attempt = $saved | ConvertFrom-Json -AsHashtable
        }
    }
    It 'compares actual small-file content and declared metadata without claiming a Borg round trip' {
        $record = Register-FixtureArchive
        $result = Test-WslBorgRestoreInventory -ArchiveEvidencePath $record.EvidencePath -SourceInventoryPath $script:SourceInventory -RestoredInventoryPath $script:RestoredInventory -RestoreObservationPath $script:RestoreObservationPath
        $result.InventoryComparisonPassed | Should -BeTrue
        $result.FullRestoreAccepted | Should -BeFalse
        [IO.File]::WriteAllText($script:RestoredPayload, 'changed restored bytes')
        [IO.File]::SetLastWriteTimeUtc($script:RestoredPayload, (Get-Item $script:Payload).LastWriteTimeUtc)
        $null = Write-RecoveryFixtureJson $script:RestoredInventory (Get-RecoveryFixtureInventory $script:RestoredPayload)
        { Test-WslBorgRestoreInventory -ArchiveEvidencePath $record.EvidencePath -SourceInventoryPath $script:SourceInventory -RestoredInventoryPath $script:RestoredInventory -RestoreObservationPath $script:RestoreObservationPath } | Should -Throw
    }
    It 'rejects a configuration change while its pending journal record is being written' {
        $script:OriginalEvidenceWriter = (Get-Command Write-WslBackupJsonNew).ScriptBlock
        Mock Write-WslBackupJsonNew {
            param($Path, $Value)
            & $script:OriginalEvidenceWriter -Path $Path -Value $Value
            if ($Path.EndsWith('.pending.json')) { [IO.File]::AppendAllText($script:ConfigPath, ' ') }
        }
        { Register-FixtureArchive } | Should -Throw
        Test-Path (Join-Path $script:Journal ($script:Observation.transactionId + '.archive-evidence.json')) | Should -BeFalse
        Test-Path (Join-Path $script:Journal ($script:Observation.transactionId + '.failed.json')) | Should -BeTrue
        (Get-FileHash $script:Original).Hash.ToLowerInvariant() | Should -Be $script:OriginalHash
    }
    It 'compares case-distinct Linux inventory paths without collapsing them' {
        $inventory = Get-RecoveryFixtureInventory $script:Payload
        $first = $inventory.entries[0] | ConvertTo-Json | ConvertFrom-Json -AsHashtable
        $second = $first | ConvertTo-Json | ConvertFrom-Json -AsHashtable
        $first.path = 'A'; $second.path = 'a'; $second.mode = 384
        $inventory.entries = @($first, $second)
        $digest = Write-RecoveryFixtureJson $script:SourceInventory $inventory
        $null = Write-RecoveryFixtureJson $script:RestoredInventory $inventory
        $script:Config.source.inventorySha256 = $digest; $script:Observation.source.inventorySha256 = $digest
        $script:Attempt.sourceInventoryBefore = $digest; $script:Attempt.sourceInventoryAfter = $digest
        Save-RecoveryFixtureInputs
        $record = Register-FixtureArchive
        (Test-WslBorgRestoreInventory -ArchiveEvidencePath $record.EvidencePath -SourceInventoryPath $script:SourceInventory -RestoredInventoryPath $script:RestoredInventory -RestoreObservationPath $script:RestoreObservationPath).Entries | Should -Be 2
    }
    It 'refuses a same-device restore, wrong archive or source-dependent key recovery' {
        $record = Register-FixtureArchive
        foreach ($change in @('device', 'archive', 'source', 'original', 'scope')) {
            $saved = $script:RestoreObservation | ConvertTo-Json -Depth 10
            switch ($change) {
                device { $script:RestoreObservation.target.physicalDeviceId = 'REPOSITORY-HARDWARE' }
                archive { $script:RestoreObservation.archiveId = 'f' * 64 }
                source { $script:RestoreObservation.sourceUnavailable = $false }
                original { $script:RestoreObservation.originalPreserved = $false }
                scope { $script:RestoreObservation.scope = 'full-production-restore' }
            }
            $null = Write-RecoveryFixtureJson $script:RestoreObservationPath $script:RestoreObservation
            { Test-WslBorgRestoreInventory -ArchiveEvidencePath $record.EvidencePath -SourceInventoryPath $script:SourceInventory -RestoredInventoryPath $script:RestoredInventory -RestoreObservationPath $script:RestoreObservationPath } | Should -Throw
            $script:RestoreObservation = $saved | ConvertFrom-Json -AsHashtable
        }
    }
    It 'rejects ownership, modes, ACL/xattr, hardlink, flag, sparse and path coverage drift' {
        $record = Register-FixtureArchive
        foreach ($field in @('uid', 'gid', 'mode', 'mtimeNs', 'atimeNs', 'deviceMajor', 'deviceMinor', 'aclSha256', 'xattrsSha256', 'hardlinkGroup', 'linkTarget', 'flags', 'sparse', 'path')) {
            $inventory = Get-RecoveryFixtureInventory $script:RestoredPayload
            switch ($field) {
                { $_ -in @('uid', 'gid', 'mode', 'mtimeNs', 'atimeNs', 'deviceMajor', 'deviceMinor', 'flags') } { $inventory.entries[0][$field]++ }
                { $_ -in @('aclSha256', 'xattrsSha256') } { $inventory.entries[0][$field] = 'f' * 64 }
                sparse { $inventory.entries[0][$field] = $true }
                default { $inventory.entries[0][$field] = 'different' }
            }
            $null = Write-RecoveryFixtureJson $script:RestoredInventory $inventory
            { Test-WslBorgRestoreInventory -ArchiveEvidencePath $record.EvidencePath -SourceInventoryPath $script:SourceInventory -RestoredInventoryPath $script:RestoredInventory -RestoreObservationPath $script:RestoreObservationPath } | Should -Throw
        }
    }
    It 'keeps the existing adapter read-only with missing approval and refuses Execute' {
        $wrapper = Join-Path $PSScriptRoot '..' '..' 'scripts' 'weekly-wsl-backup.ps1'
        $result = Invoke-WslProbe -Executable (Get-Process -Id $PID).Path -Arguments @('-NoProfile', '-NonInteractive', '-File', $wrapper, '-RecoveryBackend', 'borg-readiness')
        $result.ExitCode | Should -Be 3
        ($result.Output -join "`n" | ConvertFrom-Json).CanExecute | Should -BeFalse
        $complete = Invoke-WslProbe -Executable (Get-Process -Id $PID).Path -Arguments @('-NoProfile', '-NonInteractive', '-File', $wrapper, '-RecoveryBackend', 'borg-readiness', '-IncrementalConfigurationPath', $script:ConfigPath, '-IncrementalObservationPath', $script:ObservationPath, '-ReviewedConfigurationSha256', $script:ConfigHash)
        $complete.ExitCode | Should -Be 3
        $data = ($complete.Output -join [Environment]::NewLine) | ConvertFrom-Json
        $data.InputBindingsValid | Should -BeTrue
        $data.CanExecute | Should -BeFalse
        $mixed = Invoke-WslProbe -Executable (Get-Process -Id $PID).Path -Arguments @('-NoProfile', '-NonInteractive', '-File', $wrapper, '-IncrementalConfigurationPath', $script:ConfigPath)
        $mixed.ExitCode | Should -Not -Be 0
        $execute = Invoke-WslProbe -Executable (Get-Process -Id $PID).Path -Arguments @('-NoProfile', '-NonInteractive', '-File', $wrapper, '-RecoveryBackend', 'borg-readiness', '-Execute')
        $execute.ExitCode | Should -Not -Be 0
        (Get-FileHash $script:Original).Hash.ToLowerInvariant() | Should -Be $script:OriginalHash
    }
}

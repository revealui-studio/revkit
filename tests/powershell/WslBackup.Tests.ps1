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

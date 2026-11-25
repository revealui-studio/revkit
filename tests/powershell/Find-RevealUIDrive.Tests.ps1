#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:ModuleRoot = Join-Path $script:RepoRoot 'powershell' 'Modules' 'RevealUI.RevStation'
    Import-Module (Join-Path $script:ModuleRoot 'RevealUI.RevStation.psd1') -Force 6> $null

    Mock Get-SavedRevkitRoot { $null } -ModuleName RevealUI.RevStation

    # Build a fake .revealui structure that contains the marker file the function looks for.
    $script:Marker = Join-Path 'powershell' 'Modules' 'RevealUI.RevStation' 'RevealUI.RevStation.psd1'
    $script:FakeRoot = Join-Path ([IO.Path]::GetTempPath()) "revkit-test-$([Guid]::NewGuid())"
    $fakeMarkerDir = Join-Path $script:FakeRoot 'powershell' 'Modules' 'RevealUI.RevStation'
    New-Item -ItemType Directory -Path $fakeMarkerDir -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $fakeMarkerDir 'RevealUI.RevStation.psd1') -Force | Out-Null

    # Save original env so we can restore it
    $script:OrigRoot = $env:REVEALUI_ROOT
    $script:OrigUserProfile = $env:USERPROFILE
}

AfterAll {
    Remove-Item -Recurse -Force $script:FakeRoot -ErrorAction SilentlyContinue
    Remove-Module RevealUI.RevStation -Force -ErrorAction SilentlyContinue

    if ($null -ne $script:OrigRoot) { $env:REVEALUI_ROOT = $script:OrigRoot } else { Remove-Item Env:REVEALUI_ROOT -ErrorAction SilentlyContinue }
    if ($null -ne $script:OrigUserProfile) { $env:USERPROFILE = $script:OrigUserProfile } else { Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue }
}

Describe 'Find-RevealUIDrive (Layer 1 — env var)' {
    It 'returns the REVEALUI_ROOT path when set and marker exists' {
        $env:REVEALUI_ROOT = $script:FakeRoot
        Find-RevealUIDrive | Should -Be $script:FakeRoot
    }
}

Describe 'Find-RevealUIDrive (Layer 2 — USERPROFILE fallback)' {
    BeforeEach {
        Remove-Item Env:REVEALUI_ROOT -ErrorAction SilentlyContinue
    }

    It 'returns USERPROFILE/.revealui when that contains the marker' {
        # Build a USERPROFILE such that USERPROFILE/.revealui = a dir with the marker.
        $userP = Join-Path ([IO.Path]::GetTempPath()) "revkit-userp-$([Guid]::NewGuid())"
        $userRevealui = Join-Path $userP '.revealui'
        $userMarkerDir = Join-Path $userRevealui 'powershell' 'Modules' 'RevealUI.RevStation'
        New-Item -ItemType Directory -Path $userMarkerDir -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $userMarkerDir 'RevealUI.RevStation.psd1') -Force | Out-Null

        $env:USERPROFILE = $userP
        try {
            $result = Find-RevealUIDrive
            $result | Should -Be $userRevealui
        } finally {
            Remove-Item -Recurse -Force $userP -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Find-RevealUIDrive configured artifact ownership' {
    It 'uses the persisted artifact root even when the process omitted its variable' {
        Mock Get-SavedRevkitRoot { $script:FakeRoot } -ModuleName RevealUI.RevStation
        $env:REVEALUI_ROOT = 'stale-process-root'
        Find-RevealUIDrive | Should -Be $script:FakeRoot
    }
    It 'refuses a missing configured release instead of rediscovering the old checkout' {
        Mock Get-SavedRevkitRoot { 'missing-configured-release' } -ModuleName RevealUI.RevStation
        { Find-RevealUIDrive } | Should -Throw
    }
}

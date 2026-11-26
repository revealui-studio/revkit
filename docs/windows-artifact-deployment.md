# Windows artifact deployment

The explicit `scripts/Deploy-WindowsArtifacts.ps1` adapter plans deployment from
reviewed, committed RevKit source or its verified native package. Its defaults are `E:\AI\windows\revkit` for
maintained artifacts and the existing `E:\AI\windows\gh` for GitHub CLI state.
The adapter does not copy GitHub credentials or change accounts. Code, account
profile and ignore-pattern ownership remain separate.

`bootstrap.ps1 -DeployWindowsArtifacts` routes to this adapter before the legacy
bootstrap flow. It plans by default; `-ApplyWindowsArtifacts` requests deployment.
Calling the adapter directly uses `-Apply`. Neither entry invokes the legacy CFA,
execution-policy or task-activation steps. The existing broad bootstrap route
remains a separate operation and is not used by this migration.

Provide `-IgnorePatternsSource` as a preserved regular file containing the
owner's current global-ignore patterns. The source may be a verified data copy
of the native target of the former Windows link. The adapter preserves bytes;
it never rewrites patterns or uses the live cross-WSL link as the Windows Git
startup dependency. `core.excludesFile` points to the private Windows-local
release data file after successful activation. The old file/link remains.

`-ReconcileFleetLauncher` is an explicit additional profile-adoption boundary.
It removes only the recognized historical WSL launcher definition and its
documentation, plus the recognized import-time default-distribution mutation.
The module exports the canonical `revealfleet` entry point, which launches only
when the owner invokes it. No compatibility alias is installed. Unknown launcher
customizations refuse adoption; unrelated owner functions and preferences stay.
The bootstrap route exposes the same switch and packaged-source manifest pin.
The recognized exported boolean startup guard becomes a script-scoped PID guard,
so a fresh child process cannot inherit a flag that skips its own profile.

The native `scripts/build-windows-artifacts.py` builder packages files from
Git's tracked index after verifying they match committed `HEAD`. It reads the
same `scripts/windows-artifact-scope.json` policy as the Windows adapter.
Windows consumes that package with the independently recorded
`-ExpectedSourceManifestSha256`; each packaged file is rehashed. This avoids
asking Windows Git to interpret Linux worktree linkage or creating a second
Windows source checkout. A native build preserves failed staging artifacts and
never overwrites an existing output package. Direct committed Windows source
checkouts remain supported by the same file selector.
The builder requires atomic no-replace directory publication and probes that
capability before reading Git or staging source. Build on native Linux storage;
DrvFs does not provide this directory operation. The Windows deployment adapter
can read the verified package through the supported WSL UNC share, then copies
it into its independent Windows release. The build directory is temporary
deployment input, never a runtime dependency after release publication.
The selected artifact closure contains maintained scripts, modules, hooks and
Git configuration, excluding machine-local `local-config.ps1`, logs and caches.
The manifest identifies the source commit, each file digest and the ignore-data
digest. Copies are verified in a private staging directory and published as a
content-addressed release only after their bytes match. A failed copy cannot
replace an active release; partial staging and preservation directories remain
available for inspection. Repeated deployment reuses only a matching release.

The account's `.config/shell/profile.ps1` is a deliberate local entry point.
The adapter parses it as PowerShell and replaces only the recognized RevStation
module-loader statement group, or an existing RevKit managed block. Unknown
commands, assignments, method calls or functions inside that group refuse
adoption. Preferences, credential references, aliases and commands outside the
boundary retain their original text. The original profile and installed
standalone module are copied into a private preservation directory before
activation. No SSH key or authentication database is copied or merged.

The generated loader reads the supported persisted `REVEALUI_ROOT` setting and
imports the exact maintained module manifest. Module discovery, elevation and
future scheduled-task commands follow that deployed artifact rather than
searching old checkout locations. Mount-task registration remains S4U/headless
and creates a disabled task. Deployment does not register or enable schedules.
The previous nonsecret user environment settings and Git ignore setting are
recorded next to the preserved originals for rollback. Activation attempts to
restore them on failure and preserves the reviewed release for diagnosis.

## Standalone module behavior

The installed standalone module's `Dismount-WSLDev` and `Get-Secret` definitions
were inspected without retrieving credential values. The maintained module
adopts scoped safe-eject behavior: verify the configured device and mount,
refuse active consumers, sync, unmount, verify, detach that exact physical disk
and take it offline. It accepts an explicit existing disk number only when it
matches the approved identity. It does not choose an arbitrary USB disk or stop
unrelated PostgreSQL, Redis or inference services. Service quiescence belongs
to those services' maintained owners.

The original standalone module remains preserved. Its `Get-Secret` parameters
differ from the maintained explicit output-mode API; the controller must verify
actual shell consumers before retiring that original. Credential values and
Windows/native identities remain separate throughout this source deployment.
The maintained bridge delegates store selection to the existing native RevVault
client configuration. `REVEALUI_ROOT` selects code only; no artifact-relative
vault store is created or forwarded. The opaque entry name remains the only
projected value, and plaintext/SecureString output still requires explicit mode
selection. No environment-export capability is added by this repair.

## Zed and remaining acceptance

The maintained Zed template already uses registry ACP agents. Its local custom
agent and model, trust, credential and WSL connection settings are outside this
adapter's write set. The installed custom command references
`zed-acp-agent.sh`, while that launcher is absent from the canonical product
source. Replacing only its old root or Node pin cannot repair it. The durable
next action is to establish the intended product-owned ACP launcher and test
its registry/launcher contract, or obtain the owner's explicit retirement of
that local customization. No template overwrite or alternate launcher is
introduced here.

Cross-platform tests cover profile-boundary adoption, preservation and refusal,
configured artifact ownership, and safe-eject refusal paths. Windows-specific
ACL enforcement, release deployment, profile/module loading, GitHub CLI account
preservation, ignore behavior and actual dismount remain controller acceptance
checks. A generated plan or passing synthetic test does not establish runtime
adoption.

Private artifact directory reconciliation writes only the reviewed DACL through
.NET's modified-section persistence API. It never reads or writes audit entries
or changes owner/group. Applying the same policy to an existing protected root
is idempotent and requires no security-audit privilege. Native Windows regression
coverage includes repeated application, exact three-principal FullControl rules,
protection/inheritance and unchanged owner/group; Linux skips that platform case.

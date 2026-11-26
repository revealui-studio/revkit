# Windows recovery maintenance

RevKit owns the backup validity, capacity and device identity primitives. The
Windows operator controls deployment, cold shutdown, recovery registration,
restoration validation and schedule activation. None of these source changes
moves a disk, starts a distribution or enables a task by itself.

## Full images and capacity

`weekly-wsl-backup.ps1` plans by default. `-Execute` requires the registered
source distribution already stopped and a private, existing destination. It
resolves the source VHD from the WSL registration, keeps a Windows power request
for the export and serializes writers to the destination. It never terminates
other distributions. Failed exports remain as `.partial.vhdx` files.

The shared planner reserves the existing recovery. It never counts that image
as reclaimable space before a new recovery passes validation. New exports use
Microsoft's supported `wsl --export --vhd` format and remain `.pending.json`
artifacts. A nonzero export, a missing output, or incomplete verification cannot
rotate a previous recovery.

A store with 943,636,373,504 available bytes can accept one full image of roughly
634 GB. It cannot safely stage its next full replacement while retaining the
first. The planner refuses that next export. Reducing retention to one does not
solve the replacement-capacity problem. The weekly task is registered disabled.
Recurring recovery acceptance still needs sufficient independent staging or an
approved incremental/deduplicated backup design, plus independent recovery-key
access and a verified restore. The maintained incremental design now selects Linux Borg 1.4.5 offline
filesystem archives, superseding the earlier Restic VHD/file-stream assessment.
This is a source design selection, not deployment or permission to initialize
storage. [Recurring recovery design](wsl-recurring-recovery-design.md) records the
metadata, consistency, key recovery and separate restore-capacity rationale.
Preserve existing images and secondary-disk data; neither tool is installed
system-wide. A separately invoked private synthetic Borg fixture is available
under the maintained design; it installs nothing globally.

## Explicit cold-container source increment

The separate `borg-container-readiness` entry plans whole stopped-VHD byte custody,
with full dense-image/overhead/cache/reserve budgets and CanExecute=false. Its
Execute switch refuses before opening a source or worker. See the maintained
[profile, synthetic evidence and staged Windows tests](wsl-recurring-recovery-design.md#separate-cold-opaque-vhd-profile-readiness-and-synthetic-transport-only).
This does not reinterpret the rejected filesystem sparse profile or activate a
production worker. Native binary tests are not actual Windows/WSL acceptance.

## Incremental readiness and evidence only

The existing wrapper accepts `-RecoveryBackend borg-readiness` with optional
`-IncrementalConfigurationPath`, `-IncrementalObservationPath` and
`-ReviewedConfigurationSha256`. It reports missing inputs or evaluates exact
version-1 bindings through WslBackup.ps1, exits 3, and always refuses `-Execute`.
It does not inspect the registry or invoke WSL/Borg in this mode. The existing
full-image default and capacity refusal remain unchanged; mixed-mode inputs
refuse rather than falling back to a full export.

The owning library adds conservative no-dedup-credit capacity evaluation,
read-only input contracts, private evidence-journal transactions and bounded
restore-inventory comparison. None creates a repository, key or real archive.
Operator-supplied attempt records remain explicitly unverified and cannot enter
the existing verified-image inventory. The native fixture has recorded
actual Borg1.4.5 ext4 observations. The controller accepted the legacy-profile
synthetic privileged cases and a separate ordinary synthetic encrypted-key drill;
neither is combined candidate/full recovery acceptance. The explicitly named
fixed64KiB candidate now rejects dense-zero allocation changes under the unchanged
sparse contract; see the maintained design for source plan, evidence and required
allocation-policy follow-up. Independent key custody and full WSL restore remain missing. The
controller alone owns real destination/maintenance approval and later deployment;
the PR changes future source payloads, not the accepted Windows release. This
native fixture increment does not alter PowerShell modules. There is no automatic retention, repair, compaction or lock breaking.

Run `Invoke-Pester ./tests/powershell/WslBackup.Tests.ps1` for bounded behavioral
fixtures. They cover real small-file hashing, journal contention/duplicates and
failure retention, with modeled metadata observations. They are not a Borg
round-trip or evidence that the detached secondary disk is approved for writes.

Restore observations now distinguish explicit version2 `isolated-restore-test`
from `third-hardware-copy`. A fresh E restore VHD could share source/protected
image hardware while reading the independent1TB backup with the source absent;
this would test restoration but would not add third-hardware redundancy. Legacy
version1 evidence keeps its strict disjoint-hardware rule. No profile accepts a
target on backup-repository hardware, reuses the source filesystem/VHD, or grants
full restore acceptance from bounded inventory data. Freeing E does not meet a
third-hardware guarantee. Conditional capacity and USB-port constraints remain
in the [canonical design](wsl-recurring-recovery-design.md).

## Verified artifact contract

`New-WslRestoreEvidence.ps1` probes an already running, separately registered
recovery. It never imports, boots, terminates or unregisters a
distribution. The source must already be stopped. The recovery must use an
isolated maintenance boot without systemd, have only approved maintenance
processes, and expose the expected Ubuntu release, user identity, home,
repository and ext4 root. This is a restoration test of the snapshot's data and
maintenance boot; it does not establish normal production service startup.
The immutable backup artifact is hashed before and after probing. The operator
must arrange the recovery registration and isolation before invoking this
verifier; that preparation is outside this command. A separate restored copy is
supported. Existing import-in-place recovery validation is also supported only
when the artifact is already protected read-only and its before/after hashes
remain equal. Sharing the live source VHD always refuses.

The generated proof records its protocol and source digest, observed recovery
identity and checks, and the artifact SHA256 and byte length.
`Confirm-WslBackupArtifact.ps1` validates those fields and independently hashes
the artifact before creating `.restore.json` and `.verified.json` files. It
refuses unbound hashes, changed artifacts, incomplete observations, unsupported
layouts, an unprotected in-place verification, and a recovery
registration equal to the source. Metadata is never overwritten. These are
trusted local operator records, not remotely authenticated attestations; deploy
artifacts, evidence and metadata with private owner/SYSTEM/Administrators access.

Retention is an explicit `-Prune` action. Only older, independently verified
images are eligible, and the new image must be the newest verified recovery.
Unknown files, unverified exports and partial images are preserved. Their
cleanup needs a separate disposition. `check-backup-staleness.ps1` consumes this
same validity contract. Routine monitoring checks artifact identity metadata and
the restoration-proof digest; `-VerifyContent` additionally rehashes every image.
A routine monitor result must not be described as a newly computed image hash.

## Exact device identity and readiness

`Test-WslDiskIdentity.ps1` verifies an already attached disk. It selects Windows
hardware by configured exact serial, model and size, then requires the approved
USB/GPT partition UUID, offset and length. It invokes the maintained read-only
Python probe through an explicit Windows/root command, without adding sudo
permissions. Windows and Linux configurations must agree.

The root-owned Linux deployment is
`/usr/local/lib/revealfleet/wsl-disk-identity.py`; the identity configuration is
an explicitly chosen root-owned file, passed as `-LinuxIdentityPath`. Deployment
is a controller/provisioning step, not an implicit action of the verifier. The
JSON schema has exactly these fields:

```json
{
  "schemaVersion": 1,
  "serial": "approved-hardware-serial",
  "model": "approved-hardware-model",
  "diskBytes": 2097152,
  "partitionBytes": 524288,
  "partitionStartSectors": 2048,
  "partitionSectors": 1024,
  "partitionUuid": "00000000-0000-0000-0000-000000000001",
  "filesystemUuid": "00000000-0000-0000-0000-000000000002",
  "filesystemLabel": "revealfleet-data",
  "mountPoint": "/mnt/approved-data"
}
```

The Python helper waits at most 30 seconds for the exact device geometry, then
revalidates GPT and ext4 UUID/label. It reports exactly `MOUNTED` or
`NOT_MOUNTED`, verifying any existing mount belongs to the same block device.
It never attaches, mounts, changes block read-only flags or writes a journal.
The Windows wrapper reserves a 25-second Linux budget inside a 30-second process
budget. The operator must use the existing approved hardware attachment path.

The existing Sandbox mount command retains its fixed helper and sudo argument
boundary. It requires a configured Windows hardware/GPT identity and verifies
that the root-owned Linux Sandbox configuration agrees before attachment. The
privileged helper itself validates root ownership, safe permissions and exact
GPT/filesystem identity, mounts the verified partition, then revalidates the
mounted filesystem. An existing mount also passes that identity/marker gate.
No configured identity means refusal with the provisioning action. Success
markers are exact, child probes have deadlines, and the command no longer
detaches an existing attachment before retrying. The separate data
disk is not silently relabeled or routed through the Sandbox helper. Retire the
installed legacy mount script only after the controller deploys and validates
the maintained owner; a substring log entry is not mount evidence.

## WSL platform prerequisite

`Test-WslPlatformPrerequisites.ps1` reads the supported `wsl --version` output
and requires WSL 3.0.5.0 or newer. `Apply-WslHostFix.ps1` runs the same gate before
its existing setup flow. Version detection does not install updates, launch UAC,
change cgroups or modify distribution registrations. The Ubuntu 26 acceptance
baseline was WSL 3.0.5.0 with kernel 6.18.58.1; a platform-version pass does not
substitute for checking the actual user-manager and service behavior.

## Validation

Cross-platform behavioral tests cover measured capacity refusal, partial
exports, preservation of the last recovery, invalid receipts, exact mount
states, process deadlines, hardware/GPT identity and delayed Linux device
readiness. Actual Windows WSL export, restoration, Task Scheduler registration,
ACL and device behavior remain controller acceptance checks.

References: [WSL supported commands](https://learn.microsoft.com/en-us/windows/wsl/basic-commands)
and the selected [Borg recovery contract](wsl-recurring-recovery-design.md).

## Cold-container hardware and authority follow-up

The operational profile remains `cold-vhd-container-v1`, with independent
`keyfile-blake2-independent-v1` custody. Its signed admission now requires the
expanded identity fields below; an earlier policy/package cannot silently adopt
this runtime. Historical synthetic filesystem rejection and all earlier receipts
remain unchanged. Native tests do not accept Windows or the selected worker.

### Cross-host repository binding

`repository` adds `deviceModel`, `partitionOffsetBytes` and `filesystemLabel` to
its existing exact Windows serial, disk/partition bytes, PARTUUID and ext4 UUID.
Windows uses `Assert-WslDiskHardwareIdentity` to observe one independent USB GPT
disk and its one exact Linux-type partition; it never consumes a guest serial
echo as an observation. Linux reuses `wsl-disk-identity.py` to enumerate the
whole block-device listing, refuse ambiguity, verify the parent size, one GPT
partition's exact offset/length/type/PARTUUID, and `blkid` ext4 UUID/label. Linux
USB SERIAL need not exist. The helper labels serial/model explicitly as configured
Windows claims correlated by geometry. They are not independently observed Linux
USB identifiers. The owner's signature binds both sides of this correlation.

The admitted worker source closure now has FOUR Python files: bootstrap, engine,
admission and `wsl-disk-identity.py`. Every worker custody check repeats the
metadata-only geometry/filesystem probe and verifies the actual mount source,
root, mount ID, block-device identity and kernel DISKSEQ against the initial
observation. Missing DISKSEQ, unmount, ambiguous match, cloned/reused device name,
changed mount ID or re-registration refuses. Ephemeral `/dev` names are observed,
never configured. Root remains trusted against deliberate out-of-band rewriting
of identity and kernel state; this is not cryptographic hardware attestation.

`Test-WslColdHardware.ps1` is a fixed, bounded, noninteractive observer of the
same hash-bound protected policy. `ColdCommitGuard` runs it repeatedly during
custody (one second between bounded observations), and again before K. It checks
Windows repository hardware and all four Windows VHD/target volume identities.
Any observation error cancels the transaction and invokes existing retained-
custody reconciliation. This is a bounded observation interval, not a claim of
an instantaneous Windows USB event lock. Linux DISKSEQ/mount continuity and the
held source/destination handles supply their own continuity checks. The observer
must be in the signed controller file closure along with `WslDiskIdentity.ps1`.
Actual Windows-to-selected-worker substitution/disconnect acceptance remains open.

### MBR and GPT capacity identity

Each Windows `hardware` object now contains exact `serial`, `model`, `diskBytes`,
`partitionStyle`, `diskId`, `logicalSectorBytes`, `physicalSectorBytes`,
`partitionOffsetBytes`, `partitionBytes`, `partitionType`, `volumeUuid` and
`allocationUnitBytes`. For MBR, `diskId` is the positive numeric disk signature
and `partitionType` the numeric MBR type. For GPT, those two fields are canonical
nonempty disk/type UUIDs and `partitionUuid` is additionally required. There is
no dummy GUID or missing-GUID fallback. `Get-WslColdVolumeIdentity` constructs
this object from actual Get-Disk/Get-Partition/Get-Volume observations, and
`Assert-WslColdVolumeObservation` compares every field and type. Capacity domains
use the observed NTFS volume UUID, so aliases share one domain even on MBR.

The source, worker, protected recovery and proposed restore share E hardware.
Only the repository is independent hardware. A fresh E restore remains an
isolated restore test, never a third-hardware recovery copy. Current live image
sizes and approximately 5.89GB provisional headroom before overhead are not cold
capacity acceptance. Runtime, caches/indexes, transaction growth, dense image,
filesystem costs and >=64GiB reserve must all fit without savings credit.

### Protected authority provisioning and C exception

The observed E root grants Everyone DELETE_CHILD and has an unresolved old owner;
its AI ancestors are also writable/user-owned. Protecting a new child DACL cannot
remove an ancestor's deletion authority. The existing code/policy ancestor guard
correctly refuses. No E ACL/owner conversion, broad root change, trust exception
or existing private-package promotion is part of this fix.
[Microsoft's directory rights](https://learn.microsoft.com/en-us/windows/win32/fileio/file-access-rights-constants)
document the parent DELETE_CHILD right. Inherit-only CREATOR OWNER is a template
for a trusted creator, not an effective grant on its parent; the existing guard
continues to distinguish it while rejecting other untrusted grants.

The maintained `Deploy-WindowsArtifacts.ps1 -ColdAuthority` mode prints a plan
through the existing artifact owner. It verifies the exact committed archive
manifest, counts actual bytes and selects a NEW `%ProgramFiles%\RevKitCold`
namespace with a source-addressed release. This small C exception is required by
the current E ancestor trust boundary. It contains public reviewed controller
code and its manifest, not VHDs/repositories/caches or credentials. Exact payload
size belongs to each package receipt. No startup, profile, environment, policy,
task, service or runtime activation is performed by this mode.

After root reviews both the frozen package and plan, the SAME command with
`-Apply` requires Windows elevation, validates every existing ProgramFiles
ancestor, and refuses an existing RevKitCold namespace. It uses exclusive Win32 CreateDirectoryW (existing paths fail) to create the new root
with its administrator-owner/protected descriptor at creation: SYSTEM/Admin full,
Users read/execute, no inheritance. Only NEW descendants are copied and rehashed;
every path is validated. No existing owner/DACL is modified. A failure leaves the
new partial namespace intact and inactive. Rollback scope, only after review and
no running controller, is that exact newly created namespace. There is no
automatic recursive delete or overwrite/repair. Existing user artifact deployment
is a separate mode and keeps its previous private-data ACL semantics.

Authority admission and data privacy remain distinct. This mode DOES NOT prove
that an E journal/dense-target directory satisfies `-PrivateData` ancestor checks.
The recorded E root owner/public mutation grants also prevent that acceptance.
Root must review a narrowly scoped data-custody solution before real E restore;
this source does not weaken b155 or silently move a 640GB target onto C. A future
handle-anchored data namespace would require its own owner implementation and
actual substitution/privacy tests; it is not supplied by an authority hash.

Review-only staging commands (root substitutes the frozen paths/hash):

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File PACKAGE\scripts\Deploy-WindowsArtifacts.ps1 -ColdAuthority -SourceRoot PACKAGE -ExpectedSourceManifestSha256 MANIFEST_SHA256
# Later reviewed creation only; NOT run by native source:
pwsh -NoLogo -NoProfile -NonInteractive -File PACKAGE\scripts\Deploy-WindowsArtifacts.ps1 -ColdAuthority -SourceRoot PACKAGE -ExpectedSourceManifestSha256 MANIFEST_SHA256 -Apply
```

Root must independently verify source signatures and package/installer bytes
BEFORE elevated execution; a self-described manifest is not its own authority.
The plan/apply primitive itself remains actual-Windows unaccepted. Stage changed
`WslColdAdmission.Tests.ps1`, `WindowsArtifactDeployment.Tests.ps1`, and existing
cold transport/worker/disk suites from the SAME Git archive for host acceptance.
No real disk is needed for those synthetic tests. Root must NOT repeat the
completed temporary bare-attachment helper merely to obtain another receipt.

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

## Opt-in volume-root custody transaction (source proposal, Windows acceptance pending)

`Invoke-WslColdVolumeCustody.ps1` now owns an executable Plan/Apply/Rollback path
through `lib/WslColdVolumeCustody.ps1` and the WslBackup native custody primitives.
It does not activate a worker/controller, read any VHD, initialize credentials or
operate on a disk. The proposed scope is exactly OWNER+DACL on one positively
identified **NTFS volume root**, then exclusively created direct-root namespaces.
Existing AI paths, VHDs, files and child/grandchild descriptors are not traversed
or rewritten. Removing parent DELETE_CHILD intentionally removes the root-based
deletion fallback for EXISTING immediate children too. Their direct DACL-derived
grants/templates remain, but effective access is not universally identical.
An existing child with its own DELETE still permits deletion; a protected child
whose only deletion authority was the parent loses that fallback. The plan
explicitly exposes this effect for owner review, and the elevated synthetic
case verifies both controls before/after while comparing the unchanged child ACL. Unchanged old descendants retain their existing public/private
permissions; this is NOT physical-drive-wide privacy or a retrofit of old data.

This replaces the earlier *missing code* boundary with a concrete review target.
It is not acceptance of that target on a real host. Before owner confirmation or
UAC, the controller must review the complete plan and run the new Windows
synthetic and explicitly elevated subsets. No source test authorizes a real ACL
change. Keep ProgramFiles authority provisioning as a separate unactivated
option; useful authority/journal/restore state may live on the selected E volume
only AFTER this transaction and the normal source/file/capacity/lifetime gates
are accepted.

### Descriptor transformation and propagation boundary

**Actual Windows evidence invalidated the proposed SetSecurityInfo contract.**
The documented MAXIMUM_ALLOWED exception did not prevent control-bit changes or,
in the deliberately different-template case, changes to existing child descriptors.
Production `ColdDirectorySecurityLease.Replace` and custody Apply/Rollback now refuse
without mutation. Plan remains read-only review data, never an apply capability.
The previously proposed mutation transaction has been removed, rather than leaving
unreachable code which appears deployable. Exact descriptor/control/group drift
checks and the retained no-delete-share custody handle remain.

[Microsoft SetSecurityInfo](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-setsecurityinfo)
documents propagation and the MAXIMUM_ALLOWED exception. Actual receipts take
precedence over that inference. [Automatic inheritance conversion](https://learn.microsoft.com/en-us/windows/win32/secauthz/automatic-propagation-of-inheritable-aces)
can alter representations/control flags; this is an explanation to investigate,
not permission to normalize a failed exact comparison. Group/SACL/attributes are
not selected for mutation, and SACL bytes are not claimed verified.

The before record retains original descriptor bytes, exact owner SID and raw
DACL bytes, group, DACL-related control flags and a deterministic snapshot SHA256.
Unknown control forms, null DACLs, deny/callback/object/inherited root ACEs,
no-propagate flags, unmapped generic masks and unknown principals refuse. This
initial grammar supports standard allow ACEs for Everyone, CREATOR OWNER,
SYSTEM, Administrators and the exact current user. An unsupported real descriptor
requires source review; there is no automatic normalization or permissive fallback.

The new owner is Administrators. SYSTEM/Admin get root-only full grants. An
outside effective grant retains root-only list/read/traverse/READ_CONTROL/sync
and file+directory creation (mask0x1200af), removing DELETE, DELETE_CHILD,
WRITE_DAC, WRITE_OWNER and unneeded root metadata-write rights. Any inheritable
portion stays as an otherwise unchanged inherit-only template, in its original
template order. CREATOR OWNER stays a generic inherit-only template, even if the
old literal ACE was effective+inheritable. Its child-owner mapping is preserved;
the new concrete Admin owner receives its own effective grant. No blanket Deny
Everyone is added. See [ACE inheritance](https://learn.microsoft.com/en-us/windows/win32/secauthz/ace-inheritance-rules)
and [distinct creation/deletion rights](https://learn.microsoft.com/en-us/windows/win32/fileio/file-access-rights-constants).

Windows tests intentionally alter a child template in a SEPARATE synthetic case:
existing child/grandchild descriptors must stay byte-equivalent, while a NEW
child must receive the altered template. This discriminates actual no-propagation
from a merely equivalent inheritable-rights calculation. The real transformation
also checks unchanged preexisting protected/nonprotected children, owners,
creation/write timestamps, attributes and file hashes; it does not claim an
unmeasured census of all NTFS metadata forms or SACLs.

`Assert-WslColdAclGrants` now treats **all** inherit-only ACEs as ineffective on
an ancestor. The leaf remains strict: untrusted inheritance templates which
could expose future private files refuse. CREATOR OWNER is allowed only under
the existing trusted-creator reasoning: untrusted effective/template leaf writes
are independently rejected. A protected new private directory excludes public
inheritance; an old unprotected public child continues to fail private admission.
Code paths remain admin-owned and unwritable; private data still excludes outside
readers. This is not a general relaxation of leaf privacy or code immutability.

### Reviewed policy and read-only plan

The strict policy has exactly: `schemaVersion:1`, `kind:cold-volume-custody-v1`,
`volumeRoot`, `hardware`, `namespace`, `trustedUserSid`, `evidenceDirectory`,
`evidenceHardware`, `sourceRoot`, `sourceManifestSha256`,
`namespaceAdditionalBytes`, `evidenceAdditionalBytes`, `reserveBytes`. Hardware objects use the
existing exact MBR/GPT identity contract. `volumeRoot` is one canonical uppercase
local drive root, never a subtree, UNC, extended alias, mountpoint or reparse.
Namespace is a fresh literal name (letters/digits/underscore/hyphen), bounded64;
reserved device names/collisions refuse. No site identity/account is in source. Positive reviewed namespace/evidence
growth allowances and >=64GiB reserve must fit each fresh actual filesystem.
Namespace allowance exceeds full source+manifest bytes; metadata costs are an
explicit reviewed allowance, not a fabricated worst-case bound or savings ratio.
Observed growth/free reserves are rechecked before mutation and before completion;
these are refusal monitors, not filesystem quotas. This small transaction
admission does not accept full backup/restore capacity.

The controller compares the hardware against independent retained evidence, then
supplies actual observations. Plan binds volume/root handle identity, exact
before/after snapshots, Windows user SID, independent evidence handle/descriptor,
complete source closure/manifest, namespace, phase intent and <=1h expiry. The
actual current descriptor is compared again immediately before mutation. The
independently reviewed **saved plan's raw SHA256**, supplied at apply, is authority;
a hash printed in self-described data is not. There is no test flag or unsigned
acceptance boolean. No sampled boolean establishes custody.

Root ACL setters have no kernel compare-and-swap for a descriptor. The retained
handle and fresh checks bind the object, but cannot exclude a concurrent trusted
administrator changing its ACL between comparison and SetSecurityInfo. Controller
review must quiesce other security writers for this short transaction; no claim
is made that a cooperative evidence-file lock blocks arbitrary administrators.
After repair, ordinary callers have no root security mutation/deletion authority.

### Independent evidence, privilege preflight and bootstrap

Apply/Rollback require elevated Windows AND successful scoped SeRestorePrivilege
BEFORE root mutation. The privilege is enabled on a duplicate impersonation
token for the synchronous thread only; an existing impersonation context refuses.
No account/process-wide privilege, security policy or trust setting is changed.
The original thread context is restored. [Microsoft privilege semantics](https://learn.microsoft.com/en-us/windows/win32/secauthz/privilege-constants)
allow an arbitrary valid owner SID with SeRestorePrivilege. The transaction
actually assigns the ORIGINAL SID (including an unresolved SID) to a NEW private
probe and restores it before touching the volume root. Missing privilege, API or
control-flag preservation fails there first, retaining the probe evidence.

Evidence must already be protected/private on separately identified hardware and
filesystem, outside the root being repaired. It is independently reviewed, not
bootstrapped by that unsafe root or a self-described receipt. A single held file
lock serializes this owner at that evidence destination; no lock breaking/deletion.
Each attempt is a NEW UUID. The reviewed plan, exact before and proposed target,
pending record, and owner-preflight records are CreateNew/Flush(true) BEFORE the
real root change. Actual after/completion or best-effort failure snapshots follow.
An evidence write failure prevents progression; attempts and partial namespaces
are never automatically deleted or hidden as success.

Apply requires executing the complete hash-bound package from protected admin
code ancestry. A user-owned E test package cannot bootstrap its own authority.
If no independent protected code/evidence anchor exists, the optional maintained
ProgramFiles provisioner can create its NEW reviewed code namespace and a NEW
private `review-evidence` child (SYSTEM/Admin full, current user read/execute).
This is a small explicit bootstrap/audit exception, not a C VHD/repository/cache/
production-state move. Root must review its package-size/ACL plan first; this
source does not install it. After root custody is accepted, the new direct-root
namespace provides useful E authority/data without altering the old AI chain.

### Apply, partial failure and rollback

Apply creates the selected direct-root namespace with an admin-protected public
read/execute descriptor AT exclusive creation. It creates separate `authority`
and `private` children. Authority contains an exact-hash source-addressed code
release, including the package source manifest; the private child grants only
SYSTEM/Admin and the explicit trusted user. Directory and file descriptors are
supplied to exclusive Win32 creation, not patched after public creation. Only
directories created by the current call may be reused while copying the reviewed
closure. Every code file is flushed and rehashed; existing targets/reparse/collision
refuse. Source/file/cold/capacity/lifetime guards still run for later controller
operations. The repair supplies no backup/restore/worker activation capability.

A failed owner/DACL call, exact-control/byte mismatch, namespace collision/copy
failure or evidence error retains all state. It does NOT auto-rollback; that could
overwrite another owner's later edit. Rollback restores ONLY the original root
OWNER+DACL, on the same actual hardware/root, when the current owner/DACL/group/
control snapshot equals the exact planned accepted AFTER state. Later drift or
an unexpected partial descriptor refuses. No created namespace or evidence is
removed or rewritten; reverting the root also reopens its historical ancestor
risk, so new controller admission must refuse until custody is reaccepted.
Do not roll back while any controller depends on that namespace.

After the review expires, `PlanRollback` may emit a NEW rollback-only plan from
the original reviewed record, only if root identity and exact after hash still
match. Review/save/hash that new output independently. It cannot authorize Apply.
No ordinary source permission is missing; actual Windows acceptance and root's
reviewed mutation/outage coordination are the remaining operational prerequisites.

Interfaces (review placeholders, never run by the native source lane):

```powershell
# Plan only; stdout saved as exact JSON, independently reviewed and hashed.
pwsh -NoLogo -NoProfile -NonInteractive -File PACKAGE\scripts\Invoke-WslColdVolumeCustody.ps1 -PolicyPath PRIVATE_POLICY
# BLOCKED: these interfaces refuse until a separately reviewed implementation
# and actual Windows contract acceptance replace the disproved API:
pwsh -NoLogo -NoProfile -NonInteractive -File PROTECTED_PACKAGE\scripts\Invoke-WslColdVolumeCustody.ps1 -Phase Apply -PlanPath REVIEWED_PLAN -ReviewedPlanSha256 EXACT_SHA256
# Root-only descriptor rollback; never adopt later edits or delete namespaces:
pwsh -NoLogo -NoProfile -NonInteractive -File PROTECTED_PACKAGE\scripts\Invoke-WslColdVolumeCustody.ps1 -Phase Rollback -PlanPath REVIEWED_PLAN -ReviewedPlanSha256 EXACT_SHA256
# If stale, obtain NEW rollback-only review data first:
pwsh -NoLogo -NoProfile -NonInteractive -File PROTECTED_PACKAGE\scripts\Invoke-WslColdVolumeCustody.ps1 -Phase PlanRollback -PlanPath ORIGINAL_PLAN -ReviewedPlanSha256 ORIGINAL_SHA256
```

Stage the new `WslColdVolumeCustody.Tests.ps1` AND its tracked `.Fixture.cs`
alongside the same signed package and existing Windows suites. Run a fresh
noninteractive PowerShell. First exclude tag `Elevated` for ordinary synthetic
acceptance; then run `Elevated` in a separately reviewed elevated process. Those
cases transition a synthetic root to Admin, restore an unresolved synthetic SID,
and use a duplicate filtered ordinary token to prove dangerous root access and
protected namespace substitution are denied while real ordinary file/directory
creation works. No account/group is modified. Tests never select a real volume
root; production rejects their private subtree at its public entrypoint. Native
model tests and Windows/elevated skips are explicit evidence gaps, never green
acceptance. SACL auditing and real-volume application are separate unproved facts.

For retained synthetic acceptance, pass `RetainedFixtureParent` to the Pester
container (an existing protected private non-root directory outside Git). Each
NEW UUID tree and its adjacent initial/final nonsecret descriptor/tree receipts
stay there even on failure. No previous fixture is adopted. Omit it only for
ephemeral TestDrive source checks; those do not retain Windows custody evidence.

```powershell
$c = New-PesterConfiguration
$c.Run.Container = New-PesterContainer -Path PACKAGE\tests\powershell\WslColdVolumeCustody.Tests.ps1 -Data @{ RetainedFixtureParent = PRIVATE_SYNTHETIC_PARENT }
$c.Filter.ExcludeTag = @('Elevated')
$c.TestResult.Enabled = $true
$c.TestResult.OutputPath = NEW_ORDINARY_XML
$c.Run.PassThru = $true
Invoke-Pester -Configuration $c
# Separate explicitly elevated process, SAME immutable source and retained parent:
# use $c.Filter.Tag = @('Elevated'); do not set ExcludeTag, use NEW_ELEVATED_XML.
```

The elevated namespace-installation/collision case additionally requires the
retained parent to pass **code-authority** ancestor validation (admin-protected,
not user-owned Temp). It exercises actual exclusive descriptor creation, nested
file copy/hash, public authority/private data guards, partial-copy retention and
root-only rollback without deleting new namespaces. Missing such a separately
reviewed synthetic anchor is an explicit skip/gap. The test calls the owning
inner namespace primitive; it does not bypass production root/hardware admission
or claim real-volume Apply acceptance. Running without RetainedFixtureParent
cannot close this case. Failure artifacts remain in the new UUID fixture tree.

## Actual Windows sharing failure and selected-worker cold-control repair

The previous root-custody candidate remains **Windows failed/unaccepted**: the
first actual run had five correct Temp-parent guard refusals, and the independently
trusted sibling rerun then exposed a self-sharing conflict in every real fixture.
Neither native passes nor remote checks overrule those receipts. Temp's extra
untrusted mutation principal is not a reason to relax guards or change Temp ACLs.

The retained no-delete-sharing custody handle still requests exactly
MAXIMUM_ALLOWED. Its named identity observer now requests FILE_READ_ATTRIBUTES
only and shares read/write/delete; it compares the same canonical volume/file
index/attributes without requesting DELETE. Receipt capture uses a separate
READ_CONTROL+attributes, fully shared, observation-only handle. That handle cannot
mutate descriptors. It can coexist with the real custody handle while the latter
continues to exclude deletion/substitution. The claimed SetSecurityInfo
no-child-propagation contract was subsequently disproved and is blocked. The identity recheck is preserved,
not skipped or made path-specific. New Windows regression loops named/receipt
observations under a held custody lease and asserts rename exclusion BEFORE
cleanup. Existing raw descriptor, parent DELETE_CHILD effect, privacy and rollback
contracts remain strict and still require actual ordinary/elevated acceptance.

Final fixture receipts no longer acquire a competing custody lease. An original
test failure is captured before final evidence work: a secondary receipt failure
is reported without replacing it. If the test body passed, failed receipt capture
still fails the test. Final disposal remains defensive, not passing evidence.

### Bounded cold controls, without keep-alive or warmup

A selected worker may stop while idle. [Microsoft's systemd documentation](https://learn.microsoft.com/en-us/windows/wsl/systemd)
links the WSL lifecycle explanation; services do not establish persistent WSL
liveness. The measured cold launch took40.203s while the immediate warm no-op was
158ms; ordinary15s control therefore cannot represent a cold worker. No keep-alive,
retry, sleep, global deadline increase, service disable or distro setting is a
production dependency in this repair. Root owns actual stopped/warm worker tests.

`Invoke-WslColdSelectedControl POLICY prepare|status|reconcile|probe` uses fixed
selected distro/interpreter/source-addressed worker argv. A new bounded control
prefix, `revkit-cold-control-started-v1` plus LF, is emitted AFTER root/isolated/
no-bytecode/immutable-bootstrap ownership checks. It means Python bootstrap has
entered, **not** policy/runtime/repository admission. Startup time runs until the
entire exact prefix arrives. A separate operation deadline begins then, covering
signature/config/runtime/mount/native-ID work and the actual command. Any stderr
byte (including WSL startup warnings), wrong/missing prefix, output flood, EOF,
nonzero exit, timeout or unsettled teardown refuses. Pipes drain simultaneously,
64KiB per output, bounded input and finite frontend teardown. No text conversion
handles VHD streams; this small control prefix is separate from unchanged binary
backup framing. Root must deploy the new consistent worker/controller version;
installed older flags do not silently adopt this interface.

Signed `worker.controlBudget` has EXACT integer fields:

- `bootInitMilliseconds`:10000..120000, must match actual root-owned
  `/etc/wsl.conf` systemd=true/initTimeout (documented default10000).
- `launchAllowanceMilliseconds`:1..60000, explicit reviewed host allowance.
- `operationMilliseconds`:1..60000 for prepare/status/probe after bootstrap.
- `reconciliationMilliseconds`:1..60000 for reconcile after bootstrap, including
  exact systemd stop/kernel confirmation. This is not Windows parent-exit proof.
- `frontendTeardownMilliseconds`:1..10000, separate cancellation/drain/exit budget.

Startup is bootInit+launchAllowance (max180000ms); e.g. a reviewed60000+30000
contract provides90000ms startup, then a separately reviewed15000ms operation.
These are illustrative bounds, not invented host acceptance. All paths validate
bounds before launch. Generic local signing/list/hardware controls keep their
short15000ms default/30000ms ceiling and5000ms teardown. Local successful signing
may legitimately emit bounded stderr; selected-worker admission cannot. The two
methods deliberately have different diagnostic rules. Unknown or missing signed
budgets refuse. Warm state is never required or sampled as an admission fact.

`--control-prepare`, `--control-status UUID`, `--control-reconcile UUID` use the
existing fixed owners; legacy unprefixed direct diagnostics remain separate.
`--control-probe` is a fixed read-only startup diagnostic which needs no real
policy/repo/key. It reports source release, observed boot init timeout and kernel
session, with runtimeAdmitted=false. Controller example after root stages the
NEW immutable release and reviews the small policy-shaped argument object:
`Invoke-WslColdSelectedControl -Policy REVIEWED_WORKER_BINDING -Action probe`.
Then test actual prepare/status/reconcile with their real signed facts. No source
command starts/stops the worker or redeploys the accepted old release.

The frontend wrapper kills/reaps/drains only its owned process tree within its
teardown budget. A settled Windows frontend is **never** proof of Linux descendant
exit. On reconcile/status error or unavailable acknowledgment, existing retained
source/partial/secret custody remains. Native tests separately demonstrate slow
startup beyond the work budget, operation/startup timeout, diagnostic refusal,
wrong prefix, flood/nonzero and child exit before cleanup. A descendant holding
an inherited pipe after parent exit must refuse incomplete control output without
claiming descendant exit. Unsettled frontend/drains report teardown UNCONFIRMED;
settled frontend I/O is still not Linux descendant evidence. Pipe setup itself
remains inside owned-child cleanup, with a missing-pipe fault regression.
No unit test waits for a real30-second cold launch. Actual Windows-to-worker
startup/pipe/supervisor/cancellation acceptance is still required.

### Kernel session scope and existing VHD storage follow-up

Signed worker policy now explicitly uses `kernelBootId`, replacing ambiguous
`bootId`; old documents cannot silently adopt the new schema. This reads Linux
`/proc/sys/kernel/random/boot_id`, a kernel-session observation which may survive
or be shared across WSL distro lifecycles. It is **not a per-distro reboot ID**,
proof of cold startup or evidence that an old worker process remains alive.
Persistent machine ID plus authoritative Windows registration/VHD, immutable
runtime and fresh mount/device/native repository checks still bind admission.
Owned systemd MainPID/cgroup, actual kernel descendant checks, durable cancellation
tombstone and stream acknowledgments establish transaction lifetime. Reconciliation
may examine a later kernel session using the same signed persistent state and
cannot infer an old job's exit merely from the old identifier. Boot/readiness
output uses the explicit kernel name; prior receipts retain their original fields.

Maintained **WSL storage-owner follow-up**, separate from this repair: the
controller's metadata inventory finds existing WSL parents/VHDs with broad public
FullControl AND legitimate VM/capability SID grants. A protected new root namespace
changes neither those child descriptors nor all their effective permissions. Do
not claim it privatizes existing VHDs. Do not extend code-authority principal
allowlists to make old storage look accepted, remove unknown VM/capability grants,
or apply the narrow root-ACE transformer to existing WSL files.

The later owner must extend the maintained WslBackup registration/cold-file
lifecycle with a separately reviewed storage plan: exact registered VhdFileName,
source/worker/protected identities and current raw descriptors/owners/control/
group/VM-capability grants; saved user work and a coordinated cold outage; retained
last-good recovery and full verified backup/restore evidence; explicit per-path
mutation and drift-only rollback; actual WSL reopen/boot/consumer proof preserving
the required VM/capability access. Root owns any real ACL or lifecycle action.
This is a recorded source follow-up, not live storage hardening or permission to
modify the active main/worker/protected VHDs during this test turn. Desktop native
connection adoption, Codex offline move, producer Node24 hold and all deferred
IDE/Nix/Python/provenance work remain independent unfinished obligations.


### Actual control/child drift: blocked production, bounded native API experiment

The exact prior Windows run had46 cases:38 passed,3 failed,5 skipped. Root control
changed from0x9004 to0x9404 in two fixtures. One deliberately different template
also changed child DACL/protection/ACE representation. An unprotected fixture's
later D:AI observation and missing final receipt remain failed evidence. No root
apply/elevated acceptance follows from source checks. All old fixtures/receipts
remain untouched. E permissions were never changed.

The alternative is **test-only**, in `WslColdVolumeCustody.Fixture.cs`, excluded
from the runtime manifest. `SyntheticSecurityLab` exclusively creates new UUID
roots, registers them in-process, rejects existing/unregistered targets and
reparse/Git parents, then allows only those trees in the native experiment.
It uses `NtSetSecurityObject` with OWNER+DACL only, explicit metadata/security
access and a separate fully shared handle compatible with held custody. It never
sets protection-transition flags. [Microsoft's NtSetSecurityObject page](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/nf-ntifs-ntsetsecurityobject)
explicitly names the Nt form for user mode, but its requirements table describes
the kernel DDI. That is not an accepted Windows filesystem propagation/support
guarantee. Exact before/after root and child checks must actually pass; even a
synthetic pass cannot promote this API to production without a separate support
and contract review. `SetKernelObjectSecurity` warns against filesystem objects;
obsolete path-based `SetFileSecurity` is not substituted.

Timestamp diagnosis is separate: construction writers close before observations;
file hashing closes before fresh `GetFileInformationByHandle` creation/write time
and attribute reads. Cached GetChildItem timestamps are not used. Two immediate
independent observations must agree, without sleep/retry, or the baseline refuses
and retains both observations. The no-replacement observer case compares the same
metadata, so a timestamp failure cannot be mislabeled as mutation-only behavior.
The previously missing unprotected final capture now preserves the original body
failure while reporting a secondary receipt failure. SACL/last-access effects are
not claimed covered. No original timestamp observations are rewritten.

Windows CI now runs seven synthetic owner suites, including custody, control,
admission, worker and binary transport. The maintained acceptance runner emits
NUnit XML and a bounded nonsecret summary, preserves original fixture trees and
never uploads payloads/keys/cache/repository/private-input data. It allows only
the two explicitly native-only skipped cases; other skips fail acceptance.
Elevated cases require an actual admin token and a successfully scoped restore
privilege preflight. The disposable CI runner may exclusively create a protected
UUID anchor under validated ProgramFiles; it never edits any existing ACL. Laptop
acceptance uses a separately audited private parent, never the unsafe Temp parent.

Root staging from one signed Git archive (all paths are review placeholders):

```powershell
# Ordinary: explicit elevatedAccepted gap remains; no production apply.
& PACKAGE\tests\powershell\Invoke-WslColdWindowsAcceptance.ps1 -OutputDirectory NEW_RESULTS -RetainedFixtureParent AUDITED_PRIVATE_PARENT
# Separate actual elevation, only on NEW synthetic fixtures after root review:
& PACKAGE\tests\powershell\Invoke-WslColdWindowsAcceptance.ps1 -OutputDirectory OTHER_NEW_RESULTS -RetainedFixtureParent AUDITED_ADMIN_PROTECTED_PARENT -IncludeElevated
```

Include the test fixture C# and acceptance runner in the exact test supplement.
Neither command accepts an arbitrary existing mutation target. Do not run any
custody Apply/Rollback on E; those commands now refuse. If the experiment fails,
retain every failed descriptor/metadata observation and investigate the precise
class. A supported production implementation remains a concrete API/host blocker,
not a missing owner permission for ordinary source work.

### Selected-worker cwd is part of fixed launch admission

All selected-worker control/serve/reconcile/probe argv now include `--cd /`
before `--exec`. The Windows ProcessStartInfo working directory is explicitly
the absolute executable's parent, both in owned controls and serve/list monitors.
No caller UNC or repo cwd selects a worker directory. Caller-owned already-started
process test seams cannot retroactively fix cwd; their caller must configure it.
Strict selected stderr, startup/work/teardown budgets, shell-free arguments,
immutable source/interpreter and identity checks remain. The actual diagnostic
with only `--cd /` passed a29.136s cold probe without warnings; this candidate-only
receipt is not acceptance of the changed signed source or production worker.
Root must stage the consistent new release and test from the problematic UNC cwd
while spare is genuinely stopped, main running and recovery stopped. No warmup,
retry, sleep, keeper or ignored stderr is an operational dependency.

Existing E WSL/VHD broad ACLs and VM/capability grants remain a separate storage
owner follow-up behind cold outage/backup/recovery proof. New namespace protection
does not privatize old descendants. Never change live storage ACLs to make tests
pass. Desktop RPC/Codex offline relocation, real key recovery/capacity/full backup/
dense restore/import/boot and deferred runtime/editor/provenance work stay open.


The first newly enabled Windows CI run refused before tests because converting an
ACL's display account names back to SIDs failed for an unresolved identity on a
runner ancestor. The guard now requests access rules **as SecurityIdentifier**
from the existing descriptor, avoiding account-name round trips. Every exact SID
and effective/template mask still goes through the same refusal policy. Unknown
mutation/read principals are not allowed or omitted. A Windows synthetic orphan
SID case exercises observation of a harmless synchronize-only grant and refusal
of that same SID with dangerous authority. The original CI failure is retained;
this source repair does not accept its host or relax ancestor trust.


### Constrained child-inheritance transaction, after actual host experiments

The ordinary source8e60f85 host run discovered100 cases:93 passed,2 failed,
2 expected platform skips and3 explicitly filtered Elevated cases. Forward normal
restriction passed exact root/control/group, existing child descriptor/metadata/
content and new-child inheritance comparisons. Rollback then failed because the
experiment reopened WRITE_OWNER after restriction removed it. A second experiment
changed a child template and **did alter old children** with NtSetSecurityObject.
The generalized no-propagation proposition is rejected. Original fixtures and
failed receipts remain intact. The later SID-only regression passed1 case with
21 deliberately filtered cases; it did not rerun or accept the unchanged failures.

The proposed **unchanged-child-inheritance-v1** scope is enforced in the owning
policy and version2 custody plan, in both directions, before any experimental
native call. Plans of the old version refuse. The ACL revision and ordered inheritable ACE list
must retain the exact SID, specific mask, OI/CI flags and inherited marker. Root-only
ACEs have no child projection. IO on an inheritable ACE controls effectiveness
on the current root, so adding/removing only IO preserves its child projection.
CREATOR OWNER remains a generic SID mapped to the new child's owner, never expanded
to the parent's old/new owner. Unknown controls, generic rights, no-propagate,
deny/object/callback ACEs remain outside the grammar. Actual root restriction still
rejects inherited root ACEs; inherited-marker preservation in a no-op scope check
is not permission to transform those forms. Owner/group/control/raw exact checks
remain; this projection is a prerequisite, not replacement evidence.

See [Microsoft's ACE inheritance rules](https://learn.microsoft.com/en-us/windows/win32/secauthz/ace-inheritance-rules).
A different SID/mask/order/count/OI/CI/mapping must refuse **before mutation**,
with unchanged root AND children and zero native calls. It must never be normalized
into a successful no-propagation experiment. Parent DELETE_CHILD restriction still
has the separately documented intended effect on existing children's parent-based
deletion fallback, despite unchanged child descriptors.

The test-only candidate now duplicates the already acquired owning lease's original
open file description using [DuplicateHandle SAME_ACCESS](https://learn.microsoft.com/en-us/windows/win32/api/handleapi/nf-handleapi-duplicatehandle),
non-inheritable and within the same process. No path reopen or WRITE_OWNER re-request
occurs after mutation. Runtime name/final-handle/file identity and delete exclusion
stay held throughout both directions. The duplicate closes before the original
lease, including failure paths. Test-only reflection keeps the production handle
surface closed and reuses the owning descriptor/scope validator; it is not packaged
as runtime code. Native call count and handle lifetime are asserted before cleanup.
This is still synthetic, not an accepted production API/support contract.

New synthetic cases model explicit unprotected control0x8004 under a NEW private
parent that contributes no inheritance, plus a separately elevated unresolved
owner/group case. They assert the actual observed control, never clear/mask it.
Real volume-root behavior, original ACL spare capacity/layout and actual owner/group
restore on the real filesystem remain separate unproved gates. Protected fixture
passes alone cannot accept the observed real nonprotected root form.

### Windows runner components, anchor roles and exact inventory

The ordinary component explicitly excludes only known Elevated cases. Receipts
separate total/discovered/selected/excluded, raw Pester NotRun and unexpected
selected NotRun; an excluded case must match the known name/file/elevated tag and
ShouldRun=false. Unexpected skips/not-run, duplicates, missing cases or empty
suites fail. A literal AST inventory of every selected test file binds discovery.
Empty unexpected lists serialize as actual empty arrays. Ordinary success never
sets elevatedAccepted/fullSyntheticAccepted; real elevated proof remains required.
The added accounting owner is an eighth small suite, with refusal tests on native
and Windows. No component result grants production admission.

The CI ProgramFiles preflight previously treated a proposed ancestor as a public
code leaf. That may refuse legitimate inheritable child templates; exact offending
SID/rights were absent from its old generic error, so this is a diagnosis to test,
not an asserted historical fact. New bounded readonly audits retain exact owners,
SIDs, masks and flags, old-public-leaf offenders and ancestor offenders. The generic
synthetic-anchor creator audits LocalApplicationData ancestry as **private data
ancestry**, then creates a NEW exclusive protected user-owned UUID leaf. For the
separate elevated namespace case it audits ProgramFiles as public-code ancestry
and creates a separate new Admin-protected authority fixture. Existing ACLs are
never changed. Actual operational public-code/ancestor/private-leaf guards are
unchanged; final new leaf validation remains strict. If an ancestor has real
outside DELETE/DELETE_CHILD/WRITE_DAC/WRITE_OWNER, refuses after retaining exact
nonsecret observations; there is no trust exception or fallback permission repair.

Root interfaces from a fresh signed package and matching complete supplement:

```powershell
# Ordinary component; original retained fixtures are never inputs.
& PACKAGE\tests\powershell\Invoke-WslColdWindowsAcceptance.ps1 -OutputDirectory NEW_RESULTS -RetainedFixtureParent AUDITED_PRIVATE_PARENT -PythonPath REVIEWED_INSTALLED_PYTHON -PythonSha256 REVIEWED_PYTHON_HASH
# Separately elevated, new output; namespace case needs its own code-protected ancestry.
& PACKAGE\tests\powershell\Invoke-WslColdWindowsAcceptance.ps1 -OutputDirectory OTHER_RESULTS -RetainedFixtureParent AUDITED_PRIVATE_PARENT -AdminFixtureParent AUDITED_AUTHORITY_PARENT -IncludeElevated -PythonPath REVIEWED_INSTALLED_PYTHON -PythonSha256 REVIEWED_PYTHON_HASH
```

CI-only CreateCiAnchor chooses fixed role-aware parent candidates and saves bounded
private-anchor-audit/authority-anchor-audit JSON. No recursive tree or real data
payload is uploaded. Local supplied Python path/hash binds the installed public
interpreter and avoids WindowsApps command aliases without changing system PATH;
no interpreter installation or secret inputs are involved.

Actual maintained controller cold probe passed40.322s and warm139ms, strict stderr,
with controller8e60f85 and installed earlier worker explicitly distinguished.
The worker Python/provisioner bytes were unchanged: no duplicate Borg installation
is needed to restate that component proof. runtimeAdmitted=false and final consistent
immutable production release/policy/device/cgroup admission remain pending.

Latest controller live estimates leave2937942016 bytes before further overhead,
or only519995392 after the metadata-only Codex move estimate, before its additional
directory/database/link/cache overhead. These are not cold bounds. Preserve full
backup/restore acceptance before simultaneous Codex relocation unless a complete
fresh combined budget proves both. No sparse/compression/dedup credit; no source
outage, real key/repository, full backup/restore, live ACL edit or relocation is
accepted by this source increment. All deferred migration obligations remain.


The first new hosted Windows run exercised110 cases:106 passed,2 failed,
2 expected platform skips,0 not-run. Constrained forward/rollback, zero-call
changed-template refusal, unprotected control and elevated unresolved-owner/group
cases passed there. This is hosted synthetic evidence, not laptop/volume-root or
production acceptance. Private and public ancestor audits had no outside effective
mutation offenders. The current hosted C root's S-1-5-11 append/create-directory
right4 is safe ancestry but an invalid public code leaf write grant; its inherit-only
generic template is likewise not effective ancestor authority. These observations
explain the role distinction on this host; the old disposed runner did not capture
its exact offending SID, so historical identity equality is not asserted.

Two remaining test defects were then repaired. A filtered token's DELETE open of
the still-held root returned sharing32 before an ACL denial could be established.
The test now uses [AccessCheck](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-accesscheck)
with an actual restricted impersonation token and the exact held root descriptor
to prove its denied security rights and permitted creation rights, independently
of sharing. Real child creation and unheld target opens still prove filesystem
behavior. CanOpen still throws on sharing32; it is never recast as access-denied.
The original retained handle/custody stays held throughout. The authority namespace
factory now validates its explicitly public parent as public, while private fixture
parents retain strict PrivateData validation. No operational guard was changed.
Failed source/test packages and CI XML/audits are retained; revised tests still
need actual Windows execution.

### Raw-layout and real synthetic volume-root gate

Root's independently pinned b123 laptop ordinary component passed104 cases with
2 expected platform skips and4 explicitly excluded Elevated cases. Root then
completed a separately owner-approved Microsoft PowerShell UAC run of all eight
suites from a fresh protected C copy:110 discovered/selected,108 passed,0 failed,
2 expected platform skips,0 excluded/not-run. All124 protected source/dependency
files were rehashed after exit. That actual laptop full/elevated synthetic gate
is accepted. The orchestration capture is audit evidence, not a runtime/bootstrap
dependency. It did not mutate E or establish volume-root acceptance.

The remaining layout gap is concrete: the observed nonprotected root descriptor
had28-byte owner/group SIDs, DACL offset76, revision2, three standard allow ACEs,
248 declared ACL bytes,68 parsed bytes and180 zero spare bytes, descriptor324.
The accepted subtree fixtures were compact (ACL68/descriptor144). Passing compact
cases cannot prove spare capacity or actual NTFS volume-root rollback.

`ColdSecurityLayout` now records and checks the raw component offsets, SID lengths,
ACL declared/parsed/spare lengths, revision, reserved fields and trailing bytes.
The original semantic snapshot hash stays unchanged; a separate complete descriptor
hash covers offsets/layout/bytes too. The supported writable layout is explicit
owner-then-group-then-DACL with zero ACL spare and no outer trailing bytes. Other
orders/gaps/overlaps, nonzero spare/reserved bytes, malformed ACE bounds and outer
tail mutation refuse; they are never silently canonicalized. `WithOwner` preserves
the full DACL bytes/capacity. Restriction retains at least original AclSize, grows
only if required by added root ACEs, and retains zero spare within that capacity.
Rollback uses the exact original descriptor. Plan version3 binds both complete
raw hashes; older plans refuse. Native mutation acceptance compares BOTH snapshot
and full descriptor hashes, so kernel compaction is an explicit failure, not a
successful normalized rollback. Generic tests cover multiple SID sizes/capacities,
not a machine SID/hash exception.

The constrained native setter is now in `ColdDirectorySecurityLease`, on its
original retained handle. The old reflection/duplicate test candidate was removed.
Only unforgeable fresh synthetic directory/volume provenance can currently call
that internal implementation; public production Replace/Apply/Rollback still refuse.
The fresh directory factory is C-only, exclusive UUID, outside Git/reparse paths;
volume authority originates only from a newly created virtual disk handle. No test
flag or existing-path registration grants a real-volume capability.

`Invoke-WslColdSyntheticVolume.ps1` is a separate maintained Plan/Execute harness.
Default Plan reads protected source/parents/capabilities only. Execute requires an
independently saved/reviewed fresh plan digest, exact source manifest/parent
identities/descriptors/current-user binding and actual elevation with scoped
SeRestore/SeManageVolume privileges. No account/process/global privilege setting
changes. Root reviews and runs it; the native source lane does not execute it.

The new file is a fixed128MiB classic VHD (256MiB hard backing-file ceiling) in a
NEW protected/private UUID C workspace. `CreateVirtualDisk` version1 uses a fresh
identifier, no source/parent input and full physical allocation. The virtual-disk DLL imports resolve from System32 only. Its live handle,
file ID/name/no-delete metadata custody, virtual identifier/geometry and attachment
physical path remain bound. Attach requests NO_DRIVE_LETTER and no permanent
lifetime. No Hyper-V cmdlet/feature installation, diskpart, WSL registration or
real/migration disk input exists.

Storage association follows Microsoft's documented Get-DiskImage on the exact
new image piped to Get-Disk. Native device-number metadata on that returned device
path must match the held virtual handle; boot/system/read-only/offline/clustered/nonvirtual
or ambiguous objects refuse. Immediately before initialize/partition/format, the
binding is rechecked. Writes accept only the returned Disk/Partition objects,
never caller disk ordinals or drive letters; partition requery/identity/geometry
is checked before format. A native single-volume-extent check binds the resulting
GUID-root path to that same owned device and exact partition offset/length. Generic
unsupported host/provider behavior produces a retained refusal, no fallback.

The fresh NTFS system-child allowlist is explicit (System Volume Information and
Recycle Bin). A bounded64-entry/depth4/16MiB-data inventory captures every accessible
raw child descriptor, creation/write time, attributes and content digest. Inability
to inspect a system child or any unexplained delta refuses. Even fixture seeding
must leave system children exact; no SVI permission rewrite, deletion, sleep or
retry hides a mismatch. Fixed ordinary/protected payloads are then created, two
stable baselines required, and the generic control0x8004/foreign28-byte SIDs/ACL248
case is tested on the actual new NTFS ROOT. Proposed/observed raw descriptors,
unchanged descendants, inherited new child, restricted ordinary-token rights and
actual child creation, original-handle rollback and native-call counts are retained.
No source VHD/user data is read. Expected system-created differences are reported,
not exempted from comparison.

Evidence is independent of code and backing data. Before/after/pending-detach
records flush before owned handle cleanup. Failures retain workspace, VHD and all
receipts, including failed seed/layout observations. Only DetachVirtualDisk on the
same verified held handle is used; uncertain identity/detach fails closed with a
retained unconfirmed outcome. No global detach, lock breaking, repair or deletion.
Nonpersistent OS handle lifetime is not a substitute for a successful explicit
detach receipt. Native/Storage synchronous calls have no claimed hard cancellation
latency; root's reviewed process deadline must treat interrupted work as unaccepted,
retain artifacts and inspect only that owned attachment. Do not kill host services
or select another disk to make a fixture complete.

Root review interface, placeholders only:

```powershell
# Independently protected code and disjoint private C fixture/evidence parents.
& PACKAGE\scripts\Invoke-WslColdSyntheticVolume.ps1 -FixtureParent REVIEWED_C_FIXTURE_PARENT -EvidenceParent REVIEWED_C_EVIDENCE_PARENT -SourceManifestSha256 REVIEWED_MANIFEST_HASH
# Save exact Plan JSON privately, review source/operations/hash, then separate UAC:
& PACKAGE\scripts\Invoke-WslColdSyntheticVolume.ps1 -Phase Execute -PlanPath REVIEWED_NEW_PLAN -ReviewedPlanSha256 REVIEWED_PLAN_HASH
```

The root wrapper may use maintained synthetic-anchor creation to make NEW private
parents under an audited C ancestor; do not reuse old fixture directories or turn
the previous temporary elevated script into a dependency. Use a protected exact
new source package and supplement; no code copied from writable diagnostics.
Normal CI exercises raw layout/refusal logic and compact subtree regressions only;
it never creates/attaches/formats this VHD. Actual root/layout proof is unrun until
root supplies its separately reviewed receipt in a later same-chat turn. If the
kernel discards AclSize/spare or cannot preserve exact root bytes, public production
remains blocked; review explicit supported-contract alternatives with that failed
receipt, rather than dropping fields or rewriting the real root once.

Primary API references: [CreateVirtualDisk](https://learn.microsoft.com/en-us/windows/win32/api/virtdisk/nf-virtdisk-createvirtualdisk),
[AttachVirtualDisk](https://learn.microsoft.com/en-us/windows/win32/api/virtdisk/nf-virtdisk-attachvirtualdisk),
[GetVirtualDiskPhysicalPath](https://learn.microsoft.com/en-us/windows/win32/api/virtdisk/nf-virtdisk-getvirtualdiskphysicalpath),
[Get-DiskImage association example](https://learn.microsoft.com/en-us/powershell/module/storage/get-diskimage),
[Initialize-Disk input objects](https://learn.microsoft.com/en-us/powershell/module/storage/initialize-disk),
[New-Partition input objects](https://learn.microsoft.com/en-us/powershell/module/storage/new-partition),
[Format-Volume partition objects](https://learn.microsoft.com/en-us/powershell/module/storage/format-volume).

Latest live E free713272750080 versus source641689714688/reserve68719476736
leaves2863558656 before new overhead; not a cold admission. Existing worker usage
is already reflected in free space. Codex state dense2417946624 plus unknown
additional overhead must not silently consume this restore margin. Full restore
first remains the hold absent a complete fresh combined budget. Main/recovery/
worker, real E permissions, production key/repository/full backup/restore and
all deferred runtime/editor/provenance work remain outside this source execution.

### Read-only system Storage ownership preflight

The controller's c5edc6f full nine-suite **laptop** elevated component passed:
117 discovered/selected,115 passed,0 failed,2 expected platform skips,0 excluded
or not-run;128 protected source/dependency files rehashed unchanged. Its separate
volume attempt failed at **volume-plan**, before any reviewed plan, child or VHD
existed: `Owned Microsoft Storage module required.` The first UAC was canceled
without starting; the approved retry exited1 at that precondition. Component
acceptance is retained. Actual synthetic volume/root and production acceptance
remain false; no real E permission or existing VHD changed.

The observed Microsoft Storage manifest exports functions from declared nested
CDXML modules (`DiskImage`, `Disk`, `Partition`, `Volume`). Their command ModuleName
is the child name, so requiring it to equal the parent `Storage` was incorrect.
The maintained resolver now selects the native64-bit system Storage.psd1 by
absolute SystemDirectory path, not PSModulePath. Before explicit import it requires
protected non-reparse file ancestry, Valid Authenticode with an explicit Microsoft
Windows/Corporation publisher identity, and validates every declared direct nested
CDXML/script file the same way. No laptop file or certificate hash is hardcoded.
Other declaration or publisher forms refuse for review. It binds the imported
parent path/base/GUID/version, exact declared/imported child inventory, and each
of the seven module-qualified commands to that parent's exported compiled Function
and its declared CIM child. Foreign loaded parents, aliases, ambiguous
resolution and session proxies refuse. It never unloads foreign modules to pass.

The first signed resolver attempt failed the new real Windows regression because
Import-PowerShellDataFile rejected the standard manifest's expanded system-assembly
path. That failure and bundle remain retained. Inspection now uses PowerShell's
parser and SafeGetValue only on the literal GUID/version/NestedModules nodes;
other manifest expressions are not evaluated by the inspector. Dynamic identity
or nested declarations refuse. The later standard module import still processes
the signed Microsoft manifest normally; a redirected windir refuses rather than
being silently repaired. This is not arbitrary script evaluation or a substitute
for the prior signature/protected-path checks.

A subsequent real Windows diagnostic proved CDXML Get-Command returns a distinct
FunctionInfo metadata wrapper for the same exported compiled block: the owning
module reference, ScriptBlock ID, definition and context were unchanged. Wrapper
reference equality was therefore an incorrect condition. The binder retains exact
declared module reference ownership and now requires the parent's nonempty compiled
block ID, exact body and owning context; metadata copies pass, changed blocks,
bodies, contexts, aliases and shadow commands refuse. The failed wrapper checks
and bounded diagnostic remain evidence, not an accepted run.

The standalone preflight needs no fixture, disk inputs or elevation:

```powershell
& PACKAGE\scripts\Invoke-WslColdSyntheticVolume.ps1 -Phase StoragePreflight
```

It reads signatures/ACLs/files and imports the selected system module into the
current process; it executes **no Storage disk command** and creates no plan,
child or VHD. Preserve its nonsecret manifest/version/GUID/file-hash/command-path
JSON before reviewing another elevated test. The Windows-only regression runs
this real installed resolver twice to exercise stable revalidation; native tests
of ownership observations remain models, not actual Windows acceptance.

Synthetic volume plan schema2 binds that complete Storage receipt. Execute rejects
older plans, rechecks the receipt before fixture creation and revalidates it before
Storage operations. The fixed module-qualified image/disk/partition/volume path,
returned-object writes, no ordinals/letters, original handle and all raw descriptor
checks remain strict. Public production Apply/Rollback remains blocked.

For capture comparison, c5edc6f to89a40a3 changed only four files: System32-only
virtual-disk DLL imports; clustered-disk refusal; reviewed operation/privilege and
false production-field binding; one-shot seed-attempt accounting including failure;
actual native-call counters (rather than counting before validation), plus runbook
wording. Those changes were not part of the c5 laptop capture. This resolver repair
builds on89a40a3 and does not reinterpret that capture or promote volume acceptance.

Primary references: [module manifests and NestedModules](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_module_manifests),
[explicit-path Import-Module](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/import-module),
[safe AST values](https://learn.microsoft.com/en-us/dotnet/api/system.management.automation.language.ast.safegetvalue),
[Authenticode and catalog signatures](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/get-authenticodesignature).

### Typed Storage CIM enums after the first owned VHD observation

The controller accepted f21a166 on the actual laptop: ordinary StoragePreflight
exit0/no stderr (30 signed files/seven commands), then separately approved full
elevated component125 selected/123 passed/0 failed/two expected platform skips,
zero excluded/not-run;128 code/dependency files independently rehashed unchanged.
After independent exact plan review, the separate maintained synthetic attempt
created/attached its NEW fixed128MiB VHD, but failed at its first owned Storage
observation, before initialize/partition/format. Explicit own-handle detach passed
and the controller independently observed that exact image as detached. The VHD
and receipts remain retained. These are accepted component and bounded creation/
attachment/detachment observations, not root-layout/rollback or production proof.

The real Storage type adapter exposes BusType as a display string, while the
underlying CIM property's type/value remain UInt16. The disk classifier now requires
an actual local MSFT_Disk CIM instance, the Storage namespace and a single raw
UInt16 BusType property; only schema values14/15 qualify. Missing/duplicate/mistyped
properties, proxies, remote/wrong-class/namespace identities and physical/unknown
buses refuse. It does not parse display text. Exact owned image/native handle,
path/number/geometry, boot/system/offline/read-only/cluster and command-binding
checks still apply independently; a client-only CIM object grants no disk custody.

Adjacent PartitionStyle/FileSystemType comparisons were intentional display-label
checks, not integer casts. They now use the same raw typed reader to avoid depending
on adapter presentation: MSFT_Disk0 is uninitialized/unknown (PowerShell RAW),1 MBR,
and MSFT_Volume14 NTFS. The MSFT values differ from Win32 PARTITION_STYLE values;
they are never mixed. Fixed cmdlet input arguments MBR/NTFS remain intentional API
arguments. Other ToString uses concern real CLR module/command/signature enums;
FileAttributes is a real CLR flags conversion. Those are unchanged.

The Windows-only regression uses New-CimInstance **-ClientOnly** with the real
installed Storage types. It proves adapter/raw-value behavior for virtual and USB
buses, malformed raw types, partition styles and NTFS without provider enumeration,
disk selection, attachment or format. Native typed-observation/refusal tests remain
models. Root can run the scoped WslColdSyntheticVolume.Tests.ps1 read-only before
reviewing any NEW plan/UAC. Never reuse the retained failed VHD or its old plan.
Public production Apply/Rollback stays blocked; actual new volume-root/raw-layout/
rollback, full backup/restore/key/cold capacity and migration acceptance remain open.

Primary schema references: [MSFT_Disk UInt16 BusType/PartitionStyle](https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-disk),
[MSFT_Volume UInt16 FileSystemType](https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-volume).

### Explicit synthetic partition creation contract

The controller accepted dc346ea's actual laptop preflight and scoped21/21 readonly
tests, then the owner-approved elevated component131 selected/129 passed/zero
failed/two expected platform skips. Protected source/dependencies128 unchanged.
The separate NEW VHD attempt passed the raw bus/RAW/MBR checks, initialized MBR
and created one partition, then refused before format. Explicit own detach and
independent exact-image detached observation succeeded. All receipts/image remain
retained. This is not format, volume-root, raw-layout/rollback or production proof.

The controller's bounded read-only MBR/footer inspection proves the retained image
has a type7 partition at65536bytes, below the existing1048576byte guard. That proves
the default-offset mismatch only; the remaining association predicates were not
individually captured and must not be inferred successful. Source creation had
requested maximum size/IFS without Offset or Alignment, allowing provider defaults
that contradicted its own minimum guard.

Synthetic plan schema3 now binds fixed offset1048576bytes (UInt64) and alignment
1048576bytes (UInt32). New-Partition supplies BOTH explicitly with the same verified
InputObject/UseMaximumSize/IFS contract. No larger VHD, relaxed minimum, disk ordinal,
letter selector, retry or machine exception. Returned offset must equal the reviewed
request and still meet the original minimum; sector divisibility and finite positive
extent bounds are checked. UseMaximumSize does not imply an invented exact returned
size; provider-reserved space is allowed within the verified container bound.

Before format, bounded observations retain returned/current partition IDs, offsets,
sizes/types, local disk and parent identities/geometry/state, and owned native-device
identity. Each association/layout refusal names its predicate; unvisited predicates
are not certified by the receipt. Separate post-create/pre-format/post-format records
are new-only and flushed before validation. The existing parent/native handle check
still runs; observation facts are not a substitute for that capability. Unsigned
or modeled receipts never authorize an operation. UInt64 extent checks subtract only
after offset bounds, including the native BindVolume boundary, avoiding wraparound.

Native tests exercise the actual readonly validation gate and model format remaining
unreachable after refusal, coupled to AST ordering of the production pre-format gate
and explicit creation parameters. Windows-only tests read the real InputObject
parameter types and project client-only CIM partitions; no provider enumeration or
disk operation. Actual creation at the requested layout and every subsequent
format/extent/root/rollback gate still require a NEW controller-reviewed isolated
test. Never reuse the old image/plan. Production Apply/Rollback remains blocked.

Primary references: [MSFT_Disk CreatePartition Offset/Alignment](https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/createpartition-msft-disk),
[New-Partition InputObject parameter set](https://learn.microsoft.com/en-us/powershell/module/storage/new-partition?view=windowsserver2025-ps),
[MSFT_Partition identity/size properties](https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-partition).


### Separate permission-fidelity candidate; raw-layout failure remains evidence

The actual laptop957 partition-layout attempt accepted26/26 focused tests and
134/136 elevated component tests (two expected platform skips, no failures).
Its separate new128MiB VHD passed creation/attachment, MBR initialization, the
explicit1MiB offset/alignment,132120576-byte partition, NTFS4096 format and native
volume extent binding. System-before-seed was empty. The strict seed then FAILED:
requested descriptor324/ACL248/used68/free180 became descriptor144/ACL68/used68/free0.
Owner/group bytes, control0x8004, ACL revision/reserved/count and ordered ACE bytes
matched. The controller's read-only comparison found ONLY removal of180 all-zero
unused ACL bytes and the corresponding AclSize change. Explicit own detach and
independent exact-image Attached=false succeeded. No root rollback or real E
permission change was accepted. These facts supersede the earlier unrun-layout
scope above; they do not relabel the strict raw-profile failure as success.

Documented fact: [ACL_SIZE_INFORMATION](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-acl_size_information)
distinguishes AclBytesInUse (header plus ACEs) from AclBytesFree (unused allocation).
The reviewed [NtSetSecurityObject contract](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/nf-ntifs-ntsetsecurityobject)
sets security state and required access; it provides no reviewed guarantee of the
caller's unused allocation or binary-layout round trip. Observation: this NTFS
fixture discarded zero free capacity and retained every meaningful byte. Inference:
a separately reviewed permission/ACE-fidelity candidate is reasonable; continuing
to demand undocumented padding retention would leave exact raw restoration blocked.
No claim that every possible setter was exhaustively disproved is made. No raw NTFS
write, driver trick, live-volume normalization or alternative setter is introduced.

`exact-raw-acl-capacity-v1` remains the DEFAULT, schema3 synthetic profile, with its
original raw equality postconditions and failed receipts. The distinct OPT-IN
`permission-ace-zero-unused-v1` is a schema4 synthetic candidate, kind
`new-private-permission-fidelity-candidate-v1`. Its plan binds candidate status,
mandatory raw evidence, full raw CAS, exact descendants and
`rawByteRestorationPromised=false`; reviewed operations describe this distinction.
Execute accepts no independent profile flag: it derives the profile exclusively
from the independently reviewed plan and rechecks every candidate field. Old plans
or receipts cannot establish candidate acceptance. Public production Replace,
Apply and Rollback STILL REFUSE. Neither candidate plan nor synthetic provenance
can authorize an existing volume, path or production mutation.

Forensic raw identity and permission identity have separate jobs:

- Every before/requested/observed descriptor remains immutable full-byte evidence,
  with complete SHA256 and raw layout. Native calls receive the ORIGINAL requested
  bytes. Full raw SHA256 of the currently observed descriptor is the CAS input;
  even permission-equivalent padding drift refuses before a native call. A used-byte
  identity hash is never a CAS capability. Failed postconditions retain raw evidence.
- Candidate comparison accepts only the existing bounded self-relative contiguous
  OWNER/GROUP/DACL layout, standard nonempty allow ACEs with specific file rights,
  supported inheritance flags and ACL revision2 or4. Header offsets, exact owner
  and group bytes/lengths, ALL supported control bits, revision/reserved/count and
  every ordered ACE byte (flags/mask/SID/size) must match. Each ACE consumes its
  exact SID length, so opaque bytes cannot hide in a declared ACE. There is no SDDL
  or broad effective-access comparison, ACE sorting, SID remapping or coercion.
- The ONLY excluded representation is structurally validated all-zero UNUSED ACL
  capacity plus its AclSize field. Parsing walks the declared ACE count and checks
  every bound/alignment; every remaining byte INSIDE AclSize must be zero. Outer
  trailing allocation, gaps/overlap, nonzero spare/reserved data, malformed/hidden
  ACEs, null/empty DACL, SACL, object/callback/conditional/audit/deny/generic/unsupported
  forms refuse. Control/inheritance differences remain failures. The private
  comparison representation is never written back or substituted for raw evidence.
- A delta records `ExactRaw` or `ValidatedZeroUnusedAclCapacityOnly`, both raw
  digests, ACL used/allocated sizes and the separately named used-identity hash.
  Candidate rollback promises exact supported permission/ordered-ACE identity,
  NOT restoration of unused raw capacity or the original complete descriptor hash.
  Raw bytes are preserved as evidence, not promised as a setter result. Existing
  descendant raw descriptor/metadata/content evidence remains EXACT and unchanged.

The candidate uses the same original retained handle, named/file identity checks,
no-delete-sharing custody, unchanged-child-template precondition and fresh synthetic
capability as the strict implementation. One seed attempt is consumed even if it
fails; its full raw pre-seed observation is saved before mutation. The initial
fresh NTFS descriptor is forensic evidence, not claimed permission-equivalent to
the deliberately different seed. Seed/forward/rollback each retain requested and
observed raw snapshots and explicit delta. Forward and rollback compare exact
permissions against their respective requested targets, then compare the final
state to the observed baseline. CAS uses the actual post-forward raw hash. Exact
system/descendant/ordinary-access/new-child inheritance checks, retained rollback
capability, two transaction calls, explicit own detach and failure retention remain.
Candidate acceptance has a DIFFERENT receipt filename and false strict-profile,
real-E and production acceptance fields. Existing generic initial/final test-tree
receipts alone are never candidate acceptance.

Native pure-byte coverage checks padded/compact comparison, all meaningful compact
bytes, supported control/revision/order differences, malformed/unsupported grammar,
nonzero spare/hidden data and raw CAS refusal. Existing five platform-specific skips
in the scoped volume test file retain their meaning. A separate elevated Windows
subtree test exercises the new candidate transaction, foreign owner/group,
nonprotected control, exact descendants, real ordinary-token creation and retained
rollback capability; native skips do not certify these behaviors. Hosted/subtree
proof cannot prove actual NTFS VOLUME ROOT behavior or real E rollback.

Root's next read-only review uses a NEW protected exact signed package and complete
supplement, then StoragePreflight and the scoped WslColdSyntheticVolume tests. Only
root, after separate current-source/plan/UAC review, may request a NEW image:

```powershell
& PACKAGE\scripts\Invoke-WslColdSyntheticVolume.ps1 -Phase StoragePreflight
Invoke-Pester -Path PACKAGE\tests\powershell\WslColdSyntheticVolume.Tests.ps1 -Output Detailed
# NEW protected/disjoint private C parents; old image/plan/marker remain untouched.
& PACKAGE\scripts\Invoke-WslColdSyntheticVolume.ps1 -FidelityProfile permission-ace-zero-unused-v1 -FixtureParent REVIEWED_NEW_C_FIXTURE_PARENT -EvidenceParent REVIEWED_NEW_C_EVIDENCE_PARENT -SourceManifestSha256 REVIEWED_CURRENT_MANIFEST
# Independently review/schema4/candidate fields/operations/raw policy/digest first.
& PACKAGE\scripts\Invoke-WslColdSyntheticVolume.ps1 -Phase Execute -PlanPath REVIEWED_NEW_CANDIDATE_PLAN -ReviewedPlanSha256 REVIEWED_EXACT_PLAN_DIGEST
```

Actual NEW Windows candidate volume proof is UNRUN until root supplies receipts.
No production promotion follows automatically. Full encrypted backup/readback,
keyfile bootstrap/export and Google+Apple off-laptop recovery drill, source outage,
fresh shared-filesystem cold capacity (dense restore PLUS positive transaction/cache/
worker overhead PLUS64GiB reserve) and full restore/import/boot remain open. Prepare
accepting an absent repository is NOT repository initialization; existing private
key import does not close bootstrap/export. Live2.825GB headroom is not admission.
Codex relocation stays behind restore absent a complete combined budget. All prior
failed filesystem/sparse/ACL receipts, old fixtures, root storage-owner/busctl gaps,
Node24 producer, Python/Nix/provenance and deferred standard plus custom Zed IDE
return obligations remain intact. Overall migration is NOT GREEN.


### Reviewed production permission custody v2 (source promotion, no activation)

The controller subsequently accepted the actual laptop permission candidate at
efcd20f: read-only Storage preflight and32/32 focused tests;143 selected elevated
component cases,141 passed/two expected platform skips, no failures/not-run.
A separate NEW128MiB NTFS volume-root transaction exited0: own create/attach/MBR/
1MiB partition/format/native extents, seed, forward, ordinary rights/creation,
new-child inheritance, retained-handle inverse and own detach all passed. The
controller independently compared exact descendant evidence, raw CAS chain and
three native calls (one seed/two transaction). Seed/rollback ACL248/used68 became
ACL68; forward ACL248/used132 becameACL132. Only validated zero unused allocation
differed. This fixture's observed baseline/final raw hashes happened to match;
padded raw restoration is NOT promised. Strict raw-profile failures remain failed.
No real E permission change, source/worker activation or production backup occurred.

This supports explicit source promotion review of a DIFFERENT operational profile:
policy schema2/kind `cold-volume-permission-custody-v2`, `fidelityProfile` exactly
`permission-ace-zero-unused-v1`; plan schema4/kind
`cold-volume-permission-custody-plan-v4`. Legacy schema1 policy/schema3 exact-raw
plans and public `ColdDirectorySecurityLease.Replace` STILL REFUSE mutation. Real
volumes never acquire synthetic provenance. The new reviewed entry is the existing
`Invoke-WslColdVolumeCustody.ps1`; default remains READ-ONLY Plan. Production and
synthetic transaction factories have separate admission; synthetic journals carry
`bindingScope=FreshSyntheticOnly` and are rejected as production rollback evidence.
No test flag, supplied boolean, laptop SID/hash or old receipt authorizes a target.

Plan binds canonical direct NTFS root, exact MBR/GPT hardware/filesystem, native
volume-GUID/root-file identity/attributes, current owner, protected source manifest
and exact closure, Microsoft system Storage binding, independently protected
DIFFERENT hardware/filesystem evidence parent, exact evidence identity/raw descriptor,
new bounded namespace, positive payload/evidence growth allowances and reserve,
original/requested raw descriptors, unchanged inheritance/control/group and the
versioned fidelity contract. Explicit phase/UUID/freshness is required; Apply plan
has at most one hour and cannot act as a Rollback plan. Namespace collision refuses.
The shared signed-system Storage resolver now belongs to `WslDiskIdentity.ps1`;
synthetic and production owners reuse it. Production does NOT source a fixture
harness or diagnostic. Disk operations here only OBSERVE module-qualified Storage
objects; no attach/mount/format/registration/startup exists in custody execution.

Apply/Rollback are supported only from a fresh noninteractive PowerShell process,
protected reviewed source, exact externally reviewed plan SHA and actual elevated
current owner. Root/controller independently verifies the signed archive/deployment
before invocation; a manifest/hash is not authority by itself. All source/manifest/
plan/receipt inputs are regular canonical single-link files held read-only with
write/delete exclusion and rehashed/reidentified through the transaction. Empty
tracked source files are still bound. Protected ancestry prevents untrusted source
substitution; pre-existing CLR types at the CLI refuse to avoid stale loaded code.
Native named/held GUID paths are compared, not only volume serial/file index.

The same original MAXIMUM_ALLOWED/no-delete-share root handle survives forward,
namespace copy, inverse and final evidence. Exact native volume GUID, fresh signed
Storage hardware/capacity observations and held identities are checked before each
write and afterward. A nonblocking per-volume named mutex serializes these maintained
controllers; occupied/abandoned exclusion refuses, without lock breaking or retry.
This is not an OS-atomic security-descriptor compare/exchange against arbitrary
concurrent administrators: controller maintenance must be coordinated and trusted
Admin/System/TrustedInstaller remain outside the untrusted-principal threat model.
Device removal/rebind, source drift, expiry or uncertain validation refuses; it is
never converted into a cleanup/rollback success. Native synchronous calls have no
claimed hard cancellation latency. Root retains and investigates uncertain attempts.

SACL absence must now be OBSERVED, not inferred from OWNER/GROUP/DACL-only reads.
The new scoped duplicate-thread token requires BOTH SeRestorePrivilege (foreign
owner inverse) and SeSecurityPrivilege (read-only security observation). A separate
compatible metadata handle requests ACCESS_SYSTEM_SECURITY and queries
all nine SDK security component flags explicitly (mask0x1ff), including audit,
label, resource, scope, trust and access-filter SACL data. Any observed
SACL (even empty), unsupported control/reserved data, or unavailable access/API
refuses BEFORE root mutation. No SACL/group/control/attribute setter is used;
NtSetSecurityObject selects only OWNER+DACL. This adds a concrete real-host
prerequisite: old permission-candidate proof did not certify this new full security
observation. No process/account privilege, security policy or host setting is changed.

[GetSecurityInfo](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-getsecurityinfo)
documents the required access/privilege and warns that querying is not race handling.
[SECURITY_INFORMATION](https://learn.microsoft.com/en-us/windows/win32/secauthz/security-information)
distinguishes the umbrella BACKUP selector from individual label/attribute/SACL
selections. The [Microsoft SDK header](https://github.com/microsoft/win32metadata/blob/main/generation/WinSDK/RecompiledIdlHeaders/um/winnt.h)
defines the nine explicit component flags through ACCESS_FILTER_SECURITY_INFORMATION.
The first hosted implementation opened its read handle but BACKUP query returned
Win32 5 before mutation. That failed source/host proof is retained; the new plan
binds `explicit-security-components-v1:no-sacl:0x1ff`. No failed query falls back
to a smaller selection. Synthetic audit and integrity-label cases must refuse. Missing capability is a refusal, not skipped-green production acceptance.

The evidence parent must have admin-protected ancestry/authority. Each attempt is
NEW, private, protected, Admin-owned, with SYSTEM/Admin full and current user read-only
access. Public parent traversal is allowed; its child journal does not inherit public
read/write grants. The per-plan UUID determines its exclusive attempt directory,
so even an unsuccessful created attempt cannot be replayed/adopted by the same plan.
An existing directory always refuses. No old fixture, production journal or arbitrary
caller destination is adopted. The parent and attempt are continuously held;
there is only ONE DELETE-requesting lease per directory, avoiding earlier self-conflict.

Before the FIRST native write, exact reviewed input bytes are independently copied
and flushed into the journal, and `prepared.json` retains original/requested raw
snapshots and review context. Each write first flushes a NEW intent, then rechecks
external bindings and full raw CAS. Readback raw evidence is flushed BEFORE meaningful
comparison/acceptance. `ObservedOnly` is distinct from `Accepted`; an error after a
setter may have mutated and is `Unconfirmed`. Best-effort failure observation is
read-only evidence, not an operation retry. No failed journal/write/readback is
silently accepted. Failure records cannot replace the original exception. Handle,
mutex and scoped privilege ownership unwinds on setup/operation/cleanup failures;
cleanup failure is reported, never inferred as restoration.

Forward is ONLY the deterministic reviewed `Restricted(currentUser)` transformation;
its inverse ONLY the original descriptor. The existing bounded parser/zero-unused
capacity comparison remains unchanged. Full raw CAS uses the actual CURRENT observed
hash, never predicted compact bytes or a permission hash. Owner/group/control,
ordered ACE bytes/flags/masks/SIDs, ACL revision/reserved fields and exact child
inheritance projection remain strict. Unsupported object/conditional/SACL/malformed/
nonzero-free/outer-tail forms refuse. There is no Set-Acl/SetSecurityInfo recursion,
protection transition, descriptor canonicalization or old-child enumeration. Actual
prior constrained root/subtree proofs support this specific inheritance-preserving
shape, not arbitrary NTFS policies. Existing WSL children are NOT made private.

After accepted forward mutation, only NEW protected public authority and private
empty-data namespaces are installed from the held exact source. No service/task/WSL
activation is performed. If public-code copying/final evidence fails, an inverse is
attempted ONLY from the engine's accepted observed after-state, after independently
journaled failure and a bounded known-public/empty-private namespace observation.
It uses the SAME original handle/full raw CAS. Binding drift or uncertain forward
prevents an inverse; failed/partial namespaces and every receipt are retained. No
prune/delete/repair/adoption follows. Restoring the old root also restores its parent
DELETE_CHILD fallback: retained namespaces are then NOT accepted authority/private
custody even if their own DACLs remain protected. No real secrets belong there before
separate deployment acceptance.

A later independently invoked inverse requires original reviewed Apply plan+SHA,
independently reviewed production apply-observation/acceptance receipt+SHA, and a
NEW fresh RollbackOnly plan+SHA. The original Apply plan may be expired as a historical
baseline; it cannot authorize a new forward write. Receipt context must bind that
original review/source/UUID/root identity; synthetic or unrelated receipts refuse.
Observed-only receipts are revalidated from raw data and never promoted by a status
label. Their actual after-state must match the approved forward permission identity
AND current full raw descriptor. Later current raw edits/substitution refuse.
The new inverse plan binds the original before/after scope and exact observed raw
CAS; it cannot change the original target or source policy. Every reference stays
held and rehashed. No plan predicts kernel compaction.

Only the bounded NEW namespace may be inventoried for an inverse: at most512entries/
16MiB public source, exact signed file paths/hashes, no reparses, private data EMPTY.
Unknown/private files refuse BEFORE reading them. Missing public files are retained
partial evidence, not adopted. Root/child descriptor/metadata/content snapshot must
match fresh review and remain unchanged across inverse. No scan/read/rewrite of old
WSL/user descendants occurs. If deployment has begun using the namespace, controller
must stop and obtain a separate storage-owner disposition; rollback is not a way to
silently expose production private data.

Root review interfaces ONLY (not source-lane execution):

```powershell
# NEW protected source/manifest, independently protected different-hardware
# evidence parent and explicit private policy v2. No E plan is created by native.
& PACKAGE\scripts\Invoke-WslColdVolumeCustody.ps1 -Phase Plan -PolicyPath REVIEWED_PRIVATE_POLICY_V2
# Save/recompute exact plan; current source/host/SACL/capacity review then owner UAC.
pwsh -NoLogo -NoProfile -NonInteractive -File PACKAGE\scripts\Invoke-WslColdVolumeCustody.ps1 -Phase Apply -PlanPath REVIEWED_APPLY_V4 -ReviewedPlanSha256 EXTERNAL_REVIEW_HASH
# A later inverse has its OWN observation/review. Never reuse a guessed after hash.
& PACKAGE\scripts\Invoke-WslColdVolumeCustody.ps1 -Phase PlanRollback -PlanPath ORIGINAL_APPLY_V4 -ReviewedPlanSha256 ORIGINAL_REVIEW_HASH -ApplyReceiptPath REVIEWED_APPLY_OBSERVATION -ReviewedApplyReceiptSha256 EXTERNAL_RECEIPT_HASH
pwsh -NoLogo -NoProfile -NonInteractive -File PACKAGE\scripts\Invoke-WslColdVolumeCustody.ps1 -Phase Rollback -PlanPath NEW_REVIEWED_ROLLBACK_V4 -ReviewedPlanSha256 NEW_EXTERNAL_REVIEW_HASH
```

Hosted Windows production-shaped tests use ONLY fresh private C synthetic roots,
the same engine and a separately marked synthetic journal. They prove intent-before-
mutation, observed raw chain, retained-handle/fresh inverse, exact descendants,
source/hardware-observer and intent-file failures before native calls, and raw drift
refusal BEFORE defensive cleanup. They do NOT prove independent hardware, a real
production volume, or the whole controller admission. Those remain controller
source/host review and actual read-only E plan gates before any real mutation.

No real E apply/rollback is accepted by this source promotion. Full repository keyfile
bootstrap/init/export/off-laptop Google+Apple recovery, final immutable worker/policy/
device/cgroup admission, all-writer outage, fresh shared-E dense restore plus positive
overhead plus64GiB reserve, encrypted full backup/readback and independent dense
restore/import/boot remain open. Codex state relocation stays behind restore. Desktop
RPC, Node24 strict offline producer, busctl rotation, Python/Nix/provenance and BOTH
standard IDE entries and custom RevealUI Zed return remain required. Overall NOT GREEN.


#### Initial untrusted-root bootstrap is a distinct unsupported admission

Audit found a genuine bound on promotion: Windows descriptor query and mutation
are separate operations. MAXIMUM_ALLOWED/no-delete sharing prevents substitution,
not a second handle requesting WRITE_DAC only. A fresh synthetic ordinary-token
regression demonstrates that read-only open while the retained lease exists,
without changing the descriptor. No supported atomic NTFS OWNER+DACL CAS has been
established. Named mutexes serialize our controllers, not untrusted applications.

Production now additionally requires `trusted-root-security-writers-v1`: actual
owner SYSTEM or Administrators, no effective WRITE_DAC/WRITE_OWNER grant outside
those principals. Inherit-only templates remain distinct from effective root rights;
DELETE/DELETE_CHILD may remain as the explicit repair target. This disposition is
computed from actual raw policy state, included in the read-only plan and checked
again from the held handle at execution/every write. It is NOT a supplied approval
boolean. Fresh synthetic admission is explicitly separate and its receipts cannot
activate a real volume.

The observed unresolved E owner plus Everyone FullControl FAIL this admission.
The new controller can produce a concrete read-only plan/disposition; it cannot
safely bootstrap that starting state under the claimed CAS contract. Actual volume
root permission fidelity proof does not prove exclusion of concurrent untrusted
security writers. No real E mutation is promoted by this source turn. A separately
supported trusted-maintenance/bootstrap contract must establish that exclusion (or
an atomic supported transition) before source promotion for this initial E state.
No such primitive/proof is claimed here. This is a platform/initial-state gap, not
missing owner authorization, a request to weaken verification, an invitation to
route E through synthetic code, or permission for a one-off offline/raw rewrite.
All-writer outage alone must not be labeled an OS-enforced descriptor lock.


#### Full-security observation admission remains unaccepted

Hosted Windows confirmed that the explicit component query succeeds, while the
fresh synthetic source directories return SACL/control information rejected by
the no-SACL production contract. The new transaction cases remain FAILED; they
are not skipped or relabeled green. The earlier BACKUP umbrella-query failures
remain retained separately. A bounded READ-ONLY `ObserveSecurityComponents` result
now preserves the full returned descriptor, raw hash, exact control/reserved data,
SACL pointer presence/allocated bytes/ACE count, mask and held root identity.
It grants no capability and performs no setter. Fresh synthetic failure output
includes this nonsecret observation for controller/source review. Existing root
metadata must not be normalized or rewritten to make the absence check pass.

A further supported security-observation/preservation contract needs review of
those actual returned fields, including null versus empty and label/attribute/
other security data. No such expansion is approved or implemented by inference
here. Together with the initial untrusted-writer bootstrap, this BLOCKS real E
promotion. The read-only production plan and journals/inverse code are reviewable,
but successful native modeling, old volume fidelity proof or an implemented path
is NOT whole-production readiness. Keep the failing hosted cases and exact gate
in the source PR/checkpoint until a sound contract is established.

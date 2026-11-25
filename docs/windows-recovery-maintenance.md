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
the existing verified-image inventory. The native fixture has demonstrated an
actual unprivileged Borg1.4.5 ext4 round trip; privileged metadata, independent
key recovery and full WSL restore acceptance remain missing. The
controller alone owns real destination/maintenance approval and later deployment;
this increment changes source library/adapter bytes, not the accepted Windows
release. There is no automatic retention, repair, compaction or lock breaking.

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

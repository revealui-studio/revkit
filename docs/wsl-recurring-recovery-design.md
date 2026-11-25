# Recurring WSL recovery under bounded storage

Status: selected source design under GAP-301, 2026-11-25; **production execution
unavailable**. The maintained adapter implements readiness and evidence contracts
only. No tool installation, repository/key initialization, disk write, mount,
schedule, archive creation or recovery boot is authorized by this document.
Preserve the only last-good image and the existing full-export capacity refusal.

## One incremental design

Select **Linux Borg 1.4.5, offline filesystem archives**, with an encrypted
`repokey-blake2` repository. This supersedes the earlier Restic VHD-stream
assessment mentioned in Windows maintenance documentation and the controller's
historical DESIGN.md. That E record remains controller-owned; it was read, not
rewritten. Restic is not an additional production backend in RevKit.

| Criterion | Selected Borg filesystem approach | Assessed Restic VHD/file stream |
| --- | --- | --- |
| Linux recovery metadata | Documented numeric ownership, permissions, links, ACLs, xattrs and Linux flags; verify the actual filesystem/tool build | VHD bytes can encapsulate metadata, but require reconstruction of the whole image before filesystem verification; native file backup omits Unix inode flags/creation time |
| Consistent source | Stopped source, exclusive image lease and clean read-only ext4 view in an independent maintenance environment | Also requires a stopped, stable image/producer; streaming does not make a live VHD consistent |
| Completeness | Source inventories and zero-warning successful create/check/dry-extract stages | `--stdin-from-command` rejects a failed producer, but a plain stdin pipe does not prove completeness |
| Capacity | Budget a whole logical filesystem generation plus reviewed overhead and reserve; credit no deduplication | Chunk reuse can reduce later image storage, but image/stream restoration still needs an independent full target |
| Keys and restore | Exported key plus passphrase recoverable with source unavailable, then actual metadata comparison and isolated WSL restoration | Also requires independent key recovery and a real restore; sparse output alone is not recovery acceptance |

Borg's documented feature set is a reason to select this design, not proof that a
particular installation preserves the owner's data. No backend is installed on
this native host (`command -v borg` and `command -v restic` found neither), and
RevKit has no reviewed isolated Borg installer. No binary was downloaded or
package installed for this increment. A real Borg fixture remains a prerequisite.

## Current capacity, without optimistic credits

Controller measurements supplied for this source turn:

| Quantity | Bytes |
| --- | ---: |
| Root ext4 used | 604,949,360,640 |
| Root ext4 available inside the current VHD | 421,159,460,864 |
| E physical available | 271,653,101,568 |
| C physical available | 238,336,782,336 |
| Earlier secondary volume free, now detached | 943,636,373,504 |
| Protected read-only recovery image | 633,995,264,000 |

The secondary volume was inspected read-only; its identity, destination approval
and fresh free-space measurement are still required. Existing data stays intact.
A source-used-sized estimate plus 64 GiB leaves 269,967,536,128 bytes on that
volume **before repository overhead**. This supports assessment of one archive,
not approval of a production size bound or a full restore. Source used blocks
are not the sum of logical file lengths: sparse files and filesystem/repository
metadata require separate accounting.

`Get-WslBorgCapacityPlan` requires positive logical-data and metadata/overhead
upper bounds, and at least 64 GiB reserve. The overhead bound must cover the
reviewed Borg representation, indexes, encryption/segments and temporary growth;
it must be tied to the complete source inventory and independently reviewed.
Unmeasured overhead is not zero. The plan assumes the entire next generation is
unique, with no compression, deduplication or deletion credit. Cache and workspace
placement need their own per-filesystem capacity proof outside the read-only
source. A numerical fit is conditional on those supplied bounds, not a disk probe.

E and C cannot individually stage the measured filesystem or full image. The
secondary cannot conservatively hold both a source-sized repository and a
source-sized independent restore with reserves. **Additional independent full
restore capacity remains an unanswered owner dependency.** Deduplication and
compression do not remove this requirement. Do not reclaim the protected image,
original data or the stopped Ubuntu-Recovery-20261124 to make a transaction fit.

## Executable readiness contract in the existing owner

`scripts/lib/WslBackup.ps1` remains the single planner/evidence owner.
`weekly-wsl-backup.ps1` keeps its existing full-image default and capacity gate.
Its explicit read-only entry is:

```powershell
pwsh -NoProfile -NonInteractive -File scripts/weekly-wsl-backup.ps1 -RecoveryBackend borg-readiness
```

It returns JSON with missing prerequisites and exits 3. Optional
`-IncrementalConfigurationPath`, `-IncrementalObservationPath` and
`-ReviewedConfigurationSha256` evaluate a pinned request. `-Execute` always
refuses this backend, even for internally consistent observations. Supplying
incremental inputs to full-image mode refuses rather than silently exporting.
The adapter invokes no Borg, WSL, registry, mount, repository or key operation in
readiness mode. `CanExecute`, `BackendExecuted` and `FullRestoreAccepted` stay
false. This is an executable contract, not a dormant permissive create command.

Configuration and observation files are bounded to 1 MiB. They are hashed and
parsed from the same bytes, reject duplicate/unknown fields, and distinguish
integers and booleans from coerced strings. All configured inputs require an
explicit reviewed configuration SHA256; observations expire after five minutes
and bind that digest. These are local operator records, not authenticated remote
attestations or substitutes for independent probes.

The exact version-1 object fields are defined by `Assert-WslRecoveryFields` in
the owner. Private behavioral fixtures in `tests/powershell/WslBackup.Tests.ps1`
construct a complete specimen; they are model data, not a ready configuration
for a real disk. Required input groups are:

- `tool`: absolute executable path, exact version 1.4.5, executable SHA256 and
  package/provenance SHA256; the future native observer must actually verify them.
- `source`: distro/VHD identity, offline view, filesystem and physical identity,
  complete inventory SHA256. Fresh observations require stopped state, a clean
  read-only view, a continuously held exclusive source lease, zero producer exit
  and zero read errors. The inventory must enumerate mount boundaries and every
  unsupported entry; do not silently exclude caches, models or owner state.
- `repository`: exact path, repository ID, hardware, GPT partition and filesystem
  identities, identity-receipt digest, encryption and private-access observation.
  It must be on different hardware from source and protected original. Paths
  must be disjoint, including parent/child and Windows case aliases.
- `keyRecovery`: a vault reference and independent recovery-drill digest, with
  the source unavailable. Key/passphrase bytes never belong in JSON or logs.
- `original`: immutable original path, size, digest and hardware identity;
  observations must agree and retain read-only protection.
- `budget`: reviewed logical data, full overhead upper bound and reserve.

An approved independent Linux maintenance environment is required: the running
source cannot back itself up as a stopped filesystem. Do not boot or repurpose
the only recovery distro for this task. Controller-acquired supported source
attachment/view evidence, including exclusion of journal replay on a clean
filesystem, remains missing. Read-only access to an unclean filesystem must not
be silently treated as a complete recovery point.

## Evidence transactions and failure behavior

`Register-WslBorgArchiveEvidence` records supplied attempt observations only,
without executing an archive command. Input bindings must pass before journaling.
The existing private journal must be disjoint from source/repository/original.
A nonblocking exclusive file handle serializes its writers; unsafe lock paths
refuse, handles release on failure, and no lock is deleted or broken. Immutable
transaction UUID filenames use the existing create-new/fsync JSON writer.
Duplicate IDs cannot overwrite pending, failed or completed records.

A pending record remains after success or failure. Admission requires bound
configuration/observation, exact repository/archive IDs, unchanged before/after
source inventory and original digests, held source/repository leases and complete
ordered create, `check --verify-data`, and dry-extract stages. Every exit must be
zero, with no warnings. Borg may finish an archive while warning about skipped
files; that result is rejected. Failed observations leave a failed record and
never an accepted candidate. Input changes during admission also refuse.

The journal lock is **not** a real Borg repository lock. The continuous Borg-lock
fields are operator observations whose future executor must substantiate. Output
is `.archive-evidence.json` with `verified=false`, not `.verified.json`. The
existing full-image monitor cannot mistake it for a restore-verified backup.
There is no retention, prune, compact, repair or lock-breaking path in this
increment. Never remove originals/partials as a recovery from an admission error.

## Restore evidence and actual acceptance still required

`Test-WslBorgRestoreInventory` checks bounded, complete paired inventories against
archive-bound source inventory and a separate restore observation. The latter
binds archive evidence, repository/archive/tool identities and independent key
recovery; it requires source unavailability, original preservation and a target
on hardware disjoint from source, repository and original. Its supported scope
is `bounded-fixture`, never a full production restoration claim.

The comparison covers content digest, numeric IDs, mode, mtime/atime, symlink target,
canonical hardlink group, ACL/xattr digests, inode flags, device major/minor numbers and sparse observation.
Linux case-distinct paths are distinct. Missing/duplicate/escaping/unsupported
entries or metadata drift refuse. Inventories are bounded model/observer inputs;
this source does not yet collect authenticated live Linux metadata or prove a
backend executed. A matching inventory still returns `FullRestoreAccepted=false`.

Actual Borg coverage must next restore regular data, directories, numeric IDs,
ACLs/xattrs (including security attributes), hardlinks, symlinks, FIFOs/devices,
flags and sparse data on a supported filesystem, with inventory comparisons and
zero errors. ctime, inode numbers and other non-restorable/platform-limited
metadata must be explicitly distinguished from restorable attributes; no promise
of identical inode numbers or ctime. Borg cannot be told to disable ACLs/xattrs,
flags or completeness checks. All parents/root metadata must be included. Dry
extraction reads/verifies data but does not test filesystem writes.

A complete independent ext4 target, escrowed credentials with the source absent,
full content/metadata verification and reviewed WSL registration/isolated boot
and user-service acceptance are separate requirements. Preserve the image and
recovery registration throughout. Neither synthetic contracts, a bounded Borg
pilot nor the earlier seven-file extraction closes GAP-301.

## References and retained exceptions

- [Borg 1.4.5 metadata](https://borgbackup.readthedocs.io/en/1.4.5/usage/general.html)
- [Create and warning behavior](https://borgbackup.readthedocs.io/en/1.4.5/usage/create.html)
- [Cryptographic checks](https://borgbackup.readthedocs.io/en/1.4.5/usage/check.html)
- [Extract/dry-run/sparse behavior](https://borgbackup.readthedocs.io/en/1.4.5/usage/extract.html)
- [Encrypted repository](https://borgbackup.readthedocs.io/en/1.4.5/usage/init.html)
- [Independent key recovery](https://borgbackup.readthedocs.io/en/1.4.5/usage/key.html)
- [Restic 0.20 producer/metadata behavior](https://restic.readthedocs.io/en/stable/040_backup.html)
- [Restic sparse restoration](https://restic.readthedocs.io/en/stable/050_restore.html)

Temporary recovery readers stay evidence collectors, never runtime dependencies.
Existing full-export capacity refusal, disabled schedule, all failed staging,
protected recovery image/distro, primary planning files and all21 variants remain
preserved. The controller reports the system manager degraded only because
revealfleet-agent-updates.service refuses "tool executable differs from explicitly
reviewed binding"; user failed units are empty. Preserve that guard. No
reset-failed, rebind, service change or claim of overall migration completion.

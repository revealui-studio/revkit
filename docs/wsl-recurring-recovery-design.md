# Recurring WSL recovery under bounded storage

Status: selected source design under GAP-301, 2026-11-25; **production execution
unavailable**. The maintained adapter implements readiness and evidence contracts
only. Production tool installation, repository/key initialization, disk writes,
mounts, schedules, archive creation and recovery boot require separate approval.
The explicitly invoked private synthetic fixture below is development work only.
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
particular installation preserves the owner's data. Neither backend is installed
system-wide. The installed Ubuntu package index offers Borg1.4.4-3, which does
not satisfy this exact version. A signed standalone1.4.5 binary can now be
verified and used only inside the private synthetic fixture described below;
this establishes no production installation, key recovery or full restore.

## Current capacity, without optimistic credits

Controller measurements supplied for this source turn:

| Quantity | Bytes |
| --- | ---: |
| Root ext4 used | 604,949,360,640 |
| Root ext4 available inside the current VHD | 421,159,460,864 |
| E physical available, latest | 271,652,610,048 |
| Live source VHD, latest | 636,824,322,048 |
| Connected D initial physical available | 499,494,395,904 |
| Media copy under controller verification | 55,569,457,453 |
| Historical backups excluding protected image | 391,210,153,007 |
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

Current E and C free space cannot individually stage the measured filesystem or
full image. The secondary cannot conservatively hold a source-sized repository
and restore together. A fresh restore VHD on E could instead use the independent
backup on the1TB disk while the source VHD/distro is unavailable. This shares
physical hardware with the source and protected image; it is a restore test,
not third-hardware recovery protection.

Controller-approved media and eligible archive relocation to D is conditional
on full verification and source retirement. No native transfer is performed.
Only after BOTH retirements, the supplied totals project E free718432220508
bytes and D remaining52714785444 bytes. E would exceed the measured source-used
plus64GiB reserve by44763383132 bytes, BEFORE new VHD filesystem/repository
metadata and logical sparse expansion. A live-VHD-sized reservation plus64GiB
would leave12888421724 bytes; neither estimate proves an approved target budget.
Fresh physical free space, target identity and complete logical/overhead bounds
must be checked before allocation. Protected image AND proof files stay on E.
Two USB ports require the controller to disconnect D before reconnecting1TB;
a disconnected D cannot serve as the active restore target.

More capacity or hardware is not an unconditional prerequisite for testing a
restore on E. It remains necessary if the conservative target budget does not
fit after verified retirement, or if a third-hardware recovery copy is requested.
Such a third target must be physically disjoint from source/protected original
AND backup repository, with at least measured604949360640 +64GiB =673668837376
bytes before additional reviewed logical/metadata growth; the500GB D is too small
even before these transfers. No third target currently satisfies that guarantee.
Freeing E cannot satisfy hardware disjointness. Do not reclaim the protected
image, proof files or stopped Ubuntu-Recovery-20261124 to make room.

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
with an explicit hardware guarantee. Its supported scope remains
`bounded-fixture`, never a full production restoration claim.

The970cb41 contract introduced a stricter three-hardware rule than the preceding
design's fresh independent ext4 target/source-unavailable requirement. That was
an overconstrained fixture interpretation, not an established owner requirement
for an extra physical recovery copy. These guarantees are now explicit:

| Evidence profile | Target requirement | What a successful real full drill could establish |
| --- | --- | --- |
| Version1 legacy | Hardware disjoint from source, repository and original, unchanged | Retains the original strict interpretation; no silent evidence downgrade |
| Version2 `isolated-restore-test` | Explicit fresh target, distinct source filesystem and disjoint source VHD/view/original paths; hardware disjoint from backup repository | Actual full restoration with source unavailable; report any shared source/protected-image hardware |
| Version2 `third-hardware-copy` | All fresh-target requirements plus hardware disjoint from source, repository and original | Additional hardware redundancy, only after real complete restore acceptance |

Version2 requires `hardwareGuarantee` and `freshTarget=true`; ambiguous/missing
profiles refuse. Archive evidence now also binds sourceVhdx/sourceFilesystemUuid.
Old evidence without those identities cannot support version2. A target sharing
backup hardware always refuses. Shared-hardware booleans and observed topology
are reported separately; both FullRestoreAccepted and
ThirdHardwareRecoveryCopyAccepted remain false for bounded comparisons. A fresh
VHD on E and offline source on E are physically correlated failures, even when
the restore succeeds. The independent1TB repository is the separate recovery
hardware; no additional third-hardware guarantee is claimed by the E drill.

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

A complete fresh isolated ext4 target under the explicitly recorded hardware
profile, escrowed credentials with the source absent,
full content/metadata verification and reviewed WSL registration/isolated boot
and user-service acceptance are separate requirements. Preserve the image and
recovery registration throughout. Neither synthetic contracts, a bounded Borg
pilot nor the earlier seven-file extraction closes GAP-301.

## Maintained isolated Borg fixture and native observer

`scripts/wsl-borg-fixture.py` extends the existing PowerShell planner/evidence
owner with native Linux observations; no existing Python backup observer existed
to extend. It is a fixed synthetic-data runner, not another production backend.
Default invocation is a read-only plan. Explicit development use:

```sh
python3 -B scripts/wsl-borg-fixture.py --run --parent /absolute/approved/ext4/development-directory
```

It requires non-root Linux x86_64, an existing canonical owner directory on ext4,
and at least1GiB free, outside any Git source checkout. It creates only a unique0700 child with a fixed dataset
under33MiB logical data. Ordinary mode accepts no root execution or operator
source/repository/archive arguments. No mode mounts or changes real backup
devices, creates production keys or installs system tools. It creates an
**unencrypted synthetic repository**, with no encryption secret/key recovery
claim. Download, unpack, HOME, Borg config/cache/security and GnuPG files remain
inside that private child. Results and failed attempts remain for review; no
prune, repair, lock-breaking or automatic cleanup runs.

The upstream glibc2.31 x86_64 binary is pinned by SHA256
`c8457f70660064d0f45b38283ab4cc65b342970012013201d3aec713a75898fb`;
its detached signature is also pinned. Before executing anything from the
release, system gpg/gpgv verifies the signature against the full upstream primary
fingerprint `6D5BEF9ADD2075805747B70F9F88FB52FAF7B393` from official security docs,
then the runner requires the exact native version. Keyserver transport is not
trusted for identity; signature and pinned full fingerprint are required. No
user keyring/trust/auth config is changed. `--release-inputs` can reuse retained
bounded downloads; it copies and repeats every hash/signature/version check.
No installation into PATH or production identity approval is granted.

Create uses numeric IDs and atime, followed by full `check --verify-data`, dry
extraction and actual numeric-ID/sparse extraction. Nonzero status or unexpected
Borg diagnostics refuses. The original synthetic source is renamed away before
check/extract, and the observer compares actual data, ownership/modes, nanosecond
times, access/default ACLs, user xattrs, root/parent directories, links, FIFO,
owner-settable NODUMP and sparse allocation. This is source-path absence, not
OS-enforced disk isolation, a continuously held source/Borg transaction lease,
or a full consistency proof. No fixture observation is automatically admitted
to production readiness/evidence. `fullRestoreAccepted` stays false.

Actual privileged receipts remain unavailable: foreign UID/GID restoration, devices,
security/trusted xattrs/capabilities, immutable/append-only flags. There is no
sudo, user namespace workaround, permission change or fake privileged observation.
The sandbox's one-UID map cannot represent the named ACL subject; actual ACL
fixture tests require normal approved native execution or must report refusal.

The real8MiB sparse pilot correctly failed strict comparison: default Borg
chunking restored its bytes fully allocated despite `--sparse`. A32MiB hole spans
multiple chunks and tests successful sparse allocation separately. Neither
Borg nor this observer promises exact original extent layout or universal hole
preservation. Budget logical allocation and record/refuse material allocation
expansion; the retained failed pilot must not be erased or recast as acceptance.
Current native receipt: ten real entries passed create, full data check, dry
extract, actual extraction and strict metadata comparison. Seven observer/refusal
tests passed under normal approved native execution. The PowerShell suite has
33 backup-contract tests plus13 host-script tests (46 total); controller's prior
31 Windows backup tests apply to970cb41 only, not this new source. These local
results do not establish Windows execution or privileged Linux cases.
ctime/inode identity and a third physical device are outside this fixture.

The first source push was refused by the normal private-path leak hook because
retained fixture/cache receipts under the development checkout contain absolute
private paths. No exclusion, hook bypass, deletion or receipt rewrite was used. The
runner now refuses a parent inside a Git checkout before creating files, fixing
future evidence placement. Normal automatic approval subsequently allowed a
dedicated private ext4 custody directory outside Git and same-filesystem rename
of only this turn's four attempts. Before/after manifests verified unchanged
file bytes, modes, IDs, inode/hardlink identity and mtimes; receipts/cache records
retain their original bytes and historical paths. This corrects artifact custody,
not scanner policy. Future runs use the approved private location; publication
still must pass the unchanged normal hook. This grants no real backup-disk writes.

## References and retained exceptions

- [Signed standalone installation](https://borgbackup.readthedocs.io/en/1.4.5/installation.html)
- [Release fingerprint/signatures](https://borgbackup.readthedocs.io/en/1.4.5/support.html)
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


## Controller-only privileged metadata fixture

The ordinary `--run` guard still refuses root. New `--run-privileged` is a
separate controller-only protocol, never an elevation/override of that guard.
No privileged operation was run by the native source agent. Obtain the exact
reviewed source/release hashes and controller argument array without writes:

```sh
python3 -B scripts/wsl-borg-fixture.py --privileged-plan
```

After source/signature review, the controller must stage that exact source and
the three retained release inputs (borg, borg-linux-glibc231-x86_64.asc,
release-key.asc) as regular root-owned, non-group/world-writable files beneath
`/var/lib/revkit-synthetic-fixture-tools/<sourceSha256>/`. Copy source from the
reviewed signed commit, not a subsequently editable checkout. Verify every
reported SHA256 before any root execution; public key bytes are pinned in this
mode as well as the upstream full signer fingerprint. Root must not execute
user-writable source or nvm tools. Use a trusted root launcher with clean loader
environment; do not use an interactive shell or bypass controller approval.
The generated argv uses system Python with -I -B and a clean process environment.

The controller creates the staging base `/var/lib/revkit-synthetic-fixtures`
root-owned mode0700 beforehand, on the existing native root ext4 filesystem.
Only a NEW canonical UUID child is accepted; even an existing empty directory
refuses. The example UUID in the plan is single-use; select a fresh UUID if that
leaf exists. Never remove/overwrite an earlier attempt to reuse a name. Symlink,
unsafe ownership/mode, Git, subordinate/bind-mount ancestors, non-ext4 and low
space refuse before workspace creation. Arbitrary source/repository/backup paths
are not accepted. Native initial user namespace is required; no namespace or
kernel/security-policy workaround is provided. Root preflight uses only fixed
staging paths, reviewed input files, mount metadata and system tool identities.
No download, host account/service/mount/device configuration is supported.

The fixed ordinary dataset is extended with non-executable foreign numeric
UID65534/GID65533 data, block/character nodes with device number0:0, a
non-executable security.capability file (revision2 CAP_NET_BIND_SERVICE metadata),
a trusted synthetic xattr, and separate immutable/append-only data files.
The observer uses lstat/rdev and xattr metadata for nodes, never content reads,
open, ioctl or execution on device nodes. Borg commands are fixed and never use
--read-special; its default archives node metadata rather than device streams.
Only regular files/directories are opened for content/flags. No SELinux/AppArmor
labels, host capabilities, accounts or security policy are changed. Capability
and inode-flag operations affect only newly generated private synthetic files.

Each case records preparation/unavailable errno. Prepared properties must also
be observed in the source inventory before backup, then match the actual restored
inventory. A successful syscall alone is insufficient. verifiedPrivilegedCases
reports only round-trip-compared cases. Any unavailable case means passed=false,
privilegedMetadataVerified=false and CLI exit3, even if other cases compare.
Unexpected errors/warnings leave failed.json and refuse. EIO/ENOSPC are not
converted into capability gaps. Immutable/append files and all attempts remain;
no cleanup, flag clearing, prune, repair or lock breaking is implemented.
Production execution/full restore remain false; encrypted key recovery, offline
consistent-source backup and full WSL/hardware recovery remain separate gates.

Sparse semantics are unchanged: `sparse` means logical size exceeds allocated
blocks, not identical extent layout or identical block count. allocatedBytes is
now retained separately, and different allocated amounts are allowed only when
all semantic metadata/content AND the sparse boolean still match. A sparse source
restored fully allocated still refuses, including the retained8MiB failure.
Allocation reporting budgets the full logical bytes with zero sparse credit;
metadata/reserve are additional. No older receipt is rewritten or promoted.
The later32MiB-hole success does not resolve the small-hole failure. Windows
PowerShell evidence remains strict on its existing sparse property and is not
changed by this Python-only increment; prior Windows receipts remain historical.


## Synthetic encrypted recovery and sparse matrix

`wsl-borg-fixture.py --run-recovery --parent <approved-private-ext4-parent>
--release-inputs <retained-release-input-directory>` is a separate ordinary-user
experiment. It refuses root and source checkouts, creates a new private workspace,
reverifies all three pinned inputs plus the upstream signature, and accepts no
user source, repository or key arguments. No production executor is enabled.
Its fixed dataset is50,602,004 logical bytes; reserve at least1GiB free. Repeated
attempts accumulate retained custody; inspect capacity before another run.

A new repokey-blake2 repository receives synthetic content. Random synthetic
passphrases are created with exclusive mode0600 files inside private0700 custody;
only the documented BORG_PASSPHRASE_FD descriptor number reaches Borg's environment.
No value fallback, ambient client state, secret output or secret hash is recorded.
The encrypted key export and a separately stored passphrase copy are retained in
recovery-artifacts. These are independent of the original client paths, on the
same filesystem: this does NOT prove off-laptop or separate-hardware key custody.

After export, the fixture models loss of the embedded repokey by removing only
the key option from its NEW synthetic repository config with an atomic private
replacement. Borg1.4.5's config CLI rejects key deletion (its option allowlist
excludes key), so it is not used for this fault injection. No real repository may
be supplied. An active repository lock, absent export or symlink refuses. The
original synthetic client/source are renamed and never supplied to recovery
commands; this proves path absence and fresh-state dependency isolation, not an
OS-enforced denial of same-owner access. Evidence and original client are retained.

A fresh HOME/config/cache/security state must receive modern Borg error44 before
key import and error52 with a wrong passphrase after import; arbitrary failures
cannot satisfy those controls. Import from the explicit export, check --verify-data
and actual restored content/non-allocation metadata comparison must then succeed.
Backend stdout/stderr remain undisclosed; receipts contain byte counts and exact
exit codes only. The recovery export remains encrypted and requires its original
passphrase, as described by [upstream key recovery](https://borgbackup.readthedocs.io/en/1.4.5/usage/key.html).
[Passphrase FD and modern errors](https://borgbackup.readthedocs.io/en/1.4.5/usage/general.html)
are supported upstream interfaces; errors44/52 are defined in the
[pinned key implementation](https://github.com/borgbackup/borg/blob/1.4.5/src/borg/crypto/key.py).

The same five-file matrix is archived with default chunking and separately with
`--chunker-params=fixed,65536 --sparse`, then extracted using --sparse. Cases have
8KiB,256KiB,8MiB and32MiB head/tail holes and an8MiB mixed-data layout. Inventory
records original/restored logical length, allocation, content SHA256, ownership,
mode, nanosecond times, ACLs, xattrs and flags. The strict comparator is unchanged;
each policy/case reports its own rejection. completed=true means the experiment
finished; it is not a blanket sparse/full-restore acceptance flag.

Actual native ext4 observation reproduced default extraction's sparse-to-allocated
failure for all cases except32MiB. Fixed64KiB input-hole detection preserved all
five tested cases, including content and metadata, with matching allocated amounts.
This agrees with [create](https://borgbackup.readthedocs.io/en/1.4.5/usage/create.html)
(input hole detection requires the fixed chunker) and
[extract](https://borgbackup.readthedocs.io/en/1.4.5/usage/extract.html)
(sparse output operates on all-zero chunks). A hole embedded in a mixed default
chunk cannot be reproduced by that extraction path. The old8MiB failure and later
32MiB success remain separate unchanged evidence; no receipt is rewritten.

The maintained candidate for NEW archives is fixed chunking with input-hole
recognition, followed by strict restored-inventory acceptance. This does not repair
existing archives, guarantee arbitrary/unaligned/dense-zero layouts, or establish
privileged metadata fidelity with this candidate. Root's accepted fixture used
the existing default archive profile. Chunking changes deduplication/cache/index
cost and may alter non-sparse allocation; production policy requires further
bounded acceptance and capacity measurements before adoption. Existing archives
that fail sparse comparison remain rejected; no in-place rewriting/hole-punch
workaround is offered. Full logical lengths plus reserve/metadata are budgeted,
with zero compression/dedup/sparse credit even when observed allocation matches.

Controller-reported accepted synthetic root metadata evidence closes its seven
cases only. Actual independent key/passphrase custody, offline consistent source,
full WSL restore/boot, restore capacity and independent hardware recovery remain
unproved. No production backup, key, disk, mount, service or activation changes
are part of this increment. No PowerShell module changed; Linux fixture results
are not actual Windows execution evidence.

# Recurring WSL recovery under bounded storage

Status: selected source design under GAP-301, 2026-11-25; **production execution
unavailable**. The maintained adapter implements readiness and evidence contracts
only. Production tool installation, repository/key initialization, disk writes,
mounts, schedules, archive creation and recovery boot require separate approval.
The explicitly invoked private synthetic fixture below is development work only.
A distinct cold-vhd-container-v1 byte-custody alternative is now maintained as
readiness/synthetic transport only; it is not approved for production or a change
to the filesystem profile. See the final section for that explicit assessment.
The named fixed64KiB candidate has an observed dense-to-sparse rejection; legacy
privileged and encrypted proofs remain separate. See the combined-profile audit below.
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

The original ordinary-only baseline did not cover foreign UID/GID restoration,
devices, security/trusted xattrs/capabilities or immutable/append-only flags.
The controller subsequently accepted those seven synthetic cases under the legacy
archive profile; they are not evidence for a different candidate profile. There is no
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

The initial candidate for NEW archives was fixed chunking with input-hole
recognition, followed by strict restored-inventory acceptance. The expanded
combined-profile audit below now rejects dense-zero/dense-mixed allocation loss;
this candidate is not broadly adequate for the maintained density contract. This does not repair
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


## Combined fixed-profile candidate: explicit rejection remains evidence

Audit anchors before this increment were fixture382, privileged source293,
metadata comparison169, key-recovery fixture559 and matrix491 in
`scripts/wsl-borg-fixture.py`; readiness/capacity/restore remain owned by
`scripts/lib/WslBackup.ps1`:353/372/596. The native observer and PowerShell
contracts intentionally serve different roles (real fixed synthetic observations
versus non-executing request/evidence validation). Legacy privileged and encrypted
ordinary proofs also intentionally stay separate. Extending shared provenance,
workspace, source construction and comparison avoids accidental parallel owners.

The separately named `fixed64k-input-holes-v1` profile is selected explicitly:

```sh
python3 -B scripts/wsl-borg-fixture.py --run --profile fixed64k-input-holes-v1 --parent <approved-private-ext4-parent> --release-inputs <retained-release-input-directory>
python3 -B scripts/wsl-borg-fixture.py --privileged-plan --profile fixed64k-input-holes-v1
```

The ordinary/default root refusal, root-owned source-addressed sealed bundle,
fixed staging base, new UUID leaf, no-mount/no-device-read guard and exact
metadata comparator remain intact. No default/production backup profile changes.
Receipts and the root plan bind profile ID, create/extract options, dataset and
comparison policy. Root runs add the seven actual prepared privileged cases into
THE SAME archive as the complete ordinary/layout dataset. No old receipt/import
path exists. Missing expanded layouts cannot produce combinedCandidateAccepted;
missing/changed/unavailable privileged cases also prevent that flag. Per-case
actual matches remain distinguishable from overall candidate rejection. This
candidate still uses an unencrypted synthetic repository; earlier key recovery
is separate and does not become a combined encrypted/production proof.

The expanded dataset adds thirteen layout files to the ordinary metadata tree:
the prior five shapes plus empty, all-hole, unaligned hole, one-block hole,
sub-block logical zero gap, trailing hole, dense zeros and dense mixed chunks.
Sources must actually exhibit their intended density/SEEK_DATA-HOLE properties;
unsupported range observation/preparation refuses rather than inventing coverage.
Only generated regular files are opened for bounded range observation, never
block/character entries. Source and restored range maps are supplementary cost/
layout evidence; exact extent equality is not a promised restored attribute.

The **existing v1 density contract** remains exact in both directions: for each
regular file sparse means logical size exceeds st_blocks*512; a zero-length file
is not sparse, and allocated zero bytes are not evidence of a hole. Thus sparse
to dense AND dense to sparse both reject, even with identical content. A short
logical zero gap may occupy a data block and need not be a filesystem hole.
Equal allocated-byte counts/extent layouts remain unnecessary when the boolean
and all other restorable content/metadata match. No comparison was loosened to
make the new candidate pass, and all previous rejections remain preserved.

Actual ordinary native execution of this profile returned exit3/passed=false.
The24-entry dataset was85,129,290 logical bytes. All content and other compared
metadata matched; only these density cases rejected:

| Case | Logical bytes | Source allocated | Restored allocated | Density result |
| --- | ---: | ---: | ---: | --- |
| dense-zero | 262144 | 262144 | 0 | false -> true, rejected |
| dense-mixed | 196608 | 196608 | 131072 | false -> true, rejected |

Empty/all-hole, unaligned/short/trailing holes, the sub-block logical gap and
all five preceding shapes matched. This is actual ordinary evidence only;
combined privileged execution is PLANNED for the controller, not performed by
the native source agent. The controller should expect exit3 if these density
failures reproduce, even when all seven privileged cases independently match.
No overall candidate readiness can be inferred from that root run.

Pinned Borg1.4.5 `chunker.pyx`:191-205 distinguishes allocated-zero and hole chunks
while reading; `archive.py`:1239-1255 and1296-1311 converts both to identical
zero data/chunk references, and extract858-875 makes holes for all-zero chunks.
The allocation distinction is therefore unavailable to ordinary --sparse extract:
[chunker](https://github.com/borgbackup/borg/blob/1.4.5/src/borg/chunker.pyx),
[archive](https://github.com/borgbackup/borg/blob/1.4.5/src/borg/archive.py).

**Owning design fix still required:** an archive/source/tool/profile-bound
allocation-class manifest (hardlink groups must agree), preserved under archive
integrity, plus a reviewed native restore policy that uses sparse output only
for source-sparse groups and dense output for source-dense groups. Exact extent
preservation, if later required, needs a distinct explicit contract. Selection
must handle literal paths, hardlinks, complete directories, metadata/flag order
and final root timestamps safely; tests must include all privileged cases and
mixed density groups before adoption. The current single global --sparse
extraction is inadequate for the maintained v1 density policy. This is a design
follow-up, not an implemented executor or an in-place hole-punch workaround.
Existing archives lacking bound allocation provenance cannot simply be promoted.

## Chunk/index/cache cost audit and bounded arithmetic

Candidate source length stays below128MiB, paths at most64 and observed data/hole
ranges at most256 per regular path. Range lengths must be positive contiguous
integers covering the exact observed file size; missing/partial/oversize census
refuses before archive creation. Empty files contribute no data chunks. The
helper deliberately counts hardlink aliases independently and credits no reuse.
It sums ceil(rangeLength/65536) at EACH observed range boundary, rather than
ceil(totalBytes/65536); short files and extent splits matter. This is a fixed
fixture chunk-reference model, not a complete repository object count.

[Upstream index estimates](https://borgbackup.readthedocs.io/en/1.4.5/internals/data-structures.html#indexes-caches-memory-usage)
use40 bytes/repository-index entry and44/chunk-cache entry, with load-factor and
growth variation. The helper reports those84 bytes/reference and a12x sensitivity
(0.25 load factor, old plus2x growth), explicitly NOT a total memory/disk bound.
The actual ordinary specimen has37 observed ranges/1325 modeled references:
111300 base bytes,1335600 growth-sensitivity bytes. No metadata chunks, prior
archives, Python/runtime/crypto buffers or filesystem allocation slack are covered.

Disabling files-cache does not remove chunks cache/repository index. The pinned
[cache implementation](https://github.com/borgbackup/borg/blob/1.4.5/src/borg/cache.py)
begin_txn552-569 copies config/chunks/files into transaction state; archive indexes,
cache transactions, new temporary/index/segment files need separate disk budgets.
`ChunkerFixed` builds list(sparsemap(...)) for each file, then chunks each range;
[implementation](https://github.com/borgbackup/borg/blob/1.4.5/src/borg/chunker.pyx):149-205.
Fragmented files can require many small ranges and a large Python extent list.

For sensitivity ONLY, one hypothetical contiguous1TiB file yields16,777,216
64KiB data references,1,409,286,144 index/cache base bytes and16,911,433,728 growth-
sensitivity bytes, before all omitted costs. This is not a measurement/upper bound
for the owner's source. Used ext4 blocks/VHD size are not a logical file census.
Full apparent lengths, file counts, fragmentation and maximum ranges/file,
metadata/xattrs/hardlinks/unsupported entries, existing repository objects,
cache placement and filesystem-specific slack/temporary growth remain unmeasured.
Controller will acquire that full inventory only after archive hashing stops
competing for I/O. No source-wide scan was run here. Full logical source/restore
bytes plus separately reviewed overhead/reserves remain mandatory; sparse,
compression and deduplication credits are all zero. productionBudgetAccepted and
fullSourceCensus remain false in every fixture cost result.

## Remaining path to a reviewable full offline invocation

There is still NO supported production Borg executor to invoke.
`Get-WslBorgReadinessPlan`:372 validates version1 configuration/observations;
CanExecute/BackendExecuted remain false, and weekly-wsl-backup's -Execute refuses
borg-readiness. `Test-WslBorgRestoreInventory`:596 admits only bounded-fixture
observations, never full restore acceptance. Its exact sparse field is unchanged.
Read-WslRecoveryDocument limits JSON to1MiB, and the bounded restore comparator
limits inventories to4096 entries. A real source-scale acceptance path therefore
needs a reviewed scalable complete manifest/observer, not a larger modeled JSON
file or a bypass of those bounds. The concrete supported command today is the
read-only readiness command in the section above. Supplying modeled/fresh JSON cannot turn it into a backup command.

Required ordered inputs/implementation before a full invocation can be reviewed:

1. Resolve the density failure in a separately versioned archive/restore policy,
   bind that policy/manifest to successor readiness/evidence schemas, and obtain
   actual combined profile/privileged/encrypted acceptance. Current v1 schemas
   reject unknown fields and do not bind any candidate/restore-manifest profile.
2. After controller hashing, obtain a complete logical/metadata/extent census
   and reviewed archive/cache/workspace/restore per-filesystem resource bounds,
   including reserve >=64GiB. Refresh exact destination/target free space after
   any independently verified retirement; preserve protected original/proofs.
3. Owner/controller supplies approved independent maintenance environment and
   supported stopped-source attachment procedure: distro/VHD/filesystem/hardware
   identities, clean read-only no-replay view, continuously held exclusive lease,
   all mount boundaries/unsupported entries and zero producer/read errors. The
   active source cannot fulfill this. Do not reuse/boot the only recovery distro.
4. Controller approves exact repository path, fresh identity/GPT/filesystem and
   independent backup hardware receipt, root-safe pinned runtime binding, actual
   encryption/repository identity, independent key/passphrase vault reference and
   source-unavailable drill digest. Synthetic same-filesystem custody is insufficient.
5. Implement/review an explicit fail-closed executor holding source AND repository
   locks continuously, enforcing complete warning/error handling and immutable
   pending/failure/evidence receipts. Existing journal lock is not Borg's lock;
   no retention/prune/repair/lock breaking, originals remain protected. Fresh
   observations bind the exact reviewed config/tool/archive-policy digest.
6. Approve a NEW complete isolated ext4 restore target and explicit guarantee:
   isolated-restore-test can share source/protected-image hardware but never
   repository hardware; third-hardware-copy additionally requires another disk.
   Review allocation, source-unavailable restore, complete data/metadata checks,
   isolated WSL registration/boot/user-service acceptance and preserved original.

The1TB repository hardware is disconnected and not currently approved/probed for
writes. E restore capacity after possible verified retirement is conditional,
not evidence of hardware independence. No key/repository creation, disk/mount,
service/configuration, source shutdown/boot or full backup operation is authorized
or performed by this source increment. Source and actual Windows evidence remain
distinct; no PowerShell module changed or Windows execution is claimed here.

## Separate cold opaque VHD profile (readiness and synthetic transport only)

`cold-vhd-container-v1` is a distinct byte-custody design for a stopped actual
container, not a reinterpretation of filesystem reconstruction. The rejected
fixed64KiB filesystem profile stays REJECTED; no privileged rerun is requested.
Guest allocation maps, ACLs, ownership, special files, flags and data reside inside
the original VHD bytes. Exact entire-container bytes preserve that representation;
outer NTFS sparse/allocation metadata is not preserved: restore writes a NEW dense
private NTFS file. Random bytes matching a digest do not prove VHD/ext4 validity,
cold consistency, boot or recovery acceptance.

Audit reused WslBackup.ps1's bounded JSON reader, path/disjointness/hash checks,
capacity and non-executing readiness conventions. The new owner entry is explicit:

```powershell
pwsh -NoProfile -NonInteractive -File scripts/weekly-wsl-backup.ps1 -RecoveryBackend borg-container-readiness
```

It returns missing gates/CanExecute=false and exit3, without source/registry/WSL
access. Optional IncrementalConfigurationPath and ReviewedConfigurationSha256
validate a bounded version1 request; IncrementalObservationPath refuses because
sampled booleans cannot establish a continuous OS handle lease. -Execute ALWAYS
refuses this profile before touching a source, worker, repository or power state.
The legacy full-image default and filesystem contracts remain strict/unchanged.
RequestBindingsValid is syntax/digest binding only, never operational approval.

The exact request fields are maintained in Get-WslColdContainerReadinessPlan;
behavioral examples in tests/powershell/WslColdContainer.Tests.ps1 are model data,
not real approvals. They bind source/worker names and distinct registration UUIDs,
source VHD path/full container length/hardware, worker source/tool hashes,
repository/restore/original paths and hardware, explicit restore guarantee,
filesystem capacity domains/free space and positive repository/cache/restore
overhead bounds. Shared capacity domains must report the same available bytes;
requirements aggregate per domain with one >=64GiB reserve, full container bytes
for BOTH repository and dense restore, and no savings credits. Worker/cache costs
sharing E with a fresh restore count against the SAME free space. No real
installation, tool binding, repository ID or key custody is inferred from a request.

Controller READ-ONLY evidence supplied active VHD length637998727168, E free
326025490432 and provisional E after eligible archive retirement717235476229.
Dense image plus64GiB is706718203904, leaving only10517272325 BEFORE target
metadata/cache/other costs. Physical retirement has not happened. Final cold size
and actual physical free space must be remeasured under the approved protocol;
logical deletion totals are not proof of released physical capacity. The independent
1TB disk is disconnected, with no current write/repository approval.

Coarse transport proposal: pinned Borg1.4.5, repokey-blake2, fixed4MiB chunking,
files-cache disabled, compression none, stdin-name ext4.vhdx; extract --stdout.
No --sparse and no guest-file reconstruction options apply. At the reported active
length the contiguous data-reference model is152111 chunks, not a measured complete
object/index/metadata/memory/disk bound. Repository/index/cache/security/transaction
and runtime/temporary/NTFS allocation overhead, timing and final cold size remain
unmeasured. Guest-file apparent-size/extent census is NOT an opaque-byte custody
prerequisite; it remains required for the separate filesystem profile's budgets.

[Microsoft](https://learn.microsoft.com/en-us/windows/wsl/basic-commands) documents
VHD export/import and import-in-place; [disk-space guidance](https://learn.microsoft.com/en-us/windows/wsl/disk-space)
identifies registered VHD storage. Generic '-' wording is not evidence that VHD
export supports stdout. This design does NOT invoke wsl --export --vhd -.
[Borg stdin documentation](https://borgbackup.readthedocs.io/en/1.4.5/usage/create.html#reading-backup-data-from-stdin)
warns a producer can fail/truncate while piped archive creation succeeds: independent
exact count/digest and producer exit checks are mandatory. [Extract --stdout](https://borgbackup.readthedocs.io/en/1.4.5/usage/extract.html)
provides binary data; no PowerShell object/text pipeline may carry it.

### Maintained mechanics and actual bounded evidence

WslBackupTransport.cs, loaded by Initialize-WslBackupBinaryTransport, provides
bounded asynchronous binary transfer around an ALREADY STARTED shell-free child.
It launches no backend and opens no path. The future trusted caller must construct
an exact ArgumentList and own source/target/lease for the ENTIRE transaction.
Three streams drain concurrently with fixed buffers, incremental SHA256/counts,
exact length/digest checks, finite timeout/cancellation, nonzero-exit/any-diagnostic
rejection and64KiB stderr limit. Errors expose no backend bytes/text/secret values.
Failure requests child-tree termination and uses an independent5-second shutdown
budget to confirm the owned process exits and pipe tasks settle before returning.
The cancelled transaction exit task cannot establish this. Unconfirmed teardown
is a distinct refusal that requires retaining caller custody. Caller-owned partial
output is never removed or overwritten. Descendant termination is requested;
this parent-exit check does not independently prove every descendant has exited.
[Microsoft documents asynchronous Kill and descendant-status limits](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.kill?view=net-9.0);
[WaitForExitAsync cancellation](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.waitforexitasync?view=net-9.0)
is distinct from confirmed process exit. First source-read digest may be computed under the live
lease, then must match archive read-back before admission. A process exit0 alone
never admits bytes. The helper supplies mechanics, not source identity or cold proof.

The Linux-only binary helper in the existing wsl-borg-fixture.py uses bounded
binary pipes/selectors and an owned process group. This intentional platform
separation permits inherited passphrase FD delivery to Borg; neither layer is an
additional backup backend. Only fixed synthetic CLI --run-container is exposed;
no real source/repository/command passthrough exists. Shared pinned provenance,
private workspace, secret descriptor and fresh key-recovery observers are reused.
Secret values never enter environment values, argv, logs or committed artifacts.

An actual new private8,388,621-byte mixed/random/zero fixture passed encrypted Borg
stdin create, exported-key recovery with fresh client state/original paths absent,
exact negative controls44/52, check --verify-data, binary stdout extraction and
independent restored-file count/SHA256. Create uses three4MiB data references in
the no-reuse model. Source/restore bytes/hash match; private secret custody and all
attempts remain outside Git. This is same-filesystem synthetic key custody and
path renaming, not OS-enforced source unavailability, off-laptop custody, actual
Windows/WSL transport, VHD validity or boot. Older proofs are unchanged.

Native tests cover byte corruption/truncation with exit0, excess data, diagnostic
flood/nonzero exit, output-before-input deadlock pressure, timeout/cancellation,
request identity/path/capacity/profile refusals and legacy behavior. Windows-only
tests additionally require actual sharing error32 for existing-writer/read-lease,
write/delete exclusion while a handle stays live through binary transfer, exact
restored bytes and non-sparse new file. Native .NET execution is NOT Windows
acceptance. No maintained Windows-to-selected-worker integration receipt exists yet;
the controller diagnostic is independent historical evidence, never an operational
dependency or admission substitute.

### Staged Windows tests and selected-worker plan

After signed-source review, build a NEW artifact package with the existing
build-windows-artifacts.py and verify artifact-source-manifest.json/source commit
and every file hash. WslBackupTransport.cs is now required by the closure. This
package is NOT deployed/activated by source work. Controller stages it into a NEW
private test source tree, plus the exact signed tests/powershell/WslBackup.Tests.ps1,
WslHostScripts.Tests.ps1 and WslColdContainer.Tests.ps1 at their relative paths.
Verify supplemental test hashes from the checkpoint. Both synthetic child-launch
sites explicitly set CreateNoWindow=true with shell execution disabled and
noninteractive arguments. Native tests do not establish Windows window behavior.
Failure tests await the transport, then assert actual child exit BEFORE defensive
cleanup; no post-return grace wait/poll or cleanup kill can make those assertions
pass. A signalled source-read fault occurs only after a4096-byte prefix is flushed,
then verifies source/target handles, seek/read/write usability and exact partial
file bytes/existence before cleanup. The simulated fault affects only NEW synthetic
files, never a VHD/device. First strengthened native run exposed four child-lifetime
failures in d052; the owning C# shutdown path was repaired. Preserve both receipts.
Use fresh ordinary pwsh7
with no profile so no earlier same-named loaded assembly can substitute for code:

```powershell
pwsh -NoProfile -NonInteractive -Command 'Invoke-Pester -Path ./tests/powershell/WslBackup.Tests.ps1,./tests/powershell/WslHostScripts.Tests.ps1,./tests/powershell/WslColdContainer.Tests.ps1 -Output Detailed -CI'
```

Run only from that reviewed staging tree, retain XML/output/hash/source receipts,
and treat any sharing case skip/failure as Windows coverage still missing. Pester
uses disposable synthetic TestDrive data only; it has no real-device/VHD arguments.
Operator backup attempts require separately retained private pending/partial/failure
custody; the low-level transport never deletes caller streams/files.

No worker distro is selected here. Main Ubuntu and the spare are E-backed; spare
is stopped and must not be started until controller approval. First identify its
registration/VHD/hardware independently of source/recovery, budget its cache on E,
and stage exact reviewed runtime/source in immutable non-user-writable custody
where privileged consumers require it. Test the maintained transport through that
explicit worker using a NEW synthetic source BEFORE any real VHD. Existing native
--run-container can prove that worker's Borg/crypto path after approved isolated
staging, but does not test wsl.exe pipe/sharing behavior. The fixed worker engine
and binary protocol are implemented below; immutable production admission and
actual selected-worker Windows integration are still missing;
there is intentionally no production --create/--restore arbitrary-path CLI.

### Ordered real-operation gates and reviewable transaction design

1. Finish current controller paired archive verification; any retirement requires
   independent acceptance, then remeasure physical free space. Preserve protected
   recovery image/proofs and every failed attempt. Obtain explicit cold-container
   profile, destination, worker and restore-target approval; vault/provider choice
   is independent and pending, never ask for secret values in chat.
2. Implement/review the fixed operational wrapper around existing owner: resolve
   EXACT source distro registration UUID/canonical VHD (including reparse/final
   handle path/file identity checks), save work/quiesce and observe stopped state.
   Acquire an OS read handle with FileShare.Read that rejects any existing writer
   and excludes new write/delete access. Recheck bindings/state after acquisition.
   Do not start source as worker. Hold that SAME handle continuously through read,
   full archive check, archive byte read-back verification and receipt commit.
   No sampled boolean, reopen-by-path or journal lock substitutes for this lease.
3. Actual Windows tests must prove maintained child cancellation/binary pipes and
   source exclusion through the selected WSL worker, including baseline/held/released
   access controls and read errors. The supplied one-off diagnostic cannot close
   this maintained integration gate. Source size comes from the held handle, stream
   count/hash covers EVERY byte, and archive evidence binds repository/archive/member
   IDs, source handle/registration, exact tool/worker/profile and lease lifetime.
4. Approve independent repository hardware/identity/private access, per-filesystem
   complete overhead/reserve budgets, root-safe pinned runtime and independently
   recoverable encrypted key/passphrase custody. Initialize real repository/key
   only in a separately approved phase. Hold Borg repository transaction locks;
   immutable pending/failure receipts retain partials on ANY source/child/count/hash/
   diagnostic/timeout error. No prune/repair/overwrite/automatic retention.
5. Recover independently with source unavailable: select exact bound archive/member,
   recover key in fresh approved client state, create NEW private dense NTFS target
   with CreateNew, continuously hash/count binary output and flush, independently
   rehash its ENTIRE file before ANY import. Exact length/hash and non-sparse/reparse
   attributes are required, plus actual filesystem/capacity/ACL checks. No partial
   output may register even if child exits0. E target can be an isolated restore
   test sharing source/protected hardware; never claim third-hardware redundancy.
6. Only after separate approval, use supported import/import-in-place on that NEW
   verified image with preserved source/original/repository, isolated boot/identity/
   user/service checks and actual cold-image consistency acceptance. Random bytes,
   equal digest or a renamed synthetic source cannot grant full restore/boot proof.

This source turn does not read a live VHD, stop/start a distro, choose/activate the
worker, attach a disk, create real keys/repositories or change runtime/security/
services. Production execution stays unavailable until a reviewed operational
implementation and actual named gates exist. No extra guest census is imposed
on opaque byte custody, and no filesystem-profile gate is removed.

### Worker protocol increment: implemented engine, admission still closed

The next maintained increment extends WslBackup, not a second backup framework.
WslColdProtocol.cs owns the .NET framed binary exchange; wsl_cold_container.py
owns fixed Borg commands, process lifetime and durable journals. WslColdSourceLease.cs
owns Windows final-handle/file-ID/read-share mechanics. Existing BinaryTransport
remains unchanged for existing callers. Get-WslColdWorkerLaunchPlan returns a fixed
ArgumentList, never launches wsl.exe. Resolve-WslColdRegistrationBinding resolves
one exact name/UUID in the owner's registry, honoring registered VhdFileName (only
absent property defaults to ext4.vhdx). A resolved path is NOT stopped/cold proof.

This is a finite source increment, **not a completed production controller**.
weekly-wsl-backup -RecoveryBackend borg-container-readiness -Execute still refuses
before touching a source, worker or repository. wsl-cold-worker.py --serve also
refuses before reading stdin/secrets or touching a backend. --readiness is the
only supported worker command and exits3 with named missing gates. No wire field,
fixture flag, observation boolean or imported test harness grants admission.
Engine Session is deployment-internal, not an arbitrary-path operational CLI.
Test helpers under tests/helpers are supplemental tests and MUST NOT be deployed
as runtime dependencies. The existing fixture observer remains synthetic-only.

#### Versioned binary transaction

revkit-cold-worker-v1 binds cold-vhd-container-v1, a controller-reviewed binding
SHA256, unique operation UUID, explicit archive UUID, phase, full byte count and
lowercase SHA256. Backup requires archive UUID == operation UUID; restore uses a
new operation UUID and an explicitly identified existing archive UUID. The binding
must eventually cover authoritative source/worker/protected registrations, source
canonical handle/file identity, repository identity/native archive identity,
immutable runtime/source hashes, capacity/custody/outage receipts and the profile.
No name such as latest, arbitrary backend command or shell string is accepted.
The current engine binds the supplied digest; it does NOT certify those missing
external facts. Receipts explicitly say productionAccepted=false.

Each frame has one ASCII kind byte and uint32 little-endian payload length, then
exactly that many bytes. R/E/K/A/Z/F JSON is <=16KiB, D binary <=64KiB, S private
secure input <=1024 bytes, H heartbeat and C cancel have zero payload. Strict JSON
rejects duplicate/unknown fields and substituted versions/profiles/identities;
Python rejects nonfinite numbers, booleans as byte counts and malformed UTF8.
A two-item input queue bounds buffering. Finite whole-transaction and inter-frame
idle deadlines are separate. Heartbeats are serialized with data/control writes.
EOF, excess/truncation, diagnostic overflow, nonzero exit or wrong hashes refuse.
No PowerShell text pipeline carries container or secret bytes.

Backup order: R,S,D*,E; worker performs create, check --verify-data and extract
--stdout; worker emits D* then A. Controller independently checks all readback
bytes/hash and awaits producer completion. It sends K bound to the exact A bytes;
only then does worker fsync a committed journal record and emit identical Z,
then EOF/exit0. A alone is NOT final acceptance. Secret input goes to an anonymous
private memfd inherited only by Borg; argv/environment contain FD NUMBER only.
No passphrase environment-value fallback or child diagnostics are emitted.
Secret input must omit newline/NUL; the worker supplies Borg's terminating newline.
Neither implementation claims to scrub every managed-language memory copy.

Restore order uses R,S,E(empty input), check and D*/A/K/Z for the explicit archive.
The .NET restore exchange refuses without a caller verification callback before K.
That future caller must CreateNew a private dense NTFS file, Flush(true), verify
attributes/final path/file identity and independently rehash its entire contents
under retained handles before returning from the callback. Generic FlushAsync
alone is not durable restore acceptance. Independent key import/recovery is a
SEPARATE prepare/recover phase; the engine never initializes a real repo, exports
real keys, guesses missing keys or selects an archive. The current CLI cannot
execute any of these phases. Native tests create only new synthetic repo/keys.

Borg arguments are fixed: create --chunker-params=fixed,4194304
--files-cache=disabled --compression=none --stdin-name=ext4.vhdx REPO::cold-UUID -;
check --verify-data REPO; extract --stdout REPO::cold-UUID ext4.vhdx. Native Borg
repository locks are respected at EACH command, --lock-wait=1, no bypass/break/repair.
A private nonblocking worker lock and create-new UUID journal serialize this worker;
events are create-new0600, file+directory fsynced, never rewritten/deleted. Existing
attempts, failed partial archives, cache and last-good archives remain. This worker
lock is **not** a continuous native Borg lock against other clients. Production
needs reviewed exclusive repository access across phases and immutable deployment;
wrapping nested Borg with with-lock can contend with Borg's own locks. Do not add
a bypass to resolve that. [Borg's supported lock semantics](https://borgbackup.readthedocs.io/en/1.4.5/usage/lock.html)
are a separate resource/ownership requirement, not synthetic acceptance.

Each Borg starts in its own Linux process group. The worker establishes the
process-local Linux child-subreaper attribute and reaps ONLY its adopted group
children. This is needed for the pinned standalone bootloader's fork. On cancel,
EOF, timeout or failure it kills ONLY its owned group, waits/reaps and verifies
that group absent before F may assert linuxChildrenExited=true. No kill-all,
service/account/security-policy change or stale-lock removal occurs.
[Linux subreaper semantics](https://man7.org/linux/man-pages/man2/PR_SET_CHILD_SUBREAPER.2const.html)
explain why a launcher-only wait was insufficient. The first real native attempt
correctly refused with group exit unconfirmed; it is retained. If F/Z is missing,
false or unbound, Windows MUST retain the source lease/custody and reconcile the
journal; killing/stopping wsl.exe or observing its exit proves no Linux lifetime.
The .NET failure path settles stream tasks, sends C under an independent bounded
teardown budget and requires the bound Linux acknowledgment and child exit. An
unsettled stream or absent acknowledgment remains an explicit refusal.

#### Windows lease and unfinished production admission

ColdSourceLease requires Windows/NTFS, a reviewed canonical local drive path and
reviewed volume+file index, one hardlink, no reparse components, exact final handle
path and positive length. FileShare.Read rejects existing writers and excludes
new writes/deletes. ValidateUnchanged rechecks held-handle identity, length,
write-time/attributes, final path and reparse components. Caller owns this SAME
handle through readback, archive verification and final receipt; the protocol
never disposes it. Review-only identity inspection is not the transaction lease.
The class does not resolve registry, save work, stop a distro, establish quiescence,
verify ACL/capacity or prove a race-free registration/power-state admission by itself.
No code here silently performs those actions. Actual new Windows sharing tests
must run on reviewed synthetic files; native compilation is not Windows evidence.

Concrete remaining CODE gate: an immutable deployment/admission owner must bind
fresh authoritative registration/power state before AND after lease acquisition,
source/protected/worker identities (including actual final handles), repository
hardware/exclusive custody/native archive IDs, source-outage plan and capacity/key
receipts, then keep that binding live through commit. It must stage a pinned worker
interpreter/source/tool in non-user-writable custody, validate worker-side mounted
repository identity and independent key FD recovery, and supply the durable dense
restore verifier. Neither Get-WslColdWorkerLaunchPlan nor --readiness implements
that authority. Source/worker selection, immutable deployment and actual selected
Windows-to-WSL acceptance remain controller operations, not test flag capabilities.
A production --serve invocation is therefore NOT ready to run. The exact fixed
future argv is documented by Get-WslColdWorkerLaunchPlan; it presently refuses.

#### Bounded validation and capacity limits

Run the maintained tests with retained SIGNED PUBLIC release inputs and a private
ext4 parent outside Git; all cases create NEW custody and preserve earlier attempts:

```sh
python3 -B tests/test_wsl_cold_worker.py --retained-release-inputs /approved/public-borg-inputs --private-fixture-parent /approved/private-ext4-parent -v
```

No production data/repository/key arguments exist on that test runner. It verifies
all three release hashes/signature/version through the existing synthetic observer,
then exercises actual encrypted stdin/check/stdout, .NET-to-native Python framing,
Linux cancellation/EOF/idle/nonzero/producer refusal, retained journals, independent
synthetic key export, missing-key44/wrong-passphrase52 and fresh-client restore.
The native .NET child is fixed /usr/bin/python3 -I -B plus a TEST-ONLY helper;
no distro is launched. Only a small ~1MiB mixed binary fixture is streamed per
successful roundtrip. Native receipts do not prove Windows-to-WSL, source outage,
off-laptop recovery, full image or VHD validity/boot. Runtime/key descriptors and
all secrets remain private and outside Git; only nonsecret receipt paths/counts
are reported. All attempts remain in their new private UUID custody.

Windows staging: build a fresh committed-source package, verify EVERY manifest
file hash and source commit, stage all FOUR tests/powershell/Wsl{Backup,HostScripts,
ColdContainer,ColdWorker}.Tests.ps1 plus the signed static compact-task fixture at
its normal relative path. Run fresh ordinary pwsh with no profile:

```powershell
pwsh -NoProfile -NonInteractive -Command 'Invoke-Pester -Path ./tests/powershell/WslBackup.Tests.ps1,./tests/powershell/WslHostScripts.Tests.ps1,./tests/powershell/WslColdContainer.Tests.ps1,./tests/powershell/WslColdWorker.Tests.ps1 -Output Detailed -CI'
```

These are disposable synthetic files/processes only. Retain XML, exact staged
source/test hashes and runtime versions. Package PowerShell bytes intentionally
follow committed CRLF archive attributes; raw blob and artifact hashes are separate
identities. Actual selected-worker integration needs the missing reviewed immutable
admission/test staging first; neither this command nor old60/60 Windows tests close
that NEW gate. Do not start the spare distro or substitute tests/helpers as a
production worker. Controller review/staging is the next action, not activation.

Capacity stays full container bytes for repository AND dense restore plus separately
measured repository/index/cache/security/journal/temp/runtime overhead and >=64GiB
reserve per filesystem, aggregating shared domains. No sparse, dedup or compression
credit. Existing bounded readiness calculations remain owning. Check --verify-data
can read the ENTIRE repository, not just the new member; its I/O/time/cache cost
needs measurement/planning. The current controller requires a known full input
hash; a real first archive would need a full prehash under the SAME lease, then a
second read to stream plus archive verification/readback. Budget that I/O explicitly.
Queue/frame limits are not a bound on Borg's memory, caches or repository indexes.
No guest census is needed for opaque custody; cold size, filesystem free space,
repository history/index cardinality, all overhead and durations remain unmeasured
for production. Narrow provisional restore margin is not capacity acceptance.

Ordered remaining production gates: finish controller retirement and remeasure;
review/complete the immutable admission and dense-restore/key boundaries above;
actual Windows synthetic tests and selected-worker duplex/lifetime/lease acceptance;
independent repository/key custody and per-filesystem capacity approval; saved work,
source-outage/cold confirmation and continuous lease; separately admitted full
backup/readback; independently recovered key and source-unavailable dense restore;
all-byte file acceptance, then separately approved isolated import/boot and services.
E restore is an isolated test sharing source/protected hardware, not a third-hardware
copy. Filesystem candidate remains REJECTED. Google Password Manager and Apple
Passwords remain owner-selected; no paid vault or production secret was created.

### Operational admission and custody policy (supersedes disabled worker draft)

Invoke-WslColdContainer.ps1 now calls the existing WslBackup owner for prepare,
backup, restore and reconciliation. The former unconditional worker --serve stub
is replaced by real signed-policy admission. There is no test-mode activation,
policy-selected command string, scheduled credential provider or implicit disk/
source lifecycle action. Existing borg-container-readiness remains READ-ONLY by
name; its -Execute refusal is intentional. Use the operational entry below.
Neither this source increment nor the current f47 Windows test run activates it.

Two owner audit defects are fixed first: WslDiskIdentity accepts null, empty string
or actual System.Char NUL as an absent Windows letter, rejects whitespace/numeric/
array/assigned/malformed values without coercion; Session marks lifetime unknown
BEFORE Popen and includes selector/pipe setup inside cleanup ownership. Only actual
parent reaping AND process-group absence set group_gone=true. Fault-injected kill,
wait or reap failure cannot produce a true Linux-exit acknowledgment. Assertions
run before defensive cleanup; failed and last-good artifacts remain preserved.

#### Signed deployment, trust and repository custody

Deployment uses a NEW source-addressed root-owned directory:
/opt/revkit-wsl-backup/SOURCE_COMMIT/scripts/{wsl-cold-worker.py,lib/...}.
No symlink/current-path or in-place immutable artifact edits. A single root-owned
/etc/revkit/cold-container-v1.json has a detached SSH signature at .json.sig and
fixed /etc/revkit/cold-container-allowed-signers. The allowed identity is
revkit-owner, namespace revkit-cold-deployment-v1. Root installs only the already
reviewed owner public signing key; no token/auth/agent/trust override is performed
by this implementation. Sign the actual reviewed document using the owner's
normal supported SSH signing workflow, then stage it unchanged on BOTH sides.
Do not sign a template, synthetic receipt or acceptance boolean.

The signed document binds schemaVersion1, opaque profile, exact signed source
commit, one operation/transaction/archive UUID, expiry <=24h, exact Windows
controller runtime hashes, source/worker/protected registrations and canonical
paths, source file identity/cold size, physical hardware/partition IDs, repository
native ID/ext4 UUID/PARTUUID/USB serial+geometry, selected worker machine ID+kernel session ID (not distro restart identity),
root-owned interpreter real path+SHA256, exact four Python source hashes, pinned
Borg release hash, root-private state, per-filesystem budgets and four reviewed
acceptance/custody/capacity receipt hashes. Those hashes must refer to actual
reviewed evidence for THIS implementation; a supplied bool cannot replace them.
Missing or mismatched external facts refuse. Source hashes/interpreter/Borg hash
are cryptographically bound by the owner's deployment signature, independently
of JSON's self-described source commit. Root reviews the normal Git signature and
package manifest before signing deployment; no unsigned document can bootstrap
its own signer or choose another trust anchor from argv/wire.

Windows requires protected ownership/write ACLs (SYSTEM, Administrators or Windows
TrustedInstaller), no reparse path, exact signed policy and signer-file hashes,
SSH verification, exact controller source closure, expiry and fresh hardware/
registration/capacity observations. Ordinary users may create siblings in a volume
root but cannot replace protected existing deployment ancestors. Linux requires
root, isolated -I/-B system Python, immutable root-owned canonical runtime paths,
exact hash pins and signature, no loader/secret env fallback. It validates the
actual selected machine/boot, mounted ext4 filesystem and correlated Windows identity/parent geometry
with bounded maintained disk-probe queries, native repository ID and root-
only0700 repository/state without named/default ACL grants. There is no nvm root
execution, install, mount, attachment or permission modification in these tools.

A root-only filesystem-resident .revkit-cold-REPOSITORY_ID.lock at the independent
repository mount root is flocked nonblocking across key import, create, native
Borg locks, check, native archive-ID lookup, readback and receipt. It is inherited
by child processes; unconfirmed teardown retains custody. Root-only ownership
excludes ordinary direct Borg clients; ALL managed workers share this inode even
with different state directories. As with root-owned code/policy, a malicious or
out-of-band root administrator can override ownership/locks; root maintenance
must not run another direct Borg client while this broker owns custody. This is
an explicit administrative trust boundary, not a claim flock stops arbitrary
root. Borg's own native locks are still acquired at every command. There is no
with-lock nesting/bypass, break-lock, repair, prune or failed-evidence deletion.

#### OS lifetime and continuous source exclusion

The selected, separately accepted worker executes in one exact transient systemd
service revkit-cold-TRANSACTION_UUID.service, Type=exec, Slice=system.slice,
KillMode=control-group, TimeoutStopSec=10s, RuntimeMaxSec=policy timeout+30s,
--pipe/--wait/--collect/--quiet (NO PTY). These are properties of this bounded job,
not changes to existing services, owner memory/network settings or schedules.
The worker verifies MainPID, its actual unified cgroup, KillMode and runtime bound
before any Borg child. This uses the existing worker's supported system manager;
if unavailable, it refuses without a fallback to unsupervised execution.
[systemd-run](https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html)
documents inherited binary pipes and synchronous job waiting. Actual selected-WSL
systemd/pipe behavior remains a root-run acceptance gate, not native test proof.

Native Linux exit F/Z still requires actual owned parent/group absence. On loss
of acknowledgment, the controller RETAINS its source handle, partial destination,
private caller stream and process capability. Reconciliation invokes only the
exact selected signed worker, writes/fsyncs a durable cancel-UUID tombstone BEFORE
stopping that exact transient unit, then checks its fixed kernel cgroup is absent
or unpopulated. Every future begin/phase checks that tombstone: a delayed wsl.exe
launch cannot create a backend after reconciliation. Windows also confirms its
caller I/O tasks settled and frontend exit. A status/permission/kernel/transport
failure retains custody, not success. The driver stays alive retrying retained
custody; it does not silently exit and release the source. Do not forcibly close
that controller process on an unconfirmed result. No kill-all is used.

Windows resolves exact UUID/name/registered VhdFileName, verifies source and
protected recovery stopped before AND after acquiring the same source handle,
installs Registry change notifications on all three registrations, and refuses
any watched change through commit. Backup retains FileShare.Read exclusion through
prehash, streaming, archive check/readback, K/Z and controller receipt. Restore
uses FileShare.None, excluding OTHER READERS as well as writers/deletes, without
reading source content. The worker restores only the explicitly bound repository
archive; the retained source VHD cannot be opened by its separate process. Actual
Windows-to-WSL read-denial under this exclusive handle requires new host evidence.
No distro is stopped, started as source, imported or booted automatically.

#### Explicit independent keyfile custody decision

Production deployment selects keyCustody=keyfile-blake2-independent-v1. The byte
profile remains cold-vhd-container-v1 with fixed4MiB/files-cache-disabled/
compression-none; key custody is separately signature/version bound. This is the
SAME Borg backend, not another production backend. Existing repokey synthetic
receipts remain valid historical encryption observations, not keyfile acceptance.
No real repository exists or is converted by this change.

The reason is upstream semantics: Borg1.4.5 repokey import writes the embedded
repository key, whereas keyfile import can target a new local BORG_KEY_FILE.
[Borg key management](https://borgbackup.readthedocs.io/en/1.4.5/usage/key.html) and
[pinned key-manager implementation](https://github.com/borgbackup/borg/blob/1.4.5/src/borg/crypto/keymanager.py)
make that distinction explicit. Fresh-client recovery must not rewrite the only
good repository key just to prove it has independent custody. Root must initialize
a NEW keyfile-blake2 repository only in its separately admitted preparation phase,
using the pinned supported Borg CLI/private owner input. Initialization and key
export are explicit operator operations, never automatic fallback in backup.

The operational API accepts a SecureString from a private caller and a caller-
owned readable encrypted key-artifact Stream. Neither is a command argument,
environment secret value, receipt field or log. The wire adds a bounded private
Y frame for the encrypted export (<=64KiB); worker validates its BORG_KEY/native-
repository-ID header, stores it0600 in NEW transaction custody and imports into a
NEW BORG_KEY_FILE under a fresh client environment. It verifies actual Borg JSON
key mode and native repository ID before B (prepared acknowledgment); only then
may data/E frames proceed. Missing/wrong key/phrase refuses; artifacts remain.
No Google/Apple browser database is read. Those retained password managers and
an offline recovery record are NOT an unattended credential broker. Schedules
remain unchanged and cannot acquire credentials from this API by magic.

Every actual archive is bound to its Borg native archive ID as well as explicit
UUID/name and full image digest/length. Backup signs no output automatically: it
writes a private, flushed controller archive receipt after matching Z and fresh
source/registration/capacity checks. Root reviews/signs that receipt in namespace
revkit-cold-archive-v1 before a separately signed restore policy may reference its
exact SHA256, native archive ID, image bytes/hash and repository. Fresh restore
imports the independently supplied key into NEW client state, verifies that exact
archive and restores binary stdout into a CreateNew private DENSE NTFS file.
Before K, the C# callback Flush(true)s, verifies held final handle/one link/non-
sparse/non-reparse identity+length, independently rehashes EVERY target byte,
checks live registry/cold state/reserve and only then admits commit. Neither K/Z
nor an equal random-file hash proves VHD/ext4 validity or boot. Import remains a
separate root-approved supported WSL import/import-in-place operation after this
verified dense-file receipt; the source tool does not register anything itself.

#### Actual inputs, capacity and reviewable invocation phases

The signed policy is a deployment document, not a machine-specific source config.
Its exact field contract is enforced in wsl_cold_admission.validate and
Read-WslColdAdmission; root fills ONLY measured identities, hash pins, existing
protected private paths, actual acceptance references and reviewed costs. No
example here supplies synthetic capacities as actual measurements. Explicit
repositoryAdditionalBytes must cover at least the entire cold container for a
backup plus reviewed repository/index/segment overhead. Workspace, runtime,
cache, security, key/client state, journals and partial growth need their own
positive bound. Windows aggregates shared E restore+worker growth and reserve;
Linux aggregates per st_dev. Live monitors cancel/refuse expiry, unexpected
registration/source change, reserve/growth violations. These monitors are NOT
filesystem quotas or a measured worst-case Borg resource bound. Full image bytes
for repository AND dense target, all overhead and >=64GiB reserve remain mandatory;
no sparse/compression/dedup savings. Prehash requires a full additional source read
under the SAME lease; check --verify-data may read the entire repository/history.

Site retirement/live-size observations are recorded in the private migration
checkpoint, not immutable generic source configuration. They establish no cold
bound or complete overhead allowance. Independent device attachment/UUID and
physical capacity revalidation belong to the controller. Fresh observations must
include new fixture/runtime/worker growth; a narrow provisional target margin
closes no resource gate.

Root-controlled phases after reviewing the NEW signed source/package (not f47
acceptance carried forward):

1. Read actual new Windows tests and selected-worker synthetic lifetime/pipe/
   immutable-admission/exclusive-read proofs. Stage the source-addressed worker
   and pinned system interpreter/Borg only through normal root review. No source
   action starts the spare or touches the independent disk.
2. Root identifies/attaches/mounts only the approved independent partition using
   existing owners, verifies ext4 UUID/hardware, approves measured costs, and
   separately initializes/exports a new encrypted keyfile repository via supported
   Borg/private owner input. Preserve original/key custody and all last-good data.
3. Root prepares/reviews/signs fresh deployment JSON + detached signature and its
   existing public signer anchor, then stages identical bytes in protected Windows
   and fixed Linux locations. Do not populate receipt fields with fake booleans.
4. From a fresh normal Windows PowerShell host load the reviewed script. Its
   parameters are -Phase prepare|backup|restore|reconcile, -PolicyPath,
   -ReviewedPolicySha256, -AllowedSignersPath, -ReviewedSignersSha256 and explicit
   -Execute. Without -Execute it verifies signed syntax but executes no worker.
   prepare -Execute performs actual identity/capacity/immutable worker readiness;
   it creates no repository/key and reads no source bytes.
5. backup -Execute additionally requires private -Passphrase SecureString and
   -IndependentKey Stream. Root first saves work/quiesces/stops the selected source
   outside this tool. The signed policy binds operation/transaction/archive IDs;
   no fallback export or implicit schedule is possible.
6. Review/sign the resulting archive-receipt.json separately. A new restore policy
   binds its hash/native archive ID. restore -Execute requires that private key/
   phrase plus -BackupReceiptPath/-ReviewedBackupReceiptSha256. Source exclusive
   read denial and exact dense-file durability/hash must succeed before commit.
7. Root separately approves supported isolated import/boot/user/service acceptance.
   E target shares source/protected hardware: isolated restore test, not third-
   hardware redundancy. Full backup/restore/boot/GAP-301 remain unproved until real
   receipts exist. Fixed64KiB filesystem candidate stays REJECTED.

No source turn invokes any of these production commands or creates production
keys/policies/repos, changes permissions/auth/security, mounts/attaches disks,
stops/starts distros/services/apps or writes E/D records. Root's current f47 frozen
package is untouched; new runtime changes require their own exact package/test
review. CI/bundler/IDE work stays deferred, including required standard agent
entries AND custom RevealUI Zed agent repair. Google Password Manager AND Apple
Passwords remain owner-selected; no paid vault or credential scraping is added.

Prepare-only bootstrap is signed operation=prepare. It may omit future acceptance
hash values and native repository ID while the repository is absent; it still
checks immutable runtime, actual mounted device identity and conservative capacity,
creates nothing and cannot enter --serve. Windows permits the source to remain
running for this read-only phase and reports ColdSourceProved=false. Backup/restore
policies require all real acceptance hashes and native repository identity; a
wire flag cannot promote a prepare manifest. This avoids inventing receipts just
to perform actual read-only worker admission before provisioning/testing.

After an unconfirmed operation, the driver reports its nonsecret retained-custody
gate. Automatic retries are READ-ONLY --status, not repeated privileged stop or
authentication attempts. Root resolves any reported permission/policy/transport
gate through its normal workflow and can explicitly reconcile that SAME admitted
transaction. Missing/denied cgroup or marker reads are never absence proof.

Windows immutable code/policy and private DATA use separate ACL admission. Code
remains SYSTEM/Admin/TrustedInstaller protected. New journal/restore custody also
admits the explicit current owner but rejects other-user ReadData as well as
mutation rights at the private leaf, including inherited child grants. The tool
checks ACLs; it never changes them. Parent traversal/public code read is not
misclassified as access to private image contents.


The hardware/authority follow-up in `windows-recovery-maintenance.md` owns the
expanded MBR/GPT volume schema, missing-guest-serial correlation, DISKSEQ/mount
continuity, fixed Windows observer and protected C authority provisioning plan.
`linux-boot-provisioning.md` owns selected-worker-only timeout/readiness planning.
Earlier three-file worker closures and serial-equality policies do not admit the
new four-file runtime. E private-data ancestor custody remains an explicit code/
acceptance blocker; no authority provisioner changes that data trust contract.

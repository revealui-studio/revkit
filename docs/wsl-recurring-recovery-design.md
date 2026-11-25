# Recurring WSL recovery under bounded storage

Status: review proposal under GAP-301, 2026-11-25. No repository, encryption key,
mount, timer, retention operation or backup implementation is activated by this
proposal. Existing full-image recovery remains protected. The current maintained
full-export capacity refusal is correct and must remain enforced.

## Capacity and selected proposal

Observed E: available space is 277,879,668,736 bytes; the live Linux filesystem
uses 603,945,496,576 bytes. The retained verified VHDX is 633,995,264,000 bytes.
The independently identified secondary ext4 volume previously reported
943,636,373,504 free bytes. Those are measurements, not compression guarantees;
revalidate identity, mount state, filesystem capacity and source size at each run.

Propose an encrypted local Borg 1.x repository on the approved secondary volume,
with content-deduplicated archives of an offline filesystem view. The first full
archive has a conservative source-size budget; later archives add unique chunks
and metadata instead of staging a second full VHDX. This is a candidate design,
not a claim that Borg is installed, approved or measured against this dataset.
Pin and verify a stable supported package before implementation. Keep numeric
ownership, modes, ACLs, xattrs, hardlinks, symlinks and sparse restore semantics.
Do not silently exclude models, caches or owner state to make the budget fit.

At the quoted measurements, one source-sized archive leaves 339,690,876,928
bytes before repository metadata and reserve. Reserving at least 64 GiB leaves
270,971,400,192 bytes for unique changes and further metadata. Actual encrypted
repository size, compression, memory/cache needs and change rate need a measured
pilot. An archive dry run cannot prove its eventual unique-chunk space budget.
A maintained preflight must use a conservative upper bound and refuse uncertain
capacity. Never prune the last verified archive or old recovery image to make a
new transaction fit. Do not auto-prune or compact in the creation transaction.

## Owning implementation contract

Extend the existing WSL backup planner/wrapper rather than introducing an
unregistered scheduled script. Require the reviewed disk identity and explicit
repository path, package identity, encryption/key-recovery plan and maintenance
window. Secret key material stays outside receipts and source. Key escrow and
recovery must be tested independently of the source home being backed up.

The Windows wrapper first reports readiness. It must defer with a visible stale
backup alert while user sessions or source writers remain active. It cannot
terminate applications or a distro to satisfy a schedule. After a supported
saved-work boundary, obtain an offline, read-only view of the stopped source.
Do not treat a walk of the changing live root as a consistent WSL recovery point.
Exclude only pseudo/mount boundaries explicitly derived from the filesystem
manifest; unrelated Windows volumes and the backup repository are never recursed.

The Linux archive owner takes the repository lock, checks conservative free
space, creates a uniquely named archive and records its final ID and statistics.
Retain partial attempts and failures visibly; never label an interrupted archive
verified. Run repository/archive integrity and cryptographic data verification
before promoting the archive in the maintained recovery inventory. Retention is
a separate reviewed action after replacement verification and restore evidence.
No repair mode, lock breaking, ownership change or capacity override is automatic.

## Restore acceptance and remaining capacity blocker

Cryptographic repository checks and a dry extraction are necessary; they do not
prove that an entire filesystem was written and can boot. Restore numeric IDs,
ACLs/xattrs, links and sparse files into a new independent ext4 target, compare
content/metadata inventories, then perform the reviewed WSL registration and
isolated boot/user-service acceptance. Keep original image and recovery distro.
Restore must work with the source distro unavailable and escrowed keys only.

Current E: space cannot hold another source-sized restore target. The secondary
volume also cannot conservatively hold both a source-sized repository and a
source-sized independent full restore simultaneously. Deduplication solves the
recurring archive-staging problem; it does not remove this restore-target need.
Full acceptance therefore still requires additional independent capacity or a
separately approved recovery drill with an explicitly preserved last-good path.
Do not overwrite the protected recovery image/distro as a test shortcut.

A first pilot can verify synthetic metadata/link/ACL cases, cryptographic checks,
and a bounded real-file restore. The November 25 seven-file read-only VHDX
extraction demonstrates recovery of those exact files only. Neither pilot nor
that extraction closes full-size restoration or GAP-301.

## Existing exception removal targets

The historical full-export wrapper assumes two complete exports fit; retain the
capacity gate and replace that strategy only after the new maintained archive
and restore contract passes. Temporary recovery-reader scripts are evidence
collection only and must not become backup runtime dependencies. Preserve all
failed staging, current snapshots, original files and existing recovery artifacts
until their reviewed replacement and retention gates are satisfied.

References: [Borg create](https://borgbackup.readthedocs.io/en/stable/usage/create.html),
[Borg check](https://borgbackup.readthedocs.io/en/stable/usage/check.html),
[Borg extract](https://borgbackup.readthedocs.io/en/stable/usage/extract.html).

# Linux boot and shell provisioning

`bash shell/setup-wsl-boot.sh` prints a plan. `--apply` requires root and seeds
only a missing `/etc/wsl.conf`. An explicit `--windows-home /mnt/c/Users/<user>`
adds `.wslconfig` to that plan. Existing files, including files with old managed
markers, are preserved byte-for-byte. Apply never changes services, sockets,
the systemd default target, mounts, or running processes. Normal bootstrap calls
the plan and does not silently select host resources.

The historical boot script masked services, disabled boot consumers, changed the
default target and overwrote configuration without recording their prior state.
Its `--revert` could not restore the owner choices it replaced. The maintained
entry point now refuses that operation rather than guessing those choices.
Existing historical masks or disabled services require an independently reviewed
owner-state reconciliation. No optimization profile is selected implicitly.

`python3 -B scripts/reconcile-linux-shell.py` plans reconciliation of the package
Bash base and the recognized Nix installer blocks in `/etc/bash.bashrc` and
`/etc/profile.d/nix.sh`. It verifies the current Bash package's conffile MD5
against the candidate package base. An old base must equal the stripped
`.backup-before-nix` base; unrelated owner edits or unknown Nix blocks refuse.
The resulting files share one per-process Nix guard and preserve shell settings
from the package base. This does not modify Nix or its installed packages.

`sudo python3 -B scripts/reconcile-linux-shell.py --apply` checks root custody,
serializes the activation, copies the originals and a SHA256 receipt under
`/var/lib/revkit/linux-shell-backups/`, and atomically replaces each changed file
while retaining ownership, mode and extended metadata. A partial publication
failure restores files already replaced. Repeating a completed reconciliation
is read-only. Keep the receipt and original files for recovery.

`python3 -B scripts/provision-wsl-disk-helper.py` prints the maintained disk
identity helper's SHA256. Applying it requires root and that exact reviewed
hash via `--apply --source-sha256 <hash>`. The installer publishes
`/usr/local/lib/revealfleet/wsl-disk-identity.py` as root-owned mode `0644` and
records its deployment digest under `/var/lib/revkit/`. All existing parent
components must be root-owned, nonsymbolic and unwritable by group or others.
An unknown existing helper refuses replacement. This installs no disk identity
configuration and grants no sudo access. Sandbox adoption still requires an
explicit approved identity and the maintained mount acceptance checks.

Validate source with `python3 -B -m unittest discover -s tests -p test_linux_boot.py`
and `bash -n shell/setup-wsl-boot.sh`. A successful source check does not establish
successful cold WSL startup; that requires the controller's actual shutdown and
reconnection evidence.

## Existing exception inventory

| Existing location | Owning removal target and evidence |
|---|---|
| `/etc/bash.bashrc`, `/etc/profile.d/nix.sh` duplicate Nix preambles | Package-checksummed shell reconciler; retained before/after digest receipt and login/nonlogin shell verification |
| Existing masks, disabled units and default target left by historical boot script | Explicit owner-state reconciliation; boot provisioning now preserves choices and never reapplies the old blanket policy |
| Manual disk helper deployment | Explicit SHA256-bound root-custody installer; helper digest and ownership verification before any disk adoption |

## Saved cold-start evidence

`python3 -B scripts/provision-wsl-boot.py --boot-evidence RECEIPT.json`
reports the existing native receipt's `systemd-analyze time` and
`systemd-analyze critical-chain` results. It runs no host commands, hashes the
receipt, rejects missing/failed/ambiguous command results, and cannot be combined
with provisioning. The output deliberately leaves desktop adoption unverified.

The 2026-11-25 baseline recorded 74.639 seconds of userspace startup and
`multi-user.target` at 52.099 seconds. Its chain includes `systemd-machined`
(15.829 seconds), `libvirtd` (8.606 seconds), AppArmor (7.094 seconds), and
`snapd.apparmor` (1.157 seconds). The `/run/user/1000` mount appears at 45.942
seconds. These observations identify units for dependency and boot-journal
review; chain timings alone do not establish why a unit waited. Preserve
virtualization consumers, socket activation, confinement, and owner resource
and network settings while reviewing their readiness contracts.

The controller's separate 85.266-second desktop discovery result exceeded the
30-second app probe. A successful CLI resume and a running native user bus do
not establish desktop reconnection. No service disable, target change, host
resource override, or restart is part of this report. The inference consumer's
readiness fix is proposed separately in RevealUI PR3174; cold acceptance remains
behind the coordinated controller boundary.

## Remaining native configuration dispositions

- Docker's disabled Noble source stays disabled pending an upstream supported
  suite and an explicit consumer decision. Do not retarget the suite by name.
- The disabled Kisak Mesa and Turtle feeds stay disabled; their filenames name
  Jammy while their contents select Noble. Neither filename nor a distribution
  upgrade justifies reactivation.
- GitHub CLI and Microsoft `.list.disabled` files remain ignored by APT.
  Chrome's signed stable source remains active. No signing-key or feed changes
  are required by the evidence collected here.
- The bounded Python consumer scan found no environments in the inspected
  pipx, uv, pyenv, or project roots. It is incomplete evidence, so no venv
  rebuild or Python alias substitution is authorized by that scan.
- Zed's custom RevealUI agent still references its old fnm path. The intended
  project ACP script is absent and provider/model ownership is unresolved.
  Preserve the custom entry until its owning launcher and credential contract
  are established; a generic agent entry is not an equivalent replacement.
- GitHub CLI's configured `github.com` host and SSH alias resolve the same
  repository. Approved native shell and ordinary-child `gh repo view` both
  succeeded. Earlier sandboxed child inference errors do not justify login,
  credential migration, or host/auth configuration edits. Use the maintained
  Git rule's explicit `-R owner/repo` form for deterministic repository scope.

## Explicit selected cold-worker role

`provision-wsl-boot.py --worker-policy POLICY.json` is separate from generic seed
mode. It plans only the named `cold-backup-worker-v1` role, refusing main Ubuntu
and protected recovery names. The exact policy fields are `schemaVersion:1`,
`role`, `registrationId`, `distro`, `rootfsUuid`, `defaultUser`, `defaultUid`,
`initTimeoutMs` (10000..120000), and original `wslConfSha256`. Bind the controller's
selected registration BEFORE invoking this command in that distro. The Linux
owner independently observes root filesystem UUID and the existing passwd UID;
it cannot attest the Windows registration by echoing it. Preserve worker `joshu`
UID1000. No account rename or user-session keeper is used.

The parser requires existing `[boot]systemd=true` and the exact default user. It
preserves every unrelated byte, including owner network/memory choices, and
inserts/replaces only the explicit `initTimeout` key. Plan output includes before/
after hashes and canonical `planSha256`. Root can apply only that exact plan via
`--apply --reviewed-plan-sha256 HASH` from an immutable root-owned provisioner.
Apply rechecks root custody/config bytes, retains/fsyncs the original and plan in
a NEW UUID under `/var/lib/revkit/worker-boot`, and atomically publishes the single
file. Failure retains attempts/temporary publication; no guessed rollback occurs.
Rollback requires root's byte review of the saved original and the unchanged
published hash; never overwrite later owner edits. No running lifecycle changes
are made. Root reviews the mutation before applying and later owns cold restart.

[Microsoft documents initTimeout](https://learn.microsoft.com/en-us/windows/wsl/wsl-config)
as systemd initialization waiting, default10000ms. The selected worker's observed
20.697s userspace time and root session warning make a reviewed60000ms policy
reasonable to test; they do not establish causation. Main's setting is preserved.

After root's separately coordinated cold start, the SAME immutable provisioner
with `--worker-policy POLICY.json --worker-readiness` observes the bound rootfs,
account and config, a running system manager, active/running/success `user@0`,
and the actual root bus socket. It does not start units/buses or hide diagnostics.
This is ready-now evidence with boot ID; a controller must separately record the
cold launch warning/exit, registration/path, user/session readiness, timed startup
and selected-worker binary pipes/lifetime. It is not desktop or production
admission. Borg's temporary diagnostic binary is never installed by this owner;
root must deploy the exact signature-verified release under immutable custody and
pin system Python plus all FOUR worker runtime hashes before signed preparation.

Controller review sequence, not native execution:

```text
Windows: verify exact selected registration UUID/path; stage reviewed immutable source in that worker.
Selected worker root: python3 -I -B /opt/revkit-wsl-backup/COMMIT/scripts/provision-wsl-boot.py --worker-policy POLICY.json
Selected worker root: SAME --worker-policy POLICY.json --apply --reviewed-plan-sha256 REVIEWED_HASH
Controller: coordinated selected-worker cold start and warning/timing capture, main/recovery untouched.
Selected worker root: SAME --worker-policy POLICY.json --worker-readiness
```

Actual elevated provisioning, cold acceptance and selected-worker production
installation remain unperformed source gates. The native tests exercise private
configuration fixtures, refusal/drift, failure retention and mocked readiness;
they do not mutate the host configuration or prove actual worker readiness.

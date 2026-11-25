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

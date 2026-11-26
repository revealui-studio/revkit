# Linux runtime provisioning

RevKit keeps development Node under nvm and privileged Node in a separate,
root-owned toolchain. The version and official artifact digests live in
`shell/config/linux-node.json`. Existing installations remain available for
recovery and for consumers whose reviewed bindings still name them.

From a reviewed RevKit checkout, inspect then apply the explicit installer:

```sh
python3 -B scripts/provision-linux-node.py --mode user
python3 -B scripts/provision-linux-node.py --mode user --apply
sudo python3 -B scripts/provision-linux-node.py --mode system --apply
```

The user installer installs nvm, selects its default, backs up changed shell
files and known executable links, and reconciles legacy fnm selectors. It
preserves unrelated environment variables, PATH entries and file modes.
Interactive and noninteractive consumers use `shell/lib/node-env.sh`.
The noninteractive environment also discovers an existing, user-owned native
session bus without starting services. Explicit session addresses are preserved.

Artifacts are checksum-verified before publication. New runtimes are staged and
verified before an atomic rename; subsequent runs verify the recorded vendor
file inventory. Every privileged execution first checks root custody. Unknown
executable/configuration collisions refuse rather than replace owner content.
The installer retains receipt and recovery copies under the user's state
directory or `/var/lib/revkit/node-backups`.

Corepack is preserved from the existing pure-JavaScript installation. Separate
pnpm installations and project package-manager contracts are unchanged. Audit
other global packages before adopting a profile that needs them.

Install the built native control CLI separately, using the canonical fleet pin:

```sh
REVEALFLEET_ROOT=/path/to/revealfleet bash bootstrap.sh --control-commands
revealui-harnesses hotfix check
```

This operation installs the CLI entry point without touching vendor homes.
Native continuity skills use RevSkills' explicit `bin/install.sh --native`
installer. It deploys a committed helper closure and preserves owner skills.

An accepted privileged agent runtime may bind an absolute executable and its
digest. Installing another Node version does not change those reviewed
bindings. Reconcile them through their maintained review lifecycle before
retiring an older runtime; never edit the runtime policy directly or point it
at user-writable nvm storage.

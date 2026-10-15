# Native control tree

`.revealui/content` is the reference for rules, agents, and skills.
Vendor directories are projections. `scripts/verify-copy-lockstep.sh`
checks those projections against this tree.

`bootstrap.sh` installs the operator home at `~/.revealui`. That home is
not this directory. The workboard path, when a repo uses a file board, is
`.revealui/workboard.md`.

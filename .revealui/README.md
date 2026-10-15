# Native control tree

`.revealui/content` is the reference for rules, agents, and skills.
Vendor directories are projections. `scripts/verify-copy-lockstep.sh`
checks those projections against this tree.

`bootstrap.sh` installs the operator home at `~/.revealui`. That home is
not this directory. The workboard path, when a repo uses a file board, is
`.revealui/workboard.md`.

Repository policy is maintained only in this native tree. The former tracked
`.claude/rules` tree and vendor ownership manifest were duplicate delivery
paths; they have been removed. Vendor caches remain local projections.

The durable-solutions rule is generated from
`revealui/packages/harnesses/src/content/definitions/rules/durable-solutions.ts`
through the maintained harness CLI's `content export` command. Its native
manifest hash must match the exported bytes. This refresh uses committed
canonical source at `RevealUIStudio/revealui` revision
`e63f7db120b9137287d32ba27dd226a777202536` (reviewed source branch based on integrated `test`
`e549ac50356425278dad852f5c2031ec098dc6b9`), exported through the maintained
source CLI. This definition uses the exact `revealfleet` identity and prohibits
one-off fixes; prior registered-hotfix permission was stale generated policy.
Owning-source integration is
[canonical policy PR #3135](https://github.com/RevealUIStudio/revealui/pull/3135),
tracked with promotion issue #233.

Bootstrap validates Node and every planned RevCon link through its maintained
`--dry-run` interface before making changes. Native hook commands bind the
resolved scanner path during projection; a native-home checkout uses its
tracked scanner source. The pinned RevCon integration test exercises actual
native materialization and generated headers inside a synthetic fleet.

Grok discovers its hook JSON under its vendor cache's `hooks/` directory.
The opt-in Claude adapter merges one `RevKit native scanner` handler into
vendor `settings.json`, preserving other settings and hooks. The previous
generated hook JSON in that vendor cache is retired because Claude does not
discover arbitrary hook files. These are vendor registrations of native
behavior; policy remains in `.revealui/content`.

Registration formats follow the vendor references:
[Grok hooks](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/10-hooks.md)
and [Claude hook locations](https://code.claude.com/docs/en/hooks#hook-locations).

# Explicit Codex state adapters

These operator tools prepare a separate offline home and narrowly reconcile
runtime-home configuration. They are not invoked by bootstrap and do not activate
`CODEX_HOME`, merge platform accounts, change permissions or edit a live database.

Python 3.11 or later is required. Windows also requires PowerShell 7 for writer and
ACL inspection. Run the tools from a reviewed deployment that includes the shared
`codex_adapter_lib.py` and `codex-state-layout-v1.json` beside the entry points.

## Runtime-home settings

`scripts/codex-shell-config.py plan --config <config.toml> --platform windows
--values-file <approved-runtime-homes.json>` validates an explicit map containing
only `NVM_HOME`, `COREPACK_HOME`, `PNPM_HOME`, `CARGO_HOME`, `RUSTUP_HOME`, `HF_HOME`
and `GH_CONFIG_DIR`. Linux/macOS use `NVM_DIR` instead of `NVM_HOME` and reject
runtime homes on mounted Windows drives. `--from-environment` reads only these
names from the invoking process; it does not reconstruct a filtered parent
environment. The Windows operator must supply the verified saved values when
those values are absent from the invoking process.

The `apply` action retains `inherit = "core"`, merges the approved values into
`shell_environment_policy.set`, preserves unrelated configuration, and records
physical before/after SHA256 values. The original bytes, including CRLF, go to a
private backup. On Windows, the empty replacement receives the source file's
effective access rules before reopening for content writes. Protected deny rules
remain effective; broader parent permissions are not inherited by the staged
file. Existing filter conflicts refuse rather than changing the
owner's allowlist. Execution-changing assignments such as `PATH`, `BASH_ENV`,
`NODE_OPTIONS` and `CODEX_HOME` are not accepted inputs. Existing owner assignments
are preserved. Windows environment names are merged case-insensitively.
The same-parent configuration replacement preserves the source protection flag
and inherited ACEs, including future parent propagation. Only the separate
offline-home copy materializes effective rules as protected explicit ACLs.

This does not prove application adoption. Verify actual manager/cache consumers
in an ordinary agent child after the supported application reload/restart. Tests
using manually injected values establish adapter behavior only.

## Offline state copy

Use `scripts/codex-home-migrate.py plan --source <old-home> --target <new-home>`
before `prepare` with the same arguments. Both require no writers, a recognized
layout, disjoint paths, a nonexistent destination and sufficient free space.
There is no writer/schema bypass flag. Windows refuses while ChatGPT, Codex or
the browser integration is running. Linux checks Codex process homes and open
source handles. The controller owns orderly shutdown and subsequent activation.

Planning copies database files and sidecars into private scratch before opening
SQLite. Preparation first copies the offline tree to a private sibling staging
directory. SQLite recovery and updates occur only in the copied state; hashes
and metadata confirm the source remained unchanged. Staging roots and backups are
private to the current user on POSIX, and to the current user, SYSTEM and
Administrators on Windows. Unknown reparse points, special files and escaping
links refuse.
Windows descendant files/directories retain the source owner's effective allow
and deny rules, materialized as explicit protected ACLs under the new private
root. This preserves current effective access and deliberately changes future
inheritance from the old parent. One batched PowerShell process uses the same
rule copier as single-file configuration writes. Source and target inventories
record owner, effective-access and raw-access hashes plus protection state;
later ACL drift fails the sealed-copy verification. Ownership changes,
noncanonical source ACLs or ineffective rule copies refuse. Application sandbox registration still
requires its supported configuration and consent after preparation.

The supported profile is pinned to recorded table, migration checksum and schema
metadata. `user_version = 0` alone is not a layout gate. Full SQL/migration
profiles for state, goals, logs, memories and queue came from an isolated
synthetic app-server fixture. Exact global-state/history schemas and history's
nine migration checksums came from a nonsecret read-only schema inventory;
additional schema objects refuse.
The descriptor contains no conversation, credential or account rows.

Only `state_5.sqlite.threads.rollout_path` and the exact known
`mcp_servers.node_repl.env.CODEX_HOME` storage field are rebased. Indexed rollouts
must exist below `sessions/` or `archived_sessions/`. Windows path comparison
supports case equivalence and extended-length forms. Every non-path thread
column, other database row, history file and auth file is preserved.

## Pending actions and activation

Preparation returns `storage_copy_verified`; it always leaves
`ready_for_activation` false. SQLite checks are insufficient for final acceptance.
The controller must validate ordinary resume as the first read, full read/list,
file identity, account/history preservation and application registrations before
activating the supported environment setting. Do not make the diagnostic fixture
scripts a production dependency.
Also verify the effective home of a normal child Codex process after cutover;
the app host adopting `CODEX_HOME` does not establish that filtered shell children
received the same setting.

Known old-home references produce explicit pending actions:

| Field or artifact | Required owner action |
| --- | --- |
| Hook commands and hook-state keys | Regenerate command paths from reviewed copied code, preserve existing approval records, then review changed definitions through `/hooks`. |
| Trusted code/services, package sources | Reconcile through supported application/plugin configuration and verify copied code identity. No trust grants are rewritten. |
| Browser native-host registrations | Re-register through the application and verify the new physical paths. |
| Saved sandbox roots, heartbeat permissions and workspace state | Review through supported application controls; stored grants remain unchanged. |
| Project roots, agent paths and attachment metadata | Reconcile actual workspace ownership and references; external workspaces are not renamed. |
| Known generated `tmp/arg0-linux/codex-arg0*/` command links | Preserve the originals; omit the links from the copy and let the application regenerate them. |
| Known `plugins/cache/openai-bundled/chrome/latest` alias | Preserve the original; omit the alias and regenerate/verify through application-owned plugin controls. |
| Unclassified metadata or unsupported layouts | Add a reviewed field/schema adapter before activation. |

Only the specified generated-link locations and known reparse tags receive this
treatment. They are not followed, rewritten or deleted in the source. Relative
links that stay within the home are copied as links. Other external links refuse.
No plugin remove/re-add operation, database permission edit or vendor patch is
performed. Hook review is described in the
[official hook trust documentation](https://learn.chatgpt.com/docs/hooks#review-and-trust-hooks).

`verify --target <new-home>` is a sealed offline-copy check before application
adoption. It checks the receipt, source preservation, copied content and database
integrity. Normal startup, link regeneration and resume can change the target;
subsequent application/identity/history/security checks belong in separate
controller evidence. Do not bypass the offline manifest check to call an adopted
home unchanged. `rollback --target <new-home>` refuses if the source has changed and
retains the target under a unique rollback name, including subsequent writes.
It never deletes the original or rewrites conversation history. Restoring the
previous activation setting and restarting the application remain controller
actions; the adapter does not perform activation or environment rollback.

## Validation

Run `python3 -B -m unittest discover -s tests -p 'test_codex_*.py' -v`.
The synthetic tests cover path boundaries, schema/checksum refusal, copied-state
mutation limits, source preservation, metadata consent holds, capacity, partial
copy failure, rollback, exact configuration backups and secret-value redaction.
Native Windows ACL, reparse and real process tests must also run on Windows;
Linux mocks or skipped Windows fixtures do not establish those results.

# Offline Codex cutover and acceptance

This is an operator sequence, not permission to interrupt an active turn.
Finish source commits, PRs, the session snapshot and checkpoint before the
controller requests application Quit. Preserve the old homes and every recovery
artifact. Windows and native Linux identities remain separate.

## Before Quit

Pin the reviewed source commit and complete native Windows synthetic tests.
Record the installed application build, source and destination, existing user
environment overrides, effective configuration, account identifier fingerprints
and nonsecret inventory hashes. Include `CODEX_HOME`, `CODEX_SQLITE_HOME`,
`sqlite_home` and the separately observed Electron user-data location. An
external SQLite location requires its own reviewed preservation before cutover.

`CODEX_HOME` is the supported state root and must exist before use; SQLite
location overrides take precedence as described in the
[environment reference](https://learn.chatgpt.com/docs/config-file/environment-variables).
The migration-owned copied configuration projects the adopted home into ordinary
shell children without broadening core inheritance or overwriting a conflicting
owner identity/filter. Verify actual child adoption after restart.

Capture the baseline across all nine recognized databases. The two desktop
layouts have distinct schemas and migration chains despite equal user version.
Retain account, automation, inbox and history rows. Record indexed rollout
presence separately from history completeness: a missing JSONL may have database
history, or may already lack a local projection. Successful metadata reads alone
do not prove complete history. Do not fabricate JSONL, drop rows, mass-resume old
chats or repair historical records by substring replacement.

The Electron UI profile is a separate preservation/adoption surface. The
installed application's observed override must be independently validated before
claiming its data moved. This state adapter does not copy or activate that UI
profile. Retain its old directory and record it as an open host task.

## Offline preparation

1. Use supported application Quit only after the saved-work safe point. Close
   its associated Codex/browser writers normally. The adapter must independently
   find zero writers; there is no writer bypass or automatic process kill.
2. Run the reviewed Windows Python adapter `plan --source <old-home> --target
   <new-home>`. The destination must be absent, disjoint and have enough free
   space. Unknown layouts, links, unreadable files or ambiguous permissions
   refuse. A live guard-file census does not waive offline readability.
3. Run `prepare` with those same explicit roots. Inspect the receipt and
   field-specific pending actions. The source inventory, ACL signatures, all
   copied data and both schema-profile digests must match. Existing rollout
   absence is recorded against source thread identity and normalized relative
   storage path; present-to-missing changes fail.
4. Run `verify --target <new-home>` before starting a consumer. It checks the
   sealed copy and original preservation, opens all recognized databases in
   read-only mode and checks the rollout baseline. Passing this step establishes
   an offline storage copy, not activation readiness.

## Registration and consent

Keep the existing sandbox mode, permission grants, hook approvals and account
assignments. Do not insert permission rows, enable features, reschedule
automations or edit operating-system registrations directly.

| Surface | Supported review and acceptance |
| --- | --- |
| Changed hook paths | Regenerate definitions from reviewed copied code; retain old approval records; review the new definitions through `/hooks`. Trust is definition-specific. |
| Windows sandbox | Call `windowsSandbox/readiness`. If the configured legacy mode requires setup, use `windowsSandbox/setupStart` for that same reviewed mode and wait for completion. Do not silently change sandbox mode. |
| Browser native host | Reconnect through the application's browser integration and verify the resulting physical host path. Preserve the prior registration until the new one is verified. |
| Plugins and generated command/cache links | Use the application's existing installed-plugin controls; confirm plugin identity/version and regenerated paths. No invented refresh command or remove/re-add shortcut. |
| Current automation/project paths | Review the named fields through their supported editors. Preserve schedules, status, account ownership and historical run context. |
| Unknown current metadata | Stop at the named artifact/field and add a reviewed consumer adapter. Do not grant blanket approval to unresolved references. |

Hook review and sandbox readiness/setup are documented in
[Hooks](https://learn.chatgpt.com/docs/hooks) and
[App Server](https://learn.chatgpt.com/docs/app-server).

## Adoption and ordinary history verification

The controller records and applies the supported user-level home setting, then
starts the application normally. A still-running process with cached environment
is not adoption evidence. Check the actual app-server state root and a normal
child's `CODEX_HOME`, runtime homes, account and permission context. Linux must
continue using its own native home.

Use a fresh isolated synthetic acceptance case whose first thread operation is
ordinary `thread/resume`, without an earlier read that could populate history.
Then exercise supported thread metadata/list and paginated history reads.
Compare identifiers, turn/item totals, content hashes and account context with
their recorded baseline; do not print conversation contents. The supported
resume/pagination behavior is documented in the
[App Server reference](https://learn.chatgpt.com/docs/app-server).

Separately verify a bounded representative set of existing histories, including
present JSONL, projected database-backed history and the preexisting unprojected
class. A successful call returning zero turns is not proof of complete history.
Preserve the baseline limitation in acceptance evidence. Do not start a new
model turn or change old chats merely to make the check pass.

Application startup and supported registration may legitimately change the
target after offline verification. Keep those acceptance results separate from
the original sealed-copy receipt; do not bypass a later manifest mismatch or
call an adopted home byte-identical. `ready_for_activation` remains false in
adapter output; the controller owns the evidence-based disposition.

## Rollback

Stop target consumers normally, restore only the previously recorded supported
environment setting, and restart against the retained source. Preserve target
writes. The adapter's `rollback` retains the target under a unique name and
refuses when original preservation can no longer be established. It does not
delete either history, rewrite authentication or perform environment rollback.
Old source retirement is a later owner decision after independent recovery,
registration and ordinary-consumer acceptance; no automatic deletion follows.

## External copy executor

`scripts/Invoke-CodexOfflineCopy.ps1` waits for normal application Quit and runs
the maintained adapter's plan, prepare and verify phases with private receipts.
It never kills processes, activates a home, changes environment settings,
restarts the app, copies the UI profile or deletes originals. A successful copy
is `copy-verified-awaiting-operator-review`, regardless of pending-action count.

Prepare a JSON request outside the homes and new receipts. Exact fields:
`schemaVersion` (1), `sourceHome`, `targetHome`, `adapterDirectory`,
`adapterHashes`, `pythonPath`, `pythonSha256`, `receiptDirectory`,
`waitTimeoutSeconds` (1–3600), `pollSeconds` (1–30, no greater than timeout).
Use fully qualified local paths without linked ancestry. Target and receipt
directories must be absent. Homes, adapters and receipts must be disjoint.
The adapter directory must contain this executor. Pin the Python executable
and SHA-256 for these six sibling adapter files:

- `Invoke-CodexOfflineCopy.ps1`
- `codex-home-migrate.py`
- `codex_adapter_lib.py`
- `codex-state-layout-v1.json`
- `codex-desktop-layout-v1.json`
- `lib/WindowsArtifactDeployment.ps1`

Hash and review the request, then invoke the deployed executor using
`-RequestPath <request.json> -ExpectedRequestSha256 <digest>`.
Only start a hidden background PowerShell helper after the saved-work boundary.
Request normal Quit separately. Do not include a source-home command-line
argument: the writer guard deliberately treats source-referencing command lines
as possible writers. An unavailable census or wait timeout stops the executor;
the underlying adapter independently checks writers and consistency every phase.

`executor.json` records waiting, progress, refusal or copy verification. Each
phase retains JSON output and diagnostic logs. Exit 2 with named pending actions
is distinct from refusal; it does not authorize activation. Review those actions
and complete the separate supported consumer and consent acceptance above.
Reopening the old source may change it; do not activate a stale copy or bypass a
manifest mismatch. Retain attempted targets and use a new absent destination for
a fresh reviewed copy if needed. No background helper is an operational dependency.

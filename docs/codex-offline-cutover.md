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

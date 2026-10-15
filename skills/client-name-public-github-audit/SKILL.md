---
name: Client-name public GitHub audit
description: >-
  Use when any RevealFleet bot audits, inventories, or scrubs
  client/buyer/end-client identifiers on public GitHub; runs the daily org leak
  scan; writes Build/cloud-agent/PR copy that might leak names; or wires the
  revkit check-no-client-names gate. Whole-fleet lock.
---
# Client-name public GitHub audit

**Whole RevealFleet.** Every bot. Soft-enforce: REV. CEO runs Layer A daily org audit and the private inventory. Defense in depth until client, buyer, and end-client identifiers never appear on **public** GitHub.

Pair with `docs/client-name-public-github.md` and `scripts/check-no-client-names.sh` in revkit.

## When to use
- Daily org leak scan / inventory (CEO Layer A)
- Any fleet bot about to write a public PR, comment, fixture, commit message, or Build/cloud-agent paste
- Scrubbing a public hit
- Wiring the Layer B CI/pre-push gate

## Layers
| Layer | What | Owner |
| --- | --- | --- |
| A | Org-wide GitHub API audit, scrub editable, inventory residuals | CEO + daily routine; private box `/workspace/client-name-github-audit/` |
| B | Local/CI watchlist gate for files, commit messages, and an opt-in commit-msg hook, plus the hardcoded literal scanner that stays in git | revkit `scripts/check-no-client-names.sh` and `scripts/check-client-leaks.sh` |
| C | Soft locks: Build pastes, cloud-agent prompts, PR templates use generic labels only | **Every bot**; REV enforces |
| D | Rolling inventory + guardrail-gap loop until public hits stay 0 | CEO inventory |

Related but different: `scripts/check-no-private-leaks.sh` catches **private paths / machine paths**. This skill and `check-no-client-names.sh` catch **people and business identifiers**.

`scripts/check-client-leaks.sh` stays. Its `PATTERNS` are long-lived literals that public CI must keep enforcing with no secret. The watchlist gate is for operator-local or CI-secret terms that must not be committed. Do not delete either scanner.

## Severity
- **P0** Editable public PR/issue title, body, or comment
- **P1** Tip code or fixtures on a public branch (`test` / `main` / default)
- **P2** Orphaned history (force-pushed SHA still cached)
- **P3** Private repo only (scrub before any visibility change)

## Private watchlist
Load terms from the private SSOT (default `/workspace/client-name-github-audit/WATCHLIST.md`). For the watchlist gate, use `.client-name-watchlist.local` (gitignored) or `CLIENT_NAME_WATCHLIST_FILE` / CI secret.

**Never** commit real watchlist terms into a public repo, public PR text, commit message, or Build paste destined for a public remote.

## Generic replacements (public vocabulary)
buyer · network Consultation · end-client · Studio Consultation invoice · demo (share seed) · agency client

## Surfaces (public repos only)
For each watchlist term and slug form: PR/issue titles and bodies, comments, code on tip branches, open-PR commit messages, fixtures, workflows. Prefer org search, then **direct file/PR reads** (search indexes lag).

Org scope: all public `RevealUIStudio/*` repos (not CEO-only).

## Actions
1. **P0** Rewrite in place to generic labels.
2. **P1** Forward scrub PR. No force-push of merged history without an owner SHA list and yes.
3. **P2** Document old SHA; confirm no refs point at it.
4. **P3** List under private residual only.

## Inventory writeback
Update `/workspace/client-name-github-audit/INVENTORY.md` and `runs/YYYY-MM-DD/REPORT.md`:
- repos scanned, scrubbed counts
- open residuals with severity and recommended fix
- 1-5 guardrail gaps
- re-run zero-hit confirmation queries after scrub

## Layer B quick use
```bash
bash scripts/check-no-client-names.sh
cp templates/client-name-watchlist.example .client-name-watchlist.local
# edit local file with real terms (never commit)
bash scripts/check-no-client-names.sh
# Forward-only commit messages (does not rewrite accepted history):
bash scripts/check-no-client-names.sh --commits 'origin/test..HEAD'
# Opt-in commit-msg hook: bash scripts/hooks/commit-msg-client-names.sh "$1"
# CI: CLIENT_NAME_WATCHLIST_FILE + optional CLIENT_NAME_WATCHLIST_REQUIRED=1
# Hardcoded companion (always on in public CI): bash scripts/check-client-leaks.sh
```

## Soft locks (Layer C) - every bot
- Fixtures: `network_buyer` / `agency_client` / `end_client_example`, never live metadata slugs
- Share seed default: `demo`, never a buyer business subdomain
- PR bodies: buyer / end-client, never Desk first names or company names

## Done criteria
- Box report + inventory updated (Layer A runs)
- P0 scrubbed or blocked with reason
- Residuals ranked; gaps named
- Tell the operator only on new hits, scrubs, or gaps; stay quiet when clean or unchanged
- Fleet bots: absorb the lock; do not ping the operator just to acknowledge

## Anti-patterns
- Treating this as CEO-only
- Putting watchlist terms into public revkit docs, scripts, or CI YAML
- Deleting `check-client-leaks.sh` because the watchlist gate exists
- Trusting code search alone
- History rewrite without owner confirmation

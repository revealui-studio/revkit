# Client-name public GitHub defense

Defense in depth so buyer, network Consultation, end-client, and agency-client identifiers never appear on **public** GitHub. This document ships in revkit. It must never list real watchlist terms.

Do not use an em dash (U+2014) in this document or in public copy. Use a hyphen, a colon, or parentheses instead.

## Problem

Public org surfaces (PR titles and bodies, comments, tip code, fixtures, commit messages, CI workflows) can accumulate real buyer or end-client identifiers from Desk pastes, Build prompts, cloud-agent fixtures, or share-seed slugs. Search indexes lag. Editable hits can be scrubbed. Tip code needs a forward PR. Merged history is owner-gated.

## Fleet scope

Applies to the **whole RevealFleet** (every bot and every public RevealUIStudio repo). Soft-enforce owner: REV. CEO runs Layer A daily org audit and maintains the private inventory. Every bot applies Layer C on Build pastes, cloud-agent prompts, PR titles and bodies, commits, and fixtures.

## Layers A-D

### Layer A - Bot daily org audit

Grok Bot routine plus skill `client-name-public-github-audit` scans the studio public org via GitHub API: PRs, issues, comments, code tips, recent commits. Scrubs editable public text to generic labels. Inventories residuals privately on the box. Stays quiet when clean (per routine).

Private inventory home: `/workspace/client-name-github-audit/` (box only; not a public git tree).

### Layer B - Local / CI gate (two scanners)

Layer B is two gates that stay side by side. Neither replaces the other.

| Scanner | What it matches | Where the terms live |
|---------|-----------------|----------------------|
| `scripts/check-client-leaks.sh` | Literal denylist (`tag\|literal\|reason`) | Org Actions secret `CLIENT_LEAK_PATTERNS`. Local fallback: gitignored `.client-name-watchlist.local` in that same line format. CI: `.github/workflows/check-client-leaks.yml` |
| `scripts/check-no-client-names.sh` | Operator watchlist terms in files, and in commit messages when `--commits` or the commit-msg hook runs | Gitignored local file, or a CI secret file path, or `CLIENT_NAME_PATTERNS`. Never committed |

`scripts/check-no-private-leaks.sh` is a different companion. It catches paths, hostnames, license-shaped strings, and machine homes. It does not catch people or business identifiers.

`check-client-leaks.sh` does not keep its literal pattern list in git. Public CI passes `CLIENT_LEAK_PATTERNS` into the shared scanner action. An empty or missing secret fails closed (exit 2). Locally, export that variable or add `tag|literal|reason` lines to `.client-name-watchlist.local`. If neither source is present, the script prints a warning and exits 2. Add new lines to the org secret, never to a committed file. The watchlist gate is a separate list and stays inactive in public CI until its own secret is mounted. Do not delete either scanner.

Public repos must never contain the real watchlist. The watchlist gate loads patterns from the first found of:

1. `$CLIENT_NAME_WATCHLIST_FILE`
2. `.client-name-watchlist.local` under the repo root
3. `$CLIENT_NAME_PATTERNS` (newline or `|` separated)

If no watchlist is present, the script prints a WARN and exits 0 (gate inactive) so public CI without a secret does not false-fail. Layer A still runs daily. Set `CLIENT_NAME_WATCHLIST_REQUIRED=1` to force exit 2 when the watchlist is missing (strict laptop or private CI). That short-circuit happens before any commit scan, so a missing watchlist does not fail on a bad rev-range.

Exit codes: 0 clean or inactive, 1 violation, 2 setup error. `LEAK_JSON=1` prints a one-line JSON object.

File scan is the default (`bash scripts/check-no-client-names.sh` or explicit paths). Commit messages are a separate mode. Scrubbing a pull request title does not change a commit message already written, and it does not stop the next commit from copying a buyer or company slug into the subject or body.

```bash
bash scripts/check-no-client-names.sh --commits 'origin/test..HEAD'
SCAN_COMMIT_MESSAGES=1 bash scripts/check-no-client-names.sh
CLIENT_NAME_PR_TITLE="$title" bash scripts/check-no-client-names.sh --commits 'origin/test..HEAD'
```

Default range when `--commits` has no argument: `origin/$GITHUB_BASE_REF..HEAD` when `GITHUB_BASE_REF` is set and that remote-tracking ref exists (or `$GITHUB_BASE_REF..HEAD` when only the local ref exists). A set but unresolvable `GITHUB_BASE_REF` exits 2. It does not fall through to another base. When `GITHUB_BASE_REF` is unset, the default is `origin/test..HEAD`, and a missing `origin/test` also exits 2. `CLIENT_NAME_COMMIT_RANGE` overrides that default. An explicit `--commits <range>` wins over both. Two-dot (`base..HEAD`) is commits reachable from HEAD that are not on the base (the pull request commit list). A three-dot range also selects commits that exist only on the base. Pass one only if you mean to. R-003 class residuals (a buyer or company slug already in merged history) are forward-only. Do not rewrite them. This gate blocks new messages. It does not scan accepted history on the base.

In `--commits` mode, `CLIENT_NAME_PR_TITLE` is also matched (the subject a squash or merge would use). File-only mode ignores that variable. Hits look like `commit:<sha>:subject`, `commit:<sha>:body`, or `pr:title`.

Dry run with placeholders. Do not substitute real terms:

```bash
CLIENT_NAME_PATTERNS='buyer_example|agency_client_example' \
  bash scripts/check-no-client-names.sh --commits 'origin/test..HEAD'
```

`scripts/hooks/commit-msg-client-names.sh` reads the proposed message file and uses the same matcher. Inactive without a local watchlist. Bootstrap and `git-hooks/` do not install it.

```bash
ln -sfn ../../scripts/hooks/commit-msg-client-names.sh .git/hooks/commit-msg
```

Husky (`.husky/commit-msg`): `bash scripts/hooks/commit-msg-client-names.sh "$1"`

Lefthook (`lefthook.yml`):

```yaml
commit-msg:
  commands:
    client-names:
      run: bash scripts/hooks/commit-msg-client-names.sh {1}
```

A proposed-message hit looks like `commit:proposed:subject` or `commit:proposed:body`. Lines that start with `#` are ignored, same as git. Never put real watchlist terms in a commit message, this hook, CI, or any other git object.

Example template (placeholders only, such as `buyer_example` and `agency_client_example`): `templates/client-name-watchlist.example`. The `templates/` directory here is that sample. It is not the old config-render templates tree.

`.github/workflows/check-no-client-names.yml` runs the file scan with no secret mounted, and on `pull_request` it also runs `--commits` for `base..HEAD` plus the pull request title. Both steps stay inactive and exit 0 until a watchlist is injected. `CLIENT_NAME_WATCHLIST_REQUIRED` stays unset. To require a watchlist later, without committing terms:

1. Store the watchlist text in a GitHub Actions secret. This repo does not name or create that secret.
2. In the job, write the secret to a file outside the checkout (for example under `$RUNNER_TEMP`) with mode `0600`.
3. Export `CLIENT_NAME_WATCHLIST_FILE` to that path on the file-scan step and the pull-request commit-scan step.
4. Optionally export `CLIENT_NAME_WATCHLIST_REQUIRED=1` so a missing file fails the job (exit 2) instead of staying inactive.

Do not put term text in the workflow YAML.

### Layer C - Soft locks

Build prompts, cloud-agent instructions, and PR templates use **generic labels only**:

- buyer
- network Consultation
- end-client
- Studio Consultation invoice
- demo (share seed slug)
- agency client

Never paste Desk or CRM person or company names into public PR text or fixtures destined for public remotes.

### Layer D - Inventory loop

Rolling `INVENTORY.md` under the private box audit home, severity P0-P3, guardrail gaps, until public hits stay at 0.

## Severity

| Level | Meaning |
|-------|---------|
| P0 | Editable public PR / issue / comment |
| P1 | Tip code / fixtures on a public branch |
| P2 | Orphaned history / force-pushed SHA |
| P3 | Private repo only |

## What must never be committed publicly

- Real watchlist terms (person, company, end-client business, private slugs)
- `.client-name-watchlist.local` (gitignored)
- The live watchlist file under the private box audit home
- Desk or CRM dumps destined for public remotes

Safe to commit: this design doc, the gate script (no embedded terms), the client-leak scanner (no embedded pattern list), the example watchlist template with placeholders only, and the skill markdown that refers to watchlist terms generically.

## How bot, laptop, and CI cooperate

| Actor | Role |
|-------|------|
| Grok Bot (Layer A) | Daily org scan; scrub editable; write private inventory and report on the box |
| Laptop checkout | Local run can load `.client-name-watchlist.local` (gitignored). Optional commit-msg hook scans the proposed message |
| Public CI, client-leak scanner | `check-client-leaks.sh` runs with the org secret `CLIENT_LEAK_PATTERNS`. A missing secret fails closed |
| Public CI, watchlist gate | File scan, and on pull request the commit-message scan, stay inactive (warn, exit 0) unless `CLIENT_NAME_WATCHLIST_FILE` or `CLIENT_NAME_PATTERNS` is injected. Optional strict mode: `CLIENT_NAME_WATCHLIST_REQUIRED=1` |
| Soft locks (Layer C) | Templates and prompts stay generic so Layer A and Layer B see fewer new hits |

## Skill home

The repo-owned skill is `skills/client-name-public-github-audit/SKILL.md`.

`.claude/skills/` is the revcon copy-mode surface. `scripts/verify-copy-lockstep.sh` rejects a tracked file under `.claude/skills/` that is not in `.claude/.revcon-manifest.json`. This skill ships with the gate. It is not a revcon profile copy, so it does not live under `.claude/skills/`.

## Pointers

| Item | Path |
|------|------|
| Design (this file) | `docs/client-name-public-github.md` |
| Watchlist gate | `scripts/check-no-client-names.sh` |
| Commit-msg hook helper (opt-in) | `scripts/hooks/commit-msg-client-names.sh` |
| Watchlist gate CI (inactive without a secret; pull request also scans commits) | `.github/workflows/check-no-client-names.yml` |
| Gate tests (placeholder patterns only) | `tests/test-check-no-client-names.sh` |
| Client-leak scanner | `scripts/check-client-leaks.sh` |
| Client-leak scanner CI | `.github/workflows/check-client-leaks.yml` |
| Client-leak scanner tests (placeholder patterns only) | `tests/test-check-client-leaks.sh` |
| Path / private-leak companion | `scripts/check-no-private-leaks.sh` |
| Example watchlist | `templates/client-name-watchlist.example` |
| Skill | `skills/client-name-public-github-audit/SKILL.md` |
| Private watchlist (box) | `/workspace/client-name-github-audit/WATCHLIST.md` |
| Private inventory (box) | `/workspace/client-name-github-audit/INVENTORY.md` |

`.client-name-watchlist.local` must remain gitignored.

#!/usr/bin/env bash
# Synthetic Git fixture for registered worktree creation and conservative retirement.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/fleet" "$TMP/remote.git"
git init -q --bare "$TMP/remote.git"
git init -q -b test "$TMP/fleet/demo"
mkdir -p "$TMP/fixture-hooks"
git -C "$TMP/fleet/demo" config core.hooksPath "$TMP/fixture-hooks"
git -C "$TMP/fleet/demo" config user.name Fixture
git -C "$TMP/fleet/demo" config user.email fixture@example.invalid
printf 'fixture\n' >"$TMP/fleet/demo/README"
printf '.env.worktree\nignored-file\n' >"$TMP/fleet/demo/.gitignore"
git -C "$TMP/fleet/demo" add README .gitignore
git -C "$TMP/fleet/demo" commit -qm initial
git -C "$TMP/fleet/demo" remote add origin "$TMP/remote.git"
git -C "$TMP/fleet/demo" push -q -u origin test

export REVEALFLEET_ROOT="$TMP/fleet"
export RFG_WT_ROOT="$TMP/fleet/.wt"
export REVEALUI_CLAIMS_DIR="$TMP/claims"
export REVEALUI_WT_ENV_DIR="$TMP/env"
export RFG_STORM_PREFLIGHT_SKIP=1
. "$ROOT/shell/lib/worktree-env.sh"

open_out="$(bash "$ROOT/shell/bin/rfg.sh" open demo lifecycle-fixture --pr 123 --no-agent)"
wt="$TMP/fleet/.wt/lifecycle-fixture"
[ "${open_out##*$'\n'}" = "$wt" ]
record="$(_rfg_worktree_record demo lifecycle-fixture)"
python3 - "$record" "$wt" <<'PY'
import json, sys
record = json.load(open(sys.argv[1], encoding='utf-8'))
assert record['kind'] == 'worktree' and record['state'] == 'open'
assert record['worktree'] == sys.argv[2]
assert record['branch'] == 'feat/lifecycle-fixture'
assert record['repo'] == 'demo' and record['purpose'] == 'lifecycle-fixture'
assert record['prHint'] == '123'
assert record['gitCommonDir']
PY

# PID/TTL sweeps and generic claim release must not erase durable lifecycle.
rfg_claim_sweep >/dev/null
[ -f "$record" ]
if rfg_claim_release demo worktree-lifecycle-fixture >/dev/null 2>&1; then
  echo 'generic release erased lifecycle record' >&2; exit 1
fi

printf 'dirty\n' >"$wt/dirty"
if rfg_worktree_retire demo lifecycle-fixture "$TMP/fleet/demo" >/dev/null 2>&1; then
  echo 'dirty worktree was retired' >&2; exit 1
fi
[ -d "$wt" ]
rm "$wt/dirty"

printf 'local edit\n' >>"$wt/.env.worktree"
if rfg_worktree_retire demo lifecycle-fixture "$TMP/fleet/demo" >/dev/null 2>&1; then
  echo 'diverged ignored environment was retired' >&2; exit 1
fi
cp "$TMP/env/demo/lifecycle-fixture.env" "$wt/.env.worktree"
printf 'saved cache\n' >"$wt/ignored-file"
if rfg_worktree_retire demo lifecycle-fixture "$TMP/fleet/demo" >/dev/null 2>&1; then
  echo 'ignored local material was retired' >&2; exit 1
fi
rm "$wt/ignored-file"

printf 'unmerged\n' >>"$wt/README"
git -C "$wt" add README
git -C "$wt" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm unmerged
if rfg_worktree_retire demo lifecycle-fixture "$TMP/fleet/demo" >/dev/null 2>&1; then
  echo 'unmerged branch was retired' >&2; exit 1
fi
[ -d "$wt" ]
git -C "$TMP/fleet/demo" merge -q --ff-only feat/lifecycle-fixture
git -C "$TMP/fleet/demo" push -q origin test

RFG_CLAIM_WORKTREE="$wt" rfg_claim_acquire demo independent-session >/dev/null
if rfg_worktree_retire demo lifecycle-fixture "$TMP/fleet/demo" >/dev/null 2>&1; then
  echo 'independent claim was ignored during retirement' >&2; exit 1
fi
rfg_claim_release demo independent-session >/dev/null

printf '{broken' >"$TMP/claims/demo/malformed.json"
if rfg_worktree_retire demo lifecycle-fixture "$TMP/fleet/demo" >/dev/null 2>&1; then
  echo 'malformed claim was ignored during retirement' >&2; exit 1
fi
rm "$TMP/claims/demo/malformed.json"

mkdir -p "$TMP/bin"
real_git="$(command -v git)"
cat >"$TMP/bin/git" <<EOF
#!/usr/bin/env bash
case "\$*" in *'ls-files --others --ignored'*) exit 42 ;; esac
exec "$real_git" "\$@"
EOF
chmod +x "$TMP/bin/git"
if PATH="$TMP/bin:$PATH" rfg_worktree_retire demo lifecycle-fixture "$TMP/fleet/demo" >/dev/null 2>&1; then
  echo 'failed ignored-file enumeration was ignored' >&2; exit 1
fi
[ -d "$wt" ]

exec {held_fd}<"$wt/README"
if rfg_worktree_retire demo lifecycle-fixture "$TMP/fleet/demo" >/dev/null 2>&1; then
  echo 'open file descriptor was ignored during retirement' >&2; exit 1
fi
exec {held_fd}<&-

# A live independent session in the target checkout must retain it.
(cd "$wt" && sleep 30) &
holder=$!
sleep 0.2
if rfg_worktree_retire demo lifecycle-fixture "$TMP/fleet/demo" >/dev/null 2>&1; then
  echo 'active worktree was retired' >&2; exit 1
fi
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true

# Simulate an interrupted retire after its durable state transition.
python3 - "$record" <<'PY'
import json, sys
record = json.load(open(sys.argv[1], encoding='utf-8'))
record['state'] = 'retiring'
with open(sys.argv[1], 'w', encoding='utf-8') as output: json.dump(record, output)
PY
rfg_worktree_retire demo lifecycle-fixture "$TMP/fleet/demo" >/dev/null
[ ! -e "$wt" ]
python3 - "$record" <<'PY'
import json, sys
assert json.load(open(sys.argv[1], encoding='utf-8'))['state'] == 'retired'
PY

# A mirror failure after Git creation must be reported as partial bootstrap.
touch "$TMP/not-a-directory"
if REVEALUI_WT_ENV_DIR="$TMP/not-a-directory" bash "$ROOT/shell/bin/rfg.sh" open demo partial-fixture --no-agent >"$TMP/out" 2>"$TMP/err"; then
  echo 'failed mirror reported successful bootstrap' >&2; exit 1
fi
grep -q 'worktree exists but environment bootstrap failed' "$TMP/err"
[ -d "$TMP/fleet/.wt/partial-fixture" ]
[ -f "$(_rfg_worktree_record demo partial-fixture)" ]

# An existing checkout without a pre-creation reservation cannot be adopted.
git -C "$TMP/fleet/demo" worktree add -q -b feat/other-owner "$TMP/fleet/.wt/other-owner" origin/test
if bash "$ROOT/shell/bin/rfg.sh" open demo other-owner --no-agent >/dev/null 2>"$TMP/other-owner.err"; then
  echo 'unregistered checkout was adopted' >&2; exit 1
fi
[ ! -e "$(_rfg_worktree_record demo other-owner)" ]

# A damaged reservation blocks creation and remains available for recovery.
printf '{incomplete' >"$(_rfg_worktree_record demo damaged-record)"
bad_record="$(_rfg_worktree_record demo damaged-record)"
rfg_claim_sweep >/dev/null
[ -f "$bad_record" ]
if rfg_claim_release demo worktree-damaged-record >/dev/null 2>&1; then
  echo 'generic claim release removed damaged lifecycle record' >&2; exit 1
fi
if rfg_claim_acquire demo worktree-damaged-record >/dev/null 2>&1; then
  echo 'generic claim acquire overwrote damaged lifecycle record' >&2; exit 1
fi
if bash "$ROOT/shell/bin/rfg.sh" open demo damaged-record --no-agent >/dev/null 2>"$TMP/damaged.err"; then
  echo 'damaged reservation was overwritten' >&2; exit 1
fi
[ ! -e "$TMP/fleet/.wt/damaged-record" ]

# Both maintained launchers use the same registry and bootstrap primitive.
unset REVEALUI_WT_ENV_DIR
export REVEALUI_WT_ENV_DIR="$TMP/env"
bash "$ROOT/shell/bin/rfc.sh" open demo claude-fixture --no-agent >/dev/null
python3 - "$(_rfg_worktree_record demo claude-fixture)" <<'PY'
import json, sys
record = json.load(open(sys.argv[1], encoding='utf-8'))
assert record['kind'] == 'worktree' and record['agent'] == 'claude'
PY
echo 'PASS: worktree lifecycle registration, retention, crash retry, retirement and partial bootstrap'

#!/usr/bin/env node
// m4-sudoers-fs-scanner.js — Sudoers + filesystem invariant scanner
//
// Spec: internal fleet-security-hardening lane § M-4 (meta-durability-fixes)
// Companion designs: sprint-tier-0.md T0-1, T0-2, T0-3
//
// Source of truth: revkit/shell/bin/m4-sudoers-fs-scanner.js (this file).
// Runtime location: ~/.revealui/hooks/m4-sudoers-fs-scanner.js (copied by
//   bootstrap.sh).
// Invoked from adapter hooks and templates/hooks/session-start.js.
//   Those callers point at this native path.
//
// Read-only. No mutations. Pure stat + read + parse.
//
// Exit codes:
//   0  — clean: every invariant satisfied
//   2  — violation: at least one invariant failed; structured findings on stderr
//   1  — internal error (unexpected exception); stderr describes
//
// Output format on violation (stderr, one block per finding):
//   [M-4] <CLASS> VIOLATION: <where> — <rule failed>.
//     Remediation: <pointer to lane plan, file:line within the lane>
//
// No regex authored anywhere in this file (per fleet rule). All parsing
// uses String.prototype methods + line-by-line iteration + Set lookups.
//
// Test-mode env vars (for revkit/tests/m4-scanner/):
//   M4_SUDOERS_DIR_OVERRIDE  — read sudoers fixtures from this dir instead of /etc/sudoers.d
//   M4_FS_OVERRIDE_HOME      — pretend $HOME is this dir (for ~/.age-identity, ~/.ssh, ~/.revealui)
//   M4_FS_OVERRIDE_SUDOLOG   — path to use instead of /var/log/sudo.log

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");

// ============================================================================
// Configuration
// ============================================================================

const SUDOERS_DIR = process.env.M4_SUDOERS_DIR_OVERRIDE || "/etc/sudoers.d";
const HOME_DIR = process.env.M4_FS_OVERRIDE_HOME || os.homedir();
const SUDOLOG = process.env.M4_FS_OVERRIDE_SUDOLOG || "/var/log/sudo.log";

// Remediation pointer shown on violation. Generic phrasing so this scanner
// is safe to publish in revkit (which is going public per T0-15) without
// leaking internal-repo paths. Fleet operators know where to find the spec;
// non-fleet contributors won't have this scanner installed at all.
const REMEDIATION_LANE =
  "your fleet's internal sprint-tier-0.md (M-4 spec)";

// System-binary prefixes that NOPASSWD can never legitimately reach.
const SYSTEM_BINARY_PREFIXES = [
  "/usr/bin/",
  "/bin/",
  "/usr/sbin/",
  "/sbin/",
];

// Glob/wildcard characters that must never appear in a NOPASSWD arg list.
const GLOB_CHARS = new Set(["*", "?", "[", "]"]);
// Known sudoers Cmnd_Spec tags. A command spec may carry a chain of these,
// each terminated by ':', glued together (NOEXEC:NOPASSWD:) or split across
// whitespace (NOEXEC: NOPASSWD: / NOPASSWD :ALL). The command begins at the
// first chain element that is NOT a known tag.
const SUDO_TAGS = new Set([
  "NOPASSWD",
  "PASSWD",
  "NOEXEC",
  "EXEC",
  "SETENV",
  "NOSETENV",
  "LOG_INPUT",
  "NOLOG_INPUT",
  "LOG_OUTPUT",
  "NOLOG_OUTPUT",
  "MAIL",
  "NOMAIL",
  "FOLLOW",
  "NOFOLLOW",
]);

// Required Defaults entries that must be present in /etc/sudoers.d/00-defaults.
// Stored as a Set for O(1) lookups during file scan. Each entry is the
// keyword to look for after a leading "Defaults" token.
const REQUIRED_DEFAULTS = new Set([
  "timestamp_timeout",
  "use_pty",
  "env_reset",
  "log_subcmds",
  "logfile",
  "passwd_tries",
]);

// Filesystem invariants — table-driven so adding a new file is one row.
// Each entry: {
//   path: absolute path (HOME-relative paths resolved at scan time),
//   kind: "file" | "dir" | "ssh-private-keys",
//   maxMode: octal mode (string) — file/dir mode bits must be <= this value
//             when masked with 0o777 (we ignore sticky/setuid/setgid bits),
//   exactMode: optional — if set, mode must equal exactly,
//   ownerMustBe: optional — uid that must own the file (root = 0),
//   missingOk: if true, missing file is not a violation,
// }
function fsInvariants() {
  return [
    {
      label: "age identity key",
      target: path.join(HOME_DIR, ".age-identity/keys.txt"),
      kind: "file",
      exactMode: 0o600,
      missingOk: false,
      ruleId: "fs-age-key-mode",
      ruleDesc: "~/.age-identity/keys.txt must be mode 600",
      remediationFile: "T0-1",
    },
    {
      label: "age identity directory",
      target: path.join(HOME_DIR, ".age-identity"),
      kind: "dir",
      exactMode: 0o700,
      missingOk: false,
      ruleId: "fs-age-dir-mode",
      ruleDesc: "~/.age-identity directory must be mode 700",
      remediationFile: "T0-1",
    },
    {
      label: "revealui passage store",
      target: path.join(HOME_DIR, ".revealui/passage-store"),
      kind: "dir",
      maxMode: 0o700,
      missingOk: true, // not all dev environments have revvault initialized
      ruleId: "fs-passage-store-mode",
      ruleDesc: "~/.revealui/passage-store directory must be mode 700 or stricter",
      remediationFile: "T0-1",
    },
    {
      label: "ssh private keys",
      target: path.join(HOME_DIR, ".ssh"),
      kind: "ssh-private-keys",
      exactMode: 0o600,
      missingOk: true,
      ruleId: "fs-ssh-private-key-mode",
      ruleDesc: "~/.ssh/id_* private keys must be mode 600",
      remediationFile: "T0-1",
    },
    {
      label: "sudo audit log",
      target: SUDOLOG,
      kind: "file",
      exactMode: 0o600,
      ownerMustBe: 0,
      missingOk: true, // doesn't exist until 00-defaults is applied + first sudo runs
      ruleId: "fs-sudolog-mode-owner",
      ruleDesc: "/var/log/sudo.log must be mode 600 owned by root",
      remediationFile: "T0-2",
    },
  ];
}

// ============================================================================
// Helpers — pure, no side effects beyond fs.statSync / fs.readFileSync
// ============================================================================

/**
 * Strip a trailing comment from a sudoers line, respecting the rule that
 * `#` starts a comment unless preceded by `\` (sudoers escape). Returns
 * the code portion only.
 */
function stripTrailingComment(line) {
  let out = "";
  let inQuote = false; // inside a double-quoted span
  let escaped = false; // previous char was an unescaped backslash
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (escaped) {
      out += ch;
      escaped = false;
      continue;
    }
    if (ch === "\\") {
      out += ch;
      escaped = true;
      continue;
    }
    if (ch === '"') {
      inQuote = !inQuote;
      out += ch;
      continue;
    }
    if (ch === "#" && !inQuote) break;
    out += ch;
  }
  return out;
}

/**
 * Tokenize a sudoers line by whitespace, after stripping trailing comments.
 * Returns an array of non-empty tokens.
 */
function tokenize(line) {
  const code = stripTrailingComment(line);
  const tokens = [];
  let buf = "";
  for (let i = 0; i < code.length; i++) {
    const ch = code[i];
    if (ch === " " || ch === "\t") {
      if (buf.length > 0) {
        tokens.push(buf);
        buf = "";
      }
      continue;
    }
    buf += ch;
  }
  if (buf.length > 0) tokens.push(buf);
  return tokens;
}

/**
 * Check whether the joined-arg portion of a NOPASSWD entry contains any
 * glob/wildcard char. Iterates char-by-char so we don't need regex.
 */
function containsGlob(s) {
  for (let i = 0; i < s.length; i++) {
    if (GLOB_CHARS.has(s[i])) return true;
  }
  return false;
}

/**
 * Parse the leading tag chain + command spec of a tokenized sudoers entry.
 *
 * A Cmnd_Spec is `[Tag_Spec ...] Cmnd`. Tags are colon-terminated and may be
 * glued (NOEXEC:NOPASSWD:), split across whitespace (NOEXEC: NOPASSWD:), have
 * the command glued on (NOPASSWD:/bin/su), or carry the colon as its own token
 * (NOPASSWD :ALL). We walk the chain splitting on ':' and whitespace, strip
 * every leading element that is a known sudoers tag, and the command begins at
 * the first non-tag element.
 *
 * Returns { found, cmdSpec }: `found` is true iff NOPASSWD appears anywhere in
 * the leading tag chain; `cmdSpec` is the command(s)+args after the chain,
 * joined with single spaces. No regex — char scan + Set.
 */
function parseNopasswdEntry(tokens) {
  // Start of the tag chain: first token whose first colon-segment is a known
  // tag. user / host=(runas) tokens never colon-split to a tag
  // (e.g. "ALL=(ALL:ALL)" -> "ALL=(ALL").
  let tagStart = -1;
  for (let i = 0; i < tokens.length; i++) {
    if (SUDO_TAGS.has(tokens[i].split(":")[0])) {
      tagStart = i;
      break;
    }
  }
  if (tagStart < 0) return { found: false, cmdSpec: "" };
  const rest = tokens.slice(tagStart).join(" ");
  const tags = [];
  let i = 0;
  while (i < rest.length) {
    // Skip separators between tags: whitespace and the colons that join/end them.
    while (
      i < rest.length &&
      (rest[i] === " " || rest[i] === "\t" || rest[i] === ":")
    ) {
      i++;
    }
    // Read a word up to the next colon or whitespace.
    let j = i;
    while (
      j < rest.length &&
      rest[j] !== ":" &&
      rest[j] !== " " &&
      rest[j] !== "\t"
    ) {
      j++;
    }
    const word = rest.slice(i, j);
    if (word.length === 0) break;
    if (!SUDO_TAGS.has(word)) break; // command starts here
    // A known-tag word is only a tag if colon-terminated (after optional ws).
    let k = j;
    while (k < rest.length && (rest[k] === " " || rest[k] === "\t")) k++;
    if (rest[k] !== ":") break;
    tags.push(word);
    i = k + 1; // consume the terminating colon
  }
  const cmdSpec = rest.slice(i).trim();
  let found = false;
  for (const tag of tags) {
    if (tag === "NOPASSWD") {
      found = true;
      break;
    }
  }
  return { found, cmdSpec };
}

/**
 * Test whether a path string starts with any of SYSTEM_BINARY_PREFIXES.
 */
function isSystemBinaryPath(p) {
  for (const prefix of SYSTEM_BINARY_PREFIXES) {
    if (p.startsWith(prefix)) return true;
  }
  return false;
}

/**
 * Check the line range [start, end] (inclusive) of file lines for a comment
 * that starts with `# justification:`. Returns true if found.
 */
function hasJustificationCommentIn(lines, startInclusive, endInclusive) {
  const lo = Math.max(0, startInclusive);
  const hi = Math.min(lines.length - 1, endInclusive);
  for (let i = lo; i <= hi; i++) {
    const trimmed = lines[i].trim();
    if (trimmed.startsWith("# justification:")) return true;
  }
  return false;
}

// ============================================================================
// Sudoers scan
// ============================================================================

/**
 * Scan all readable files in SUDOERS_DIR. Returns { findings, eaccesFiles }.
 *
 * findings: array of { class, where, ruleDesc, remediationFile }
 * eaccesFiles: array of file paths that couldn't be read (permission denied);
 *              the hook surfaces this as a separate warning so the user knows
 *              the scan was partial.
 */
function scanSudoersDir() {
  const findings = [];
  const eaccesFiles = [];

  let entries;
  try {
    entries = fs.readdirSync(SUDOERS_DIR);
  } catch (err) {
    if (err && err.code === "ENOENT") {
      // No sudoers.d at all is a violation of the 00-defaults requirement.
      findings.push({
        class: "SUDOERS",
        where: `${SUDOERS_DIR}/`,
        ruleDesc:
          `${SUDOERS_DIR} does not exist — required 00-defaults block cannot be present`,
        remediationFile: "T0-2",
      });
      return { findings, eaccesFiles };
    }
    if (err && err.code === "EACCES") {
      eaccesFiles.push(SUDOERS_DIR);
      return { findings, eaccesFiles };
    }
    throw err;
  }

  let sawDefaultsFile = false;
  let defaultsHasAllRequired = false;
  let defaultsMissingKeywords = [];
  let defaultsNegatedKeywords = [];

  for (const entry of entries) {
    // Skip backup files matching sudoers conventions (vim ~, dpkg .bak, etc.)
    // — sudo itself ignores files containing `.` or ending in `~`.
    if (entry.endsWith("~")) continue;
    if (entry.includes(".")) continue;

    const full = path.join(SUDOERS_DIR, entry);

    // Open once and read through that single file descriptor so the file we
    // fstat-check is provably the file we read. There is no TOCTOU re-resolution
    // of `full` between the check and the read (fixes CodeQL js/file-system-race).
    let fd;
    try {
      fd = fs.openSync(full, "r");
    } catch (err) {
      if (err && err.code === "EACCES") {
        eaccesFiles.push(full);
        continue;
      }
      continue;
    }

    let content;
    try {
      const st = fs.fstatSync(fd);
      if (!st.isFile()) continue;
      content = fs.readFileSync(fd, "utf8");
    } catch (err) {
      if (err && err.code === "EACCES") {
        eaccesFiles.push(full);
        continue;
      }
      continue;
    } finally {
      fs.closeSync(fd);
    }

    const lines = content.split("\n");

    if (entry === "00-defaults") {
      sawDefaultsFile = true;
      const seenKeywords = new Set();
      const negatedRequired = new Set();
      for (const line of lines) {
        const code = stripTrailingComment(line).trim();
        if (!code.startsWith("Defaults")) continue;
        // tokens[0] is "Defaults" (a binding suffix like Defaults:user /
        // Defaults!cmd / Defaults@host / Defaults>runas is glued on with no
        // space, so the SETTING is tokens[1]). Only the leading setting NAME
        // counts; names inside a value list (env_keep += "use_pty") live in
        // later tokens and must NOT satisfy a requirement.
        const tokens = tokenize(code);
        if (tokens.length < 2) continue;
        let setting = tokens[1];
        // A negated setting (!name) actively disables it — never satisfaction.
        let negated = false;
        if (setting.startsWith("!")) {
          negated = true;
          setting = setting.slice(1);
        }
        // Strip a glued operator + value: name / name=v / name+=v / name-=v.
        // Check += and -= before = (both contain '=').
        const plusIdx = setting.indexOf("+=");
        const minusIdx = setting.indexOf("-=");
        const eqIdx = setting.indexOf("=");
        let cut = -1;
        if (plusIdx >= 0) cut = plusIdx;
        else if (minusIdx >= 0) cut = minusIdx;
        else if (eqIdx >= 0) cut = eqIdx;
        const name = cut >= 0 ? setting.slice(0, cut) : setting;
        if (!REQUIRED_DEFAULTS.has(name)) continue;
        if (negated) negatedRequired.add(name);
        else seenKeywords.add(name);
      }
      const missing = [];
      for (const k of REQUIRED_DEFAULTS) {
        if (negatedRequired.has(k)) continue; // reported separately as negated
        if (!seenKeywords.has(k)) missing.push(k);
      }
      defaultsHasAllRequired =
        missing.length === 0 && negatedRequired.size === 0;
      defaultsMissingKeywords = missing;
      defaultsNegatedKeywords = Array.from(negatedRequired);
    }

    // Scan every line for NOPASSWD entries.
    for (let i = 0; i < lines.length; i++) {
      const raw = lines[i];
      const code = stripTrailingComment(raw).trim();
      if (code.length === 0) continue;

      const tokens = tokenize(raw);
      const np = parseNopasswdEntry(tokens);
      if (!np.found) continue;

      const lineNum = i + 1; // human-readable

      // Rule: forbid NOPASSWD: ALL in any form.
      // Check the cmd spec for the literal token "ALL".
      const cmdSpec = np.cmdSpec;
      const cmdTokens = cmdSpec.split(",").map((s) => s.trim()).filter(Boolean);

      for (const cmd of cmdTokens) {
        const head = cmd.split(" ")[0];

        if (head === "ALL") {
          findings.push({
            class: "SUDOERS",
            where: `${full}:${lineNum}`,
            ruleDesc: "NOPASSWD: ALL is forbidden in any form (T0-2 hardline)",
            remediationFile: "T0-2",
          });
          continue;
        }

        // Rule: forbid NOPASSWD to /usr/bin/*, /bin/*, /usr/sbin/*, /sbin/*.
        if (isSystemBinaryPath(head)) {
          findings.push({
            class: "SUDOERS",
            where: `${full}:${lineNum}`,
            ruleDesc:
              `NOPASSWD to system-binary path ${head} is forbidden (T0-3 hardline)`,
            remediationFile: "T0-3",
          });
        }

        // Rule: forbid glob/wildcard chars (*, ?, [, ]) in args.
        if (containsGlob(cmd)) {
          findings.push({
            class: "SUDOERS",
            where: `${full}:${lineNum}`,
            ruleDesc:
              `NOPASSWD entry contains glob/wildcard char (one of * ? [ ]) in "${cmd}" — only literal args allowed`,
            remediationFile: "T0-3",
          });
        }

        // Rule: NOPASSWD to /usr/local/bin/<script> must pin EXACTLY ONE
        // literal arg (T0-3 one-script-one-literal-arg hardline). Zero args
        // OR two-or-more args both violate.
        if (head.startsWith("/usr/local/bin/")) {
          const argsAfter = cmd.slice(head.length).trim();
          const argTokens =
            argsAfter.length === 0 ? [] : argsAfter.split(" ").filter(Boolean);
          if (argTokens.length !== 1) {
            findings.push({
              class: "SUDOERS",
              where: `${full}:${lineNum}`,
              ruleDesc:
                argTokens.length === 0
                  ? `NOPASSWD to ${head} without a pinned literal arg — every NOPASSWD must be one-script-one-literal-arg (exactly one literal arg required)`
                  : `NOPASSWD to ${head} pins ${argTokens.length} args — every NOPASSWD must be one-script-one-literal-arg (exactly one literal arg required)`,
              remediationFile: "T0-3",
            });
          }
        }
      }

      // Rule: every NOPASSWD entry needs a `# justification:` comment within
      // the 5 lines preceding the entry.
      if (!hasJustificationCommentIn(lines, i - 5, i - 1)) {
        findings.push({
          class: "SUDOERS",
          where: `${full}:${lineNum}`,
          ruleDesc:
            "NOPASSWD entry has no `# justification: <reason>` comment in the 5 preceding lines",
          remediationFile: "T0-3",
        });
      }
    }
  }

  // Rule: 00-defaults must exist with the required Defaults block.
  if (!sawDefaultsFile) {
    findings.push({
      class: "SUDOERS",
      where: `${SUDOERS_DIR}/00-defaults`,
      ruleDesc:
        `Required file ${SUDOERS_DIR}/00-defaults is missing — must contain Defaults block with: ${Array.from(REQUIRED_DEFAULTS).join(", ")}`,
      remediationFile: "T0-2",
    });
  } else if (!defaultsHasAllRequired) {
    if (defaultsMissingKeywords.length > 0) {
      findings.push({
        class: "SUDOERS",
        where: `${SUDOERS_DIR}/00-defaults`,
        ruleDesc:
          `Required Defaults missing from 00-defaults: ${defaultsMissingKeywords.join(", ")}`,
        remediationFile: "T0-2",
      });
    }
    if (defaultsNegatedKeywords.length > 0) {
      findings.push({
        class: "SUDOERS",
        where: `${SUDOERS_DIR}/00-defaults`,
        ruleDesc:
          `Required Defaults explicitly negated (disabled) in 00-defaults: ${defaultsNegatedKeywords.map((k) => "!" + k).join(", ")}`,
        remediationFile: "T0-2",
      });
    }
  }

  return { findings, eaccesFiles };
}

// ============================================================================
// Filesystem scan
// ============================================================================

function scanFilesystem() {
  const findings = [];
  const eaccesFiles = [];

  for (const inv of fsInvariants()) {
    let stat;
    try {
      stat = fs.lstatSync(inv.target);
    } catch (err) {
      if (err && err.code === "ENOENT") {
        if (!inv.missingOk) {
          findings.push({
            class: "FILESYSTEM",
            where: inv.target,
            ruleDesc: `${inv.ruleDesc} — file does not exist`,
            remediationFile: inv.remediationFile,
          });
        }
        continue;
      }
      if (err && err.code === "EACCES") {
        eaccesFiles.push(inv.target);
        continue;
      }
      continue;
    }

    if (inv.kind === "file") {
      if (!stat.isFile()) {
        findings.push({
          class: "FILESYSTEM",
          where: inv.target,
          ruleDesc: `${inv.ruleDesc} — exists but is not a regular file`,
          remediationFile: inv.remediationFile,
        });
        continue;
      }
      const mode = stat.mode & 0o777;
      if (inv.exactMode !== undefined && mode !== inv.exactMode) {
        findings.push({
          class: "FILESYSTEM",
          where: inv.target,
          ruleDesc: `${inv.ruleDesc} — currently mode ${mode.toString(8).padStart(3, "0")}`,
          remediationFile: inv.remediationFile,
        });
      } else if (inv.maxMode !== undefined && mode > inv.maxMode) {
        findings.push({
          class: "FILESYSTEM",
          where: inv.target,
          ruleDesc: `${inv.ruleDesc} — currently mode ${mode.toString(8).padStart(3, "0")}`,
          remediationFile: inv.remediationFile,
        });
      }
      if (inv.ownerMustBe !== undefined && stat.uid !== inv.ownerMustBe) {
        findings.push({
          class: "FILESYSTEM",
          where: inv.target,
          ruleDesc: `${inv.ruleDesc} — currently owned by uid ${stat.uid}, required uid ${inv.ownerMustBe}`,
          remediationFile: inv.remediationFile,
        });
      }
    } else if (inv.kind === "dir") {
      if (!stat.isDirectory()) {
        findings.push({
          class: "FILESYSTEM",
          where: inv.target,
          ruleDesc: `${inv.ruleDesc} — exists but is not a directory`,
          remediationFile: inv.remediationFile,
        });
        continue;
      }
      const mode = stat.mode & 0o777;
      if (inv.exactMode !== undefined && mode !== inv.exactMode) {
        findings.push({
          class: "FILESYSTEM",
          where: inv.target,
          ruleDesc: `${inv.ruleDesc} — currently mode ${mode.toString(8).padStart(3, "0")}`,
          remediationFile: inv.remediationFile,
        });
      } else if (inv.maxMode !== undefined && mode > inv.maxMode) {
        findings.push({
          class: "FILESYSTEM",
          where: inv.target,
          ruleDesc: `${inv.ruleDesc} — currently mode ${mode.toString(8).padStart(3, "0")}`,
          remediationFile: inv.remediationFile,
        });
      }
    } else if (inv.kind === "ssh-private-keys") {
      if (!stat.isDirectory()) continue;
      let dirEntries;
      try {
        dirEntries = fs.readdirSync(inv.target);
      } catch (err) {
        if (err && err.code === "EACCES") {
          eaccesFiles.push(inv.target);
          continue;
        }
        continue;
      }
      for (const name of dirEntries) {
        // SSH private keys: ~/.ssh/id_* that do NOT end in `.pub`.
        if (!name.startsWith("id_")) continue;
        if (name.endsWith(".pub")) continue;
        const keyPath = path.join(inv.target, name);
        let keyStat;
        try {
          keyStat = fs.lstatSync(keyPath);
        } catch {
          continue;
        }
        if (!keyStat.isFile()) continue;
        const mode = keyStat.mode & 0o777;
        if (mode !== inv.exactMode) {
          findings.push({
            class: "FILESYSTEM",
            where: keyPath,
            ruleDesc: `~/.ssh/${name} (private SSH key) must be mode 600 — currently ${mode.toString(8).padStart(3, "0")}`,
            remediationFile: inv.remediationFile,
          });
        }
      }
    }
  }

  return { findings, eaccesFiles };
}

// ============================================================================
// Output
// ============================================================================

function writeFinding(f) {
  process.stderr.write(
    `[M-4] ${f.class} VIOLATION: ${f.where} — ${f.ruleDesc}.\n` +
      `  Remediation: ${REMEDIATION_LANE} ${f.remediationFile}\n`
  );
}

function writePartialReadNotice(eaccesFiles) {
  if (eaccesFiles.length === 0) return;
  process.stderr.write(
    `[M-4] PARTIAL SCAN: ${eaccesFiles.length} path(s) unreadable (EACCES) — scan was incomplete:\n`
  );
  for (const p of eaccesFiles) {
    process.stderr.write(`  ${p}\n`);
  }
  process.stderr.write(
    `  Re-run with sudo (or after running ${REMEDIATION_LANE} T0-2 to apply the 10-min sudo cache) for full coverage.\n`
  );
}

// ============================================================================
// Main
// ============================================================================

function main() {
  let sudoersResult;
  let fsResult;
  try {
    sudoersResult = scanSudoersDir();
    fsResult = scanFilesystem();
  } catch (err) {
    process.stderr.write(
      `[M-4] INTERNAL ERROR: ${err && err.message ? err.message : String(err)}\n`
    );
    process.exit(1);
  }

  const allFindings = sudoersResult.findings.concat(fsResult.findings);
  const allEacces = sudoersResult.eaccesFiles.concat(fsResult.eaccesFiles);

  for (const f of allFindings) writeFinding(f);
  writePartialReadNotice(allEacces);

  if (allFindings.length > 0) {
    process.stderr.write(
      `[M-4] ${allFindings.length} violation(s) found. See ${REMEDIATION_LANE} for remediation steps.\n`
    );
    process.exit(2);
  }

  // Clean: silent unless --verbose was passed (kept for manual smoke runs).
  if (process.argv.includes("--verbose")) {
    process.stdout.write(
      `[M-4] OK — sudoers + filesystem invariants satisfied (${sudoersResult.findings.length + fsResult.findings.length} findings; ${allEacces.length} unreadable paths).\n`
    );
  }
  process.exit(0);
}

main();

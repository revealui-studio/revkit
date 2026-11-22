"use strict";

// Native SessionStart helper.
// Policy lives in .revealui/content. The workboard, when a repo uses one,
// is .revealui/workboard.md. This helper runs the native M-4 scanner.
// It does not continue a previous session and it does not read a vendor home.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const scanner = path.join(
  os.homedir(),
  ".revealui",
  "hooks",
  "m4-sudoers-fs-scanner.js"
);

if (!fs.existsSync(scanner)) {
  process.exit(0);
}

const result = spawnSync(process.execPath, [scanner], { stdio: "inherit" });
if (result.error) {
  process.stderr.write("session-start: " + result.error.message + "\n");
  process.exit(1);
}
process.exit(result.status === null ? 1 : result.status);

#!/usr/bin/env python3
"""Explicit, narrow runtime-home projection into an existing Codex config."""

import argparse
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import sys
import tomllib

from codex_adapter_lib import Refused, atomic_write, encode, is_link, parsed_path, private_directory, require, toml_edit


COMMON = {"COREPACK_HOME", "PNPM_HOME", "CARGO_HOME", "RUSTUP_HOME", "HF_HOME", "GH_CONFIG_DIR"}
ALLOWED = {"windows": COMMON | {"NVM_HOME"}, "linux": COMMON | {"NVM_DIR"},
           "macos": COMMON | {"NVM_DIR"}}


def matches(pattern, name):
    return fnmatch.fnmatchcase(name.casefold(), pattern.casefold())


def render(text, values, platform):
    require(platform in ALLOWED, "unsupported platform")
    require(isinstance(values, dict) and values, "provide explicit runtime-home values")
    require(set(values) <= ALLOWED[platform], "unapproved environment variable name")
    config = tomllib.loads(text)
    policy = config.get("shell_environment_policy", {})
    require(policy.get("inherit", "core") == "core", "existing inheritance must be core")
    require(not ("filters" in policy and ("exclude" in policy or "include_only" in policy)),
            "configuration mixes canonical and legacy filters")
    filters = policy.get("filters", {})
    require(isinstance(filters, dict), "unsupported environment filters")
    require(all(isinstance(k, str) and v in {"include", "exclude"} for k, v in filters.items()),
            "unsupported environment filter value")
    includes = [k for k, v in filters.items() if v == "include"]
    excludes = [k for k, v in filters.items() if v == "exclude"]
    includes.extend(policy.get("include_only", []))
    excludes.extend(policy.get("exclude", []))
    edits = {}
    existing = policy.get("set", {})
    require(isinstance(existing, dict), "unsupported environment assignment map")
    existing_case = {key.casefold(): key for key in existing}
    if platform == "windows":
        require(len(existing_case) == len(existing), "ambiguous case-insensitive environment assignments")
    if "inherit" not in policy:
        edits[("shell_environment_policy", "inherit")] = "core"
    for name, value in values.items():
        require(isinstance(value, str) and value, "runtime home must be a nonempty path")
        parsed_path(value, "windows" if platform == "windows" else "posix")
        if platform != "windows":
            parts = Path(value).parts
            require(not (len(parts) > 2 and parts[1] == "mnt" and len(parts[2]) == 1),
                    "native runtime homes cannot use mounted Windows volumes")
        require(not any(matches(pattern, name) for pattern in excludes),
                "an owner exclusion conflicts with a requested runtime home")
        require(not includes or any(matches(pattern, name) for pattern in includes),
                "an owner include filter would remove a requested runtime home")
        key = existing_case.get(name.casefold(), name) if platform == "windows" else name
        edits[("shell_environment_policy", "set", key)] = value
    return toml_edit(text, edits)


def configure(path, values, platform, apply=False):
    path = Path(path)
    require(path.is_file() and not is_link(path), "config must be an existing regular file")
    before_bytes = path.read_bytes()
    before = before_bytes.decode("utf-8")
    after = render(before, values, platform)
    result = {"status": "unchanged" if before == after else "prepared", "platform": platform,
              "variables": sorted(values), "inherit": "core", "applied": False}
    if apply and before != after:
        digest = hashlib.sha256(before_bytes).hexdigest()
        if os.name == "nt":
            backup_root = path.parent / ".revkit-config-backups"
            private_directory(backup_root, create=not backup_root.exists())
        else:
            backup_root = path.parent
        backup = backup_root / (path.name + ".revkit-before-" + digest[:16])
        if backup.exists():
            require(not is_link(backup) and backup.read_bytes() == before_bytes, "config backup collision")
        else:
            if os.name == "nt":
                private_directory(backup_root)
            descriptor = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(before_bytes)
                stream.flush()
                os.fsync(stream.fileno())
        require(path.read_bytes() == before_bytes, "config changed during preparation")
        atomic_write(path, after)
        result.update(status="applied", applied=True, before_sha256=digest,
                      after_sha256=hashlib.sha256(after.encode()).hexdigest())
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["plan", "apply"])
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--platform", choices=sorted(ALLOWED), required=True)
    choice = parser.add_mutually_exclusive_group(required=True)
    choice.add_argument("--values-file", type=Path)
    choice.add_argument("--from-environment", action="store_true")
    args = parser.parse_args()
    try:
        values = (json.loads(args.values_file.read_text(encoding="utf-8-sig"))
                  if args.values_file else {k: os.environ[k] for k in ALLOWED[args.platform]
                                            if k in os.environ})
        result = configure(args.config, values, args.platform, args.action == "apply")
        print(encode(result), end="")
        return 0
    except (Refused, OSError, ValueError, TypeError):
        print(encode({"status": "refused", "reason": "configuration or runtime-home inputs failed validation"}), end="")
        return 1


if __name__ == "__main__":
    sys.exit(main())

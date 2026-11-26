#!/usr/bin/env python3
"""Explicit, narrow runtime-home projection into an existing Codex config."""

import argparse
import fnmatch
import hashlib
import json
import os
import socket
import stat
from pathlib import Path
import sys
import tomllib

from codex_adapter_lib import Refused, TOML_DELETE, atomic_write, encode, is_link, parsed_path, private_directory, require, toml_edit


COMMON = {"COREPACK_HOME", "PNPM_HOME", "CARGO_HOME", "RUSTUP_HOME", "HF_HOME", "GH_CONFIG_DIR"}
ALLOWED = {"windows": COMMON | {"NVM_HOME"}, "linux": COMMON | {"NVM_DIR"},
           "macos": COMMON | {"NVM_DIR"}}
REVIEWED_BASH_ENV = "~/.config/shell/env.sh"
STARTUP_FIELD = ("shell_environment_policy", "set", "BASH_ENV")
SESSION_FIELDS = {"XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"}


def matches(pattern, name):
    return fnmatch.fnmatchcase(name.casefold(), pattern.casefold())


def environment_filters(policy):
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
    return includes, excludes


def render(text, values, platform):
    require(platform in ALLOWED, "unsupported platform")
    require(isinstance(values, dict) and values, "provide explicit runtime-home values")
    require(set(values) <= ALLOWED[platform], "unapproved environment variable name")
    config = tomllib.loads(text)
    policy = config.get("shell_environment_policy", {})
    require(policy.get("inherit", "core") == "core", "existing inheritance must be core")
    includes, excludes = environment_filters(policy)
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


def persist_config(path, before_bytes, after, apply=False):
    path = Path(path)
    before = before_bytes.decode("utf-8")
    result = {"status": "unchanged" if before == after else "prepared", "applied": False}
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


def configure(path, values, platform, apply=False):
    path = Path(path)
    require(path.is_file() and not is_link(path), "config must be an existing regular file")
    before_bytes = path.read_bytes()
    after = render(before_bytes.decode("utf-8"), values, platform)
    return persist_config(path, before_bytes, after, apply) | {
        "platform": platform, "variables": sorted(values), "inherit": "core"}


def render_reviewed_startup_retirement(text, expected_value):
    require(expected_value == REVIEWED_BASH_ENV, "startup value has not been reviewed for retirement")
    config = tomllib.loads(text)
    policy = config.get("shell_environment_policy", {})
    require(isinstance(policy, dict) and policy.get("inherit") == "core",
            "reviewed retirement requires explicit core inheritance")
    values = policy.get("set", {})
    require(isinstance(values, dict), "unsupported environment assignment map")
    require(not any(key.casefold() == "bash_env" and key != "BASH_ENV" for key in values),
            "ambiguous startup entry requires separate review")
    require(not any(key.casefold() in {"env", "node_options"} for key in values),
            "other startup overrides require separate review")
    environment_filters(policy)
    require("exclude" not in policy and "include_only" not in policy,
            "reviewed startup retirement requires canonical filters; legacy filters need separate review")
    filters = policy.get("filters", {})
    matching = [name for name in filters if name.casefold() == "bash_env"]
    require(len(matching) <= 1, "ambiguous startup filters require separate review")
    key = matching[0] if matching else "BASH_ENV"
    require(key not in filters or filters[key] == "exclude",
            "an owner startup include filter requires separate review")
    edits = {}
    if "BASH_ENV" in values:
        require(values["BASH_ENV"] == expected_value, "configured startup value differs from the reviewed value")
        edits[STARTUP_FIELD] = TOML_DELETE
    if key not in filters:
        edits[("shell_environment_policy", "filters", key)] = "exclude"
    return toml_edit(text, edits) if edits else text


def reviewed_native_user_config(path, platform):
    require(platform == "linux" and sys.platform.startswith("linux"),
            "reviewed shell actions apply only to the native Linux user config")
    path = Path(path).expanduser().absolute()
    expected_path = (Path.home() / ".codex" / "config.toml").absolute()
    require(path == expected_path, "reviewed shell action requires the native user config location")
    require(path.is_file() and not is_link(path) and not is_link(path.parent),
            "reviewed config must be an existing regular file in its canonical directory")
    info = path.stat()
    require(info.st_uid == os.getuid() and info.st_gid == os.getegid()
            and path.parent.stat().st_gid == os.getegid(),
            "reviewed config ownership cannot be preserved by this user")
    require(not os.listxattr(path), "additional config metadata requires separate preservation review")
    before_bytes = path.read_bytes()
    return path, before_bytes


def retire_reviewed_startup(path, expected_value, platform, apply=False, reviewed_sha256=None):
    path, before_bytes = reviewed_native_user_config(path, platform)
    before_hash = hashlib.sha256(before_bytes).hexdigest()
    require(not apply or reviewed_sha256 == before_hash,
            "apply requires the matching SHA256 from the reviewed retirement dry run")
    after = render_reviewed_startup_retirement(before_bytes.decode("utf-8"), expected_value)
    if after.encode() != before_bytes:
        binding = native_session_binding()
        policy = tomllib.loads(before_bytes.decode("utf-8"))["shell_environment_policy"]
        require_session_admission(policy, binding)
        require(all(policy.get("set", {}).get(name) == value for name, value in binding.items()),
                "project the verified native session before retiring the startup entry")
    return persist_config(path, before_bytes, after, apply) | {
        "action": "retire-reviewed-startup", "platform": "linux", "inherit": "core",
        "policy_basis": "explicit-reviewed-retirement", "field": "/".join(STARTUP_FIELD),
        "expected_value": REVIEWED_BASH_ENV, "before_sha256": before_hash,
        "after_sha256": hashlib.sha256(after.encode()).hexdigest(),
        "changes": ["BASH_ENV"] if after.encode() != before_bytes else []}


def verify_native_session(runtime, uid):
    runtime = Path(runtime)
    require(runtime.is_dir() and not is_link(runtime), "native runtime directory is missing or linked")
    info = runtime.stat()
    require(info.st_uid == uid and stat.S_IMODE(info.st_mode) == 0o700,
            "native runtime directory must be owned by the current UID with mode 0700")
    bus = runtime / "bus"
    require(not is_link(bus), "native user bus socket cannot be linked")
    info = bus.stat()
    require(stat.S_ISSOCK(info.st_mode) and info.st_uid == uid,
            "native user bus must be a socket owned by the current UID")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
        probe.settimeout(1.0)
        try:
            probe.connect(str(bus))
        except OSError:
            raise Refused("native user bus socket has no live listener") from None
    return {"XDG_RUNTIME_DIR": str(runtime), "DBUS_SESSION_BUS_ADDRESS": "unix:path=" + str(bus)}


def native_session_binding():
    require(sys.platform.startswith("linux"), "native session projection requires Linux")
    uid = os.getuid()
    return verify_native_session(Path("/run/user") / str(uid), uid)


def require_session_admission(policy, binding):
    includes, excludes = environment_filters(policy)
    for name in binding:
        require(not any(matches(pattern, name) for pattern in excludes),
                "an owner exclusion conflicts with native session projection")
        require(not includes or any(matches(pattern, name) for pattern in includes),
                "an owner include filter would remove a native session field")


def render_native_session_projection(text, binding):
    require(set(binding) == SESSION_FIELDS, "unexpected native session field")
    policy = tomllib.loads(text).get("shell_environment_policy", {})
    require(isinstance(policy, dict) and policy.get("inherit") == "core",
            "native session projection requires explicit core inheritance")
    require_session_admission(policy, binding)
    existing = policy.get("set", {})
    require(isinstance(existing, dict), "unsupported environment assignment map")
    edits = {}
    for name, value in binding.items():
        require(name not in existing or existing[name] == value,
                "an owner session entry conflicts with the verified native session")
        if name not in existing:
            edits[("shell_environment_policy", "set", name)] = value
    return toml_edit(text, edits) if edits else text


def project_native_session(path, platform, apply=False, reviewed_sha256=None):
    path, before_bytes = reviewed_native_user_config(path, platform)
    before_hash = hashlib.sha256(before_bytes).hexdigest()
    require(not apply or reviewed_sha256 == before_hash,
            "apply requires the matching SHA256 from the reviewed native-session dry run")
    binding = native_session_binding()
    after = render_native_session_projection(before_bytes.decode("utf-8"), binding)
    return persist_config(path, before_bytes, after, apply) | {
        "action": "project-native-session", "platform": "linux", "inherit": "core",
        "policy_basis": "verified-native-user-session", "values": binding,
        "before_sha256": before_hash, "after_sha256": hashlib.sha256(after.encode()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["plan", "apply", "retire-reviewed-startup", "project-native-session"])
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--platform", choices=sorted(ALLOWED), required=True)
    choice = parser.add_mutually_exclusive_group()
    choice.add_argument("--values-file", type=Path)
    choice.add_argument("--from-environment", action="store_true")
    parser.add_argument("--expected-value")
    parser.add_argument("--reviewed-sha256")
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if args.action in {"retire-reviewed-startup", "project-native-session"}:
        if args.values_file or args.from_environment:
            parser.error("reviewed shell actions do not accept runtime-home inputs")
        if (args.action == "retire-reviewed-startup") != (args.expected_value is not None):
            parser.error("--expected-value is required only for reviewed startup retirement")
        if args.reviewed_sha256 and not args.apply:
            parser.error("--reviewed-sha256 is used only with reviewed shell --apply")
    elif not (args.values_file or args.from_environment) or args.expected_value is not None or args.reviewed_sha256 or args.apply:
        parser.error("plan/apply require runtime-home inputs and do not accept reviewed shell flags")
    try:
        if args.action == "retire-reviewed-startup":
            result = retire_reviewed_startup(args.config, args.expected_value, args.platform,
                                            args.apply, args.reviewed_sha256)
            print(encode(result), end="")
            return 0
        if args.action == "project-native-session":
            result = project_native_session(args.config, args.platform, args.apply, args.reviewed_sha256)
            print(encode(result), end="")
            return 0
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

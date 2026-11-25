#!/usr/bin/env python3
"""Prepare an offline Codex-home copy; activation remains an operator action."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import tomllib
import uuid

from codex_adapter_lib import (Refused, contains_home, encode, is_link, path_flavor, private_directory,
                               parsed_path, rebase_storage, references, require, storage_relative, toml_edit)
from codex_adapter_lib import windows_access_batch, windows_access_inventory


PROFILE = json.loads(Path(__file__).with_name("codex-state-layout-v1.json").read_text())
RECEIPT = ".revkit-codex-migration.json"


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        while block := stream.read(8 * 1024 * 1024):
            result.update(block)
    return result.hexdigest()


def roots(source, target):
    source, target = Path(source).absolute(), Path(target).absolute()
    for path in [source, target.parent]:
        require(path.exists(), "source and destination parent must exist")
        for ancestor in [path, *path.parents]:
            require(not is_link(ancestor), "linked source or destination ancestry is unsupported")
    source, target = source.resolve(), target.parent.resolve() / target.name
    require(source.is_dir() and not target.exists() and not target.is_symlink(),
            "source must exist and target must not exist")
    require(source != target and source not in target.parents and target not in source.parents,
            "source and destination overlap")
    require((source / "state_5.sqlite").is_file(), "unsupported Codex-home layout")
    require(not (source / RECEIPT).exists(), "source is already a prepared migration")
    return source, target


def writers(source):
    source = Path(source).resolve()
    if os.name == "nt":
        command = r'''
$ErrorActionPreference = 'Stop'
$p = [Environment]::GetEnvironmentVariable('REVKIT_SOURCE_HOME')
$found = @(Get-CimInstance Win32_Process | Where-Object {
  $_.Name -in @('ChatGPT.exe', 'Codex.exe', 'codex.exe', 'codex-browser-client.exe', 'codex-browser-service.exe') -or
  ($_.ProcessId -ne [int][Environment]::GetEnvironmentVariable('REVKIT_MIGRATION_PID') -and
   $_.CommandLine -and $_.CommandLine.IndexOf($p, [StringComparison]::OrdinalIgnoreCase) -ge 0)
})
if ($found.Count -gt 0) { exit 2 }
'''
        env = {k: v for k, v in os.environ.items()
               if k.upper() in {"PATH", "SYSTEMROOT", "WINDIR", "COMSPEC", "TEMP", "TMP", "PROGRAMFILES"}}
        env.update(REVKIT_SOURCE_HOME=str(source), REVKIT_MIGRATION_PID=str(os.getpid()))
        result = subprocess.run(["pwsh.exe", "-NoProfile", "-NonInteractive", "-Command", command],
                                env=env, capture_output=True, timeout=30)
        require(result.returncode == 0, "active or uninspectable Windows writers prevent offline migration")
        return
    require(Path("/proc").is_dir(), "offline writer discovery is unsupported on this host")
    for process in Path("/proc").iterdir():
        if not process.name.isdecimal() or int(process.name) == os.getpid():
            continue
        command = ""
        try:
            command = (process / "comm").read_text().strip().casefold()
            if "codex" in command:
                values = (process / "environ").read_bytes().split(b"\0")
                env = dict(entry.split(b"=", 1) for entry in values if b"=" in entry)
                home = env.get(b"CODEX_HOME", env.get(b"HOME", b"") + b"/.codex")
                require(Path(os.fsdecode(home)).resolve() != source, "active Codex writer prevents migration")
            for fd in (process / "fd").iterdir():
                try:
                    opened = Path(os.readlink(fd))
                    require(not opened.is_absolute() or not (opened == source or source in opened.parents),
                            "an open source handle prevents offline migration")
                except (FileNotFoundError, PermissionError, OSError):
                    continue
        except (FileNotFoundError, ProcessLookupError):
            continue
        except PermissionError:
            require("codex" not in command, "a Codex process cannot be inspected")


def generated_link(parts):
    command_link = (len(parts) == 4 and parts[0] == "tmp" and parts[1] == "arg0-linux"
                    and parts[2].startswith("codex-arg0")
                    and parts[3] in {"applypatch", "apply_patch", "codex-linux-sandbox"})
    chrome_alias = tuple(parts) == ("plugins", "cache", "openai-bundled", "chrome", "latest")
    return "app-command-links" if command_link else "browser-plugin-cache" if chrome_alias else None


def inventory(root):
    root = Path(root)
    for ancestor in [root, *root.parents]:
        require(not is_link(ancestor), "linked inventory root ancestry is unsupported")
    root_info = root.stat()
    if os.name != "nt":
        require(root_info.st_uid == os.getuid() and root_info.st_gid == os.getegid(),
                "source root ownership cannot be preserved by this user")
    entries = {".": {"kind": "root", "mode": stat.S_IMODE(root_info.st_mode)}}
    if os.name != "nt":
        entries["."].update(uid=root_info.st_uid, gid=root_info.st_gid)
    def visit(directory):
        for path in sorted(directory.iterdir()):
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            if os.name != "nt":
                require(info.st_uid == os.getuid() and info.st_gid == os.getegid(),
                        "source ownership cannot be preserved by this user")
            if is_link(path):
                generated = generated_link(Path(relative).parts)
                if generated:
                    tag = getattr(info, "st_reparse_tag", None)
                    allowed = {None, 0} if os.name != "nt" else ({0xA000001D} if generated == "app-command-links" else {0xA0000003})
                    require(tag in allowed,
                            "unknown generated-link reparse tag")
                    entries[relative] = {"kind": "regenerate", "owner": generated,
                                         "tag": tag, "inode": info.st_ino, "modified_ns": info.st_mtime_ns}
                    if generated == "browser-plugin-cache":
                        raw_target = os.readlink(path)
                        target_path = Path(raw_target)
                        if not target_path.is_absolute():
                            target_path = path.parent / target_path
                        require(not is_link(target_path), "browser cache version target is another link")
                        resolved = target_path.resolve(strict=True)
                        require(os.path.samefile(resolved.parent, path.parent) and resolved.is_dir()
                                and not is_link(resolved) and resolved != path,
                                "browser cache alias does not identify an internal version directory")
                        flavor = path_flavor(str(root))
                        try:
                            target_relative = parsed_path(str(target_path), flavor).relative_to(parsed_path(str(root), flavor))
                        except ValueError:
                            raise Refused("browser cache target is outside the logical source home") from None
                        require(tuple(part.casefold() for part in target_relative.parts[:-1]) ==
                                ("plugins", "cache", "openai-bundled", "chrome"),
                                "browser cache target is outside its version directory")
                        entries[relative]["target_relative"] = "/".join(target_relative.parts)
                        entries[relative]["target_inode"] = resolved.stat().st_ino
                        entries[relative]["target_device"] = resolved.stat().st_dev
                    continue
                require(path.is_symlink(), "unsupported reparse point")
                link = os.readlink(path)
                require(not Path(link).is_absolute(), "absolute or external links require supported regeneration")
                resolved = path.resolve(strict=True)
                require(resolved == root or root in resolved.parents, "link escapes the source home")
                entries[relative] = {"kind": "link", "link": link}
            elif stat.S_ISDIR(info.st_mode):
                entries[relative] = {"kind": "directory", "mode": stat.S_IMODE(info.st_mode)}
                visit(path)
            else:
                require(stat.S_ISREG(info.st_mode), "unsupported special file in Codex home")
                entries[relative] = {"kind": "file", "size": info.st_size,
                                     "mode": stat.S_IMODE(info.st_mode), "sha256": digest(path)}
            if os.name != "nt":
                entries[relative].update(uid=info.st_uid, gid=info.st_gid)
    visit(root)
    if os.name == "nt":
        names = [name for name, value in entries.items() if value["kind"] in {"root", "file", "directory"}]
        metadata = windows_access_inventory([root / name for name in names])
        for name, access in zip(names, metadata):
            entries[name].update({"acl_effective_sha256": access["effective"],
                                  "acl_access_sha256": access["access"],
                                  "acl_owner_sha256": access["owner"],
                                  "acl_protected": access["protected"]})
    return entries


def copied_metadata(manifest):
    return {name: {key: value for key, value in entry.items()
                   if key not in {"acl_access_sha256", "acl_protected"}}
            for name, entry in manifest.items() if entry["kind"] not in {"root", "regenerate"}}


def copy_tree(source, target, manifest):
    access_tasks = []
    for relative, entry in manifest.items():
        source_path, target_path = source / relative, target / relative
        if entry["kind"] == "directory":
            target_path.mkdir(mode=0o700)
            os.chmod(target_path, entry["mode"])
        elif entry["kind"] == "link":
            target_path.symlink_to(entry["link"], target_is_directory=source_path.resolve().is_dir())
        elif entry["kind"] == "file":
            shutil.copy2(source_path, target_path)
            if os.name == "nt":
                access_tasks.append((target_path, source_path))
    if os.name == "nt":
        for relative, entry in reversed(list(manifest.items())):
            if entry["kind"] == "directory":
                access_tasks.append((target / relative, source / relative))
        windows_access_batch(access_tasks)


def schema(connection):
    rows = connection.execute("SELECT type,name,tbl_name,sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name").fetchall()
    return [[x.replace("\r\n", "\n") if isinstance(x, str) else x for x in row] for row in rows]


def validate_database(path):
    require(path.name.casefold() in PROFILE["databases"], "unknown database layout")
    expected = PROFILE["databases"][path.name.casefold()]
    connection = sqlite3.connect(path)
    try:
        require(connection.execute("PRAGMA integrity_check").fetchall() == [("ok",)], "SQLite integrity failed")
        require(not connection.execute("PRAGMA foreign_key_check").fetchall(), "SQLite foreign-key validation failed")
        require(connection.execute("PRAGMA user_version").fetchone()[0] == expected["user_version"],
                "unsupported database version")
        tables = {}
        for (name,) in connection.execute("SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'"):
            quoted = '"' + name.replace('"', '""') + '"'
            tables[name] = [[r[1], r[2], r[3], r[5]] for r in connection.execute("PRAGMA table_info(" + quoted + ")")]
        require(tables == expected["tables"], "unsupported database tables or columns")
        if "schema" in expected:
            require(schema(connection) == expected["schema"], "unsupported database schema objects")
            if "migrations" in expected:
                migrations = [[r[0], bytes(r[1]).hex(), int(r[2])] for r in connection.execute(
                    "SELECT version,checksum,success FROM _sqlx_migrations ORDER BY version")]
                require(migrations == expected["migrations"], "unsupported database migrations")
        else:
            require(all(row[0] == "table" for row in schema(connection)),
                    "unsupported auxiliary database schema objects")
    except BaseException:
        connection.close()
        raise
    return connection


def scalar_rows(connection, table):
    quoted = '"' + table.replace('"', '""') + '"'
    return connection.execute("SELECT * FROM " + quoted).fetchall()


def database_snapshot(connection):
    return {name: scalar_rows(connection, name) for (name,) in connection.execute(
        "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'")}


def classify_document(relative, text, old_home):
    name = Path(relative).name.casefold()
    if Path(relative).parts[0] in {"sessions", "archived_sessions"} or name in {"history.jsonl"}:
        return []
    try:
        value = tomllib.loads(text) if name.endswith(".toml") else json.loads(text)
    except (ValueError, TypeError):
        require(not contains_home(text, old_home), "unparseable current metadata contains a source-home reference")
        return []
    count = references(value, old_home)
    if not count:
        return []
    if name == "hooks.json":
        field, kind, action = "hooks.command", "requires-hook-review", "regenerate commands from reviewed copied code; retain approval records and review changed definitions through /hooks"
    elif name == "chrome-native-hosts-v2.json":
        field, kind, action = "browser.native-host-registration", "requires-supported-regeneration", "register the browser integration through the application for the new home"
    elif name == "config.toml":
        field, kind, action = "config.trust-and-package-references", "requires-supported-regeneration", "refresh plugins and trusted service configuration through supported application settings; approve hooks normally"
    elif name == ".codex-global-state.json":
        field, kind, action = "global.project-and-permission-state", "requires-consent", "reconcile projects and workspace permissions through supported application controls"
    else:
        field, kind, action = "unclassified-current-metadata", "requires-schema-review", "review this metadata schema before adding a maintained field adapter"
    return [{"field": field, "kind": kind, "count": count, "action": action}]


def inspect_copy(source_home, copied, target_home, transform):
    pending = []
    changes = []
    connections = []
    try:
        for path in sorted(copied.rglob("*")):
            if path.is_symlink() or not path.is_file():
                continue
            relative = path.relative_to(copied)
            if path.suffix.casefold() in {".db", ".sqlite", ".sqlite3"}:
                require(len(relative.parts) == 1, "nested database requires a supported schema profile")
                connection = validate_database(path)
                connections.append(connection)
                if path.name.casefold() == "state_5.sqlite":
                    before = database_snapshot(connection)
                    columns = [r[1] for r in connection.execute("PRAGMA table_info(threads)")]
                    id_index, path_index = columns.index("id"), columns.index("rollout_path")
                    for row in before["threads"]:
                        parts = storage_relative(row[path_index], source_home)
                        rollout = copied.joinpath(*parts)
                        require(rollout.is_file() and not is_link(rollout), "indexed rollout is missing or linked")
                        new_path = rebase_storage(row[path_index], source_home, target_home)
                        changes.append({"field": "threads.rollout_path", "count": 1})
                        if transform:
                            connection.execute("UPDATE threads SET rollout_path=? WHERE id=? AND rollout_path=?",
                                               (new_path, row[id_index], row[path_index]))
                        if references(json.loads(row[columns.index("sandbox_policy")]), source_home):
                            pending.append({"field": "threads.sandbox_policy", "kind": "requires-consent", "count": 1,
                                            "action": "review saved workspace permissions through supported application controls; preserve stored policy"})
                    after = database_snapshot(connection)
                    for table, rows in before.items():
                        if table == "threads":
                            normalize = lambda data: sorted(tuple(v for i, v in enumerate(r) if i != path_index) for r in data)
                            require(normalize(rows) == normalize(after[table]), "non-path thread state changed")
                        else:
                            require(rows == after[table], "unapproved database rows changed")
                    for row in before.get("rollout_migration_skipped_rollouts", []):
                        if references(list(row), source_home):
                            pending.append({"field": "rollout_migration_skipped_rollouts", "kind": "requires-review", "count": 1})
                    for table, field in [("project_roots", "path"), ("threads", "cwd"),
                                         ("threads", "agent_path"), ("thread_attachments", "payload")]:
                        names = [r[1] for r in connection.execute("PRAGMA table_info(" + table + ")")]
                        index = names.index(field)
                        count = sum(references(row[index], source_home) for row in before[table])
                        if count:
                            pending.append({"field": table + "." + field, "kind": "requires-supported-regeneration",
                                            "count": count, "action": "reconcile workspace or attachment ownership through supported application controls"})
                elif path.name.casefold() == ".codex-global-state.sqlite":
                    for scope, key, value in connection.execute("SELECT scope,key,value FROM settings"):
                        count = references(value, source_home) + int(contains_home(key, source_home))
                        if count:
                            pending.append({"field": "settings.structured-state", "kind": "requires-supported-regeneration", "count": count})
                connection.commit()
                require(connection.execute("PRAGMA integrity_check").fetchall() == [("ok",)], "copied SQLite integrity failed")
                require(not connection.execute("PRAGMA foreign_key_check").fetchall(), "copied SQLite reference validation failed")
            elif path.suffix.casefold() in {".json", ".toml"}:
                text = path.read_text(encoding="utf-8-sig")
                if relative.as_posix().casefold() == "config.toml":
                    document = tomllib.loads(text)
                    env = document.get("mcp_servers", {}).get("node_repl", {}).get("env", {})
                    if contains_home(env.get("CODEX_HOME"), source_home):
                        require(parsed_path(env["CODEX_HOME"]) == parsed_path(source_home),
                                "unsupported nested CODEX_HOME reference")
                        changed = toml_edit(text, {("mcp_servers", "node_repl", "env", "CODEX_HOME"): target_home})
                        changes.append({"field": "config.node_repl.CODEX_HOME", "count": 1})
                        if transform:
                            path.write_text(changed, encoding="utf-8", newline="")
                        text = changed
                pending.extend(classify_document(relative, text, source_home))
        return changes, pending
    finally:
        for connection in connections:
            connection.close()


def ensure_capacity(target, manifest):
    total = sum(v.get("size", 0) for v in manifest.values())
    sqlite_bytes = sum(v.get("size", 0) for k, v in manifest.items() if k.endswith(".sqlite"))
    required = total + sqlite_bytes + max(64 * 1024 * 1024, total // 20)
    require(shutil.disk_usage(target.parent).free >= required, "insufficient destination capacity")
    return required


def plan(source, target):
    source, target = roots(source, target)
    writers(source)
    manifest = inventory(source)
    required = ensure_capacity(target, manifest)
    with tempfile.TemporaryDirectory(prefix="revkit-codex-plan-") as name:
        scratch = Path(name) / "home"
        private_directory(scratch, create=True)
        for relative, entry in manifest.items():
            path = source / relative
            if entry["kind"] == "file" and (path.suffix.casefold() in {".sqlite", ".db", ".sqlite3", ".json", ".toml"}
                                              or path.name.casefold().endswith(("-wal", "-shm"))):
                if Path(relative).parts[0] in {"sessions", "archived_sessions"}:
                    continue
                dest = scratch / relative
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, dest)
        for relative, entry in manifest.items():
            if entry["kind"] == "file" and Path(relative).parts[0] in {"sessions", "archived_sessions"}:
                dest = scratch / relative
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.touch()
        changes, pending = inspect_copy(str(source), scratch, str(target), False)
        pending.extend(regeneration_tasks(manifest))
    writers(source)
    require(inventory(source) == manifest, "source changed during offline planning")
    return {"status": "planned", "profile": PROFILE["profile"], "entries": len(manifest),
            "files": sum(entry["kind"] == "file" for entry in manifest.values()),
            "required_bytes": required, "changes": changes, "pending": pending,
            "ready_for_activation": False, "source_unchanged": True}


def prepare(source, target):
    source, target = roots(source, target)
    writers(source)
    manifest = inventory(source)
    ensure_capacity(target, manifest)
    stage = target.with_name("." + target.name + ".revkit-staging-" + uuid.uuid4().hex)
    private_directory(stage, create=True)
    try:
        copy_tree(source, stage, manifest)
        require(copied_metadata(inventory(stage)) == copied_metadata(manifest),
                "copied bytes, effective access rules or link metadata differ")
        require(inventory(source) == manifest, "source changed during copying")
        changes, pending = inspect_copy(str(source), stage, str(target), True)
        pending.extend(regeneration_tasks(manifest))
        writers(source)
        require(inventory(source) == manifest, "source changed during offline preparation")
        prepared = inventory(stage)
        receipt = {"format": 1, "id": uuid.uuid4().hex, "profile": PROFILE["profile"],
                   "source": str(source), "target": str(target), "source_manifest": manifest,
                   "target_manifest": prepared, "changes": changes, "pending": pending,
                   "ready_for_activation": False, "storage_copy_verified": True,
                   "activation_validation_required": ["resume-first", "thread-read", "thread-list", "application-registration-and-consent"],
                   "activation_owner": "operator",
                   "source_unchanged": True, "status": "prepared"}
        with (stage / RECEIPT).open("x", encoding="utf-8") as stream:
            stream.write(encode(receipt))
        private_directory(stage)
        require(not target.exists(), "target appeared during preparation")
        stage.rename(target)
        return public_result(receipt)
    except BaseException:
        if stage.exists():
            shutil.rmtree(stage)
        raise


def public_result(receipt):
    return {key: receipt[key] for key in ["status", "profile", "changes", "pending",
                                        "ready_for_activation", "storage_copy_verified",
                                        "activation_validation_required", "source_unchanged"]}


def regeneration_tasks(manifest):
    owners = {}
    for entry in manifest.values():
        if entry["kind"] == "regenerate":
            owners[entry["owner"]] = owners.get(entry["owner"], 0) + 1
    result = [{"field": owner, "kind": "requires-supported-regeneration", "count": count,
               "action": "let the application regenerate command links" if owner == "app-command-links"
               else "refresh the browser plugin through supported application controls"}
              for owner, count in owners.items()]
    for item in result:
        if item["field"] == "browser-plugin-cache":
            item["verified_internal_targets"] = [
                {"relative": entry["target_relative"], "inode": entry["target_inode"]}
                for entry in manifest.values() if entry.get("owner") == "browser-plugin-cache"]
    return result


def read_receipt(target):
    target = Path(target).absolute()
    for ancestor in [target, *target.parents]:
        require(not is_link(ancestor), "linked migration target ancestry is unsupported")
    target = target.resolve()
    require(not is_link(target / RECEIPT), "migration receipt cannot be a link")
    receipt = json.loads((target / RECEIPT).read_text())
    require(receipt["format"] == 1 and receipt["profile"] == PROFILE["profile"]
            and Path(receipt["target"]).resolve() == target, "unknown or misplaced migration receipt")
    source = Path(receipt["source"]).resolve()
    require(source != target and source not in target.parents and target not in source.parents,
            "migration receipt roots overlap")
    return target, receipt


def verify(target):
    target, receipt = read_receipt(target)
    writers(target)
    private_directory(target)
    current = inventory(target)
    current.pop(RECEIPT, None)
    require(current == receipt["target_manifest"], "prepared target changed; retain it for operator review")
    require(inventory(Path(receipt["source"])) == receipt["source_manifest"], "original source changed")
    for path in target.iterdir():
        if path.suffix.casefold() != ".sqlite":
            continue
        connection = validate_database(path)
        connection.close()
    return public_result(receipt) | {"status": "verified"}


def rollback(target):
    target, receipt = read_receipt(target)
    writers(target)
    require(Path(receipt["source"]).is_dir(), "original source is missing")
    require(inventory(Path(receipt["source"])) == receipt["source_manifest"], "original source changed; operator rollback review required")
    retained = target.with_name(target.name + ".revkit-rollback-" + uuid.uuid4().hex)
    target.rename(retained)
    return {"status": "retained-for-rollback", "source_unchanged": True,
            "target_writes_retained": True, "activation_owner": "operator",
            "ready_for_activation": False, "retained_target": str(retained)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["plan", "prepare", "verify", "rollback"])
    parser.add_argument("--source", type=Path)
    parser.add_argument("--target", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.action in {"plan", "prepare"}:
            require(args.source is not None, "source is required")
            result = (plan if args.action == "plan" else prepare)(args.source, args.target)
        else:
            result = (verify if args.action == "verify" else rollback)(args.target)
        print(encode(result), end="")
        return 0 if not result.get("pending") else 2
    except Refused as error:
        print(encode({"status": "refused", "ready_for_activation": False, "reason": str(error)}), end="")
        return 1
    except (OSError, ValueError, TypeError, KeyError, sqlite3.Error, subprocess.SubprocessError):
        print(encode({"status": "refused", "ready_for_activation": False,
                      "reason": "offline, layout, path, ownership or consistency validation failed"}), end="")
        return 1


if __name__ == "__main__":
    sys.exit(main())

from contextlib import closing
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("home_migrate", ROOT / "scripts/codex-home-migrate.py")
ADAPTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ADAPTER)
from codex_adapter_lib import Refused, contains_home, rebase_storage, references, storage_relative


def database(path, name="state_5.sqlite"):
    profile = ADAPTER.PROFILE["databases"][name]
    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(path)
    if "schema" in profile:
        for kind in ["table", "index", "trigger"]:
            for row in profile["schema"]:
                if row[0] == kind:
                    connection.execute(row[3])
        if "migrations" in profile:
            connection.executemany(
                "INSERT INTO _sqlx_migrations(version,description,installed_on,success,checksum,execution_time) VALUES(?, 'synthetic', '2026-11-25', ?, ?, 0)",
                [(version, success, bytes.fromhex(checksum)) for version, checksum, success in profile["migrations"]])
        if "desktop_migrations" in profile:
            connection.executemany(
                "INSERT INTO codex_schema_migrations(id,predecessor_id,checksum,applied_at) VALUES(?,?,?,1)",
                profile["desktop_migrations"])
    else:
        connection.execute("CREATE TABLE settings (scope TEXT NOT NULL,key TEXT NOT NULL,value TEXT NOT NULL,PRIMARY KEY(scope,key))")
    connection.execute("PRAGMA user_version=" + str(profile["user_version"]))
    connection.commit()
    return connection


def fixture(root, pending=False):
    root.mkdir(mode=0o700)
    rollout = root / "sessions" / "2026" / "11" / "25" / "rollout-synthetic.jsonl"
    rollout.parent.mkdir(parents=True)
    rollout.write_bytes(b'{"type":"synthetic-history","message":"preserve exact bytes"}\n')
    (root / "auth.json").write_bytes(b'{"synthetic":true}\r\n')
    connection = database(root / "state_5.sqlite")
    policy = {"type": "read-only", "network_access": False}
    if pending:
        policy["writable_roots"] = [str(root / "hooks")]
    connection.execute("INSERT INTO threads(id,rollout_path,created_at,updated_at,source,model_provider,cwd,title,sandbox_policy,approval_mode) VALUES(?,?,?,?,?,?,?,?,?,?)",
                       ("synthetic-thread-id", str(rollout), 1, 2, "cli", "openai", "/synthetic/project",
                        "synthetic title", json.dumps(policy), "on-request"))
    connection.commit()
    connection.close()
    return rollout


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.base = Path(self.directory.name)
        self.source = self.base / "original"
        self.target = self.base / "moved"
        self.rollout = fixture(self.source)
        if os.name == "nt":
            self.writer_patch = patch.object(ADAPTER, "writers")
            self.writer_patch.start()
            self.addCleanup(self.writer_patch.stop)

    def test_plan_is_source_read_only_and_never_ready(self):
        before = ADAPTER.inventory(self.source)
        result = ADAPTER.plan(self.source, self.target)
        self.assertFalse(result["ready_for_activation"])
        self.assertEqual(ADAPTER.inventory(self.source), before)
        self.assertFalse(self.target.exists())

    def test_preexisting_absent_rollout_preserves_rows_and_records_unresolved_baseline(self):
        self.rollout.unlink()
        before = ADAPTER.inventory(self.source)
        result = ADAPTER.prepare(self.source, self.target)
        self.assertTrue(result["storage_copy_verified"])
        self.assertFalse(result["ready_for_activation"])
        self.assertEqual(ADAPTER.inventory(self.source), before)
        receipt = json.loads((self.target / ADAPTER.RECEIPT).read_text())
        baseline = receipt["rollout_baseline"]
        self.assertEqual(len(baseline), 1)
        self.assertEqual(baseline[0]["thread_id"], "synthetic-thread-id")
        self.assertEqual(baseline[0]["presence"], "missing")
        self.assertFalse((self.target / baseline[0]["relative"]).exists())
        with closing(sqlite3.connect(self.target / "state_5.sqlite")) as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM threads").fetchone(), (1,))
        self.assertTrue(any(item["kind"] == "requires-history-verification" for item in result["pending"]))
        self.assertEqual(ADAPTER.verify(self.target)["status"], "verified")

    def test_copy_cannot_classify_a_newly_lost_rollout_as_preexisting_absence(self):
        copied = self.base / "copied"
        copied.mkdir(mode=0o700)
        manifest = ADAPTER.inventory(self.source)
        ADAPTER.copy_tree(self.source, copied, manifest)
        (copied / self.rollout.relative_to(self.source)).unlink()
        with self.assertRaises(Refused):
            ADAPTER.inspect_copy(str(self.source), copied, str(self.target), True, manifest, [])

    def test_permission_failure_is_never_classified_as_missing_history(self):
        with patch.object(Path, "lstat", side_effect=PermissionError("synthetic denial")):
            with self.assertRaises(PermissionError):
                ADAPTER.rollout_presence(self.source, ("sessions", "synthetic.jsonl"))

    def test_prepared_receipt_cannot_silently_adopt_another_profile_set(self):
        ADAPTER.prepare(self.source, self.target)
        path = self.target / ADAPTER.RECEIPT
        receipt = json.loads(path.read_text())
        receipt["profile_set"]["codex-desktop-layout-v1.json"] = "0" * 64
        path.write_text(json.dumps(receipt))
        with self.assertRaises(Refused) as caught:
            ADAPTER.verify(self.target)
        self.assertIn("profile set", str(caught.exception))

    def test_capacity_includes_desktop_database_recovery_space(self):
        from types import SimpleNamespace
        with patch.object(ADAPTER.shutil, "disk_usage", return_value=SimpleNamespace(free=64 * 1024 * 1024 + 199)):
            with self.assertRaises(Refused):
                ADAPTER.ensure_capacity(self.target, {"sqlite/codex.db": {"kind": "file", "size": 100}})

    def test_copied_config_projects_adopted_home_without_changing_owner_policy(self):
        text = 'model = "owner-model"\n[shell_environment_policy]\ninherit = "core"\n[shell_environment_policy.set]\nOWNER_VALUE = "preserve"\n'
        (self.source / "config.toml").write_text(text)
        result = ADAPTER.prepare(self.source, self.target)
        import tomllib
        changed = tomllib.loads((self.target / "config.toml").read_text())
        self.assertEqual(changed["shell_environment_policy"]["set"]["CODEX_HOME"], str(self.target))
        self.assertEqual(changed["shell_environment_policy"]["set"]["OWNER_VALUE"], "preserve")
        self.assertEqual(changed["shell_environment_policy"]["inherit"], "core")
        self.assertEqual(changed["model"], "owner-model")
        self.assertEqual((self.source / "config.toml").read_text(), text)
        self.assertFalse(result["ready_for_activation"])

    def test_copied_home_refuses_owner_identity_or_filter_conflicts(self):
        for text in ['[shell_environment_policy.set]\nCODEX_HOME = "/synthetic/other-account"\n',
                     '[shell_environment_policy]\ninherit = "core"\ninclude_only = ["PATH", "HOME"]\n']:
            with self.subTest(text=text), self.assertRaises(Refused):
                ADAPTER.project_copied_home(text, str(self.source), str(self.target))

    def test_prepare_rebases_only_index_and_preserves_history_auth_and_rows(self):
        before = ADAPTER.inventory(self.source)
        connection = sqlite3.connect(self.source / "state_5.sqlite")
        row_before = connection.execute("SELECT * FROM threads").fetchone()
        connection.close()
        result = ADAPTER.prepare(self.source, self.target)
        self.assertFalse(result["ready_for_activation"])
        self.assertTrue(result["storage_copy_verified"])
        self.assertEqual(ADAPTER.inventory(self.source), before)
        connection = sqlite3.connect(self.target / "state_5.sqlite")
        row_after = connection.execute("SELECT * FROM threads").fetchone()
        self.assertEqual(connection.execute("PRAGMA integrity_check").fetchone(), ("ok",))
        connection.close()
        self.assertEqual(row_before[:1] + row_before[2:], row_after[:1] + row_after[2:])
        self.assertEqual(Path(row_after[1]), self.target / self.rollout.relative_to(self.source))
        self.assertEqual(self.rollout.read_bytes(), Path(row_after[1]).read_bytes())
        self.assertEqual((self.source / "auth.json").read_bytes(), (self.target / "auth.json").read_bytes())
        self.assertEqual(ADAPTER.verify(self.target)["status"], "verified")

    def test_policy_references_are_preserved_and_block_readiness(self):
        with closing(sqlite3.connect(self.source / "state_5.sqlite")) as connection, connection:
            policy = json.dumps({"writable_roots": [str(self.source / "hooks")]})
            connection.execute("UPDATE threads SET sandbox_policy=?", (policy,))
        result = ADAPTER.prepare(self.source, self.target)
        self.assertFalse(result["ready_for_activation"])
        self.assertTrue(result["pending"])
        with closing(sqlite3.connect(self.target / "state_5.sqlite")) as connection, connection:
            self.assertEqual(connection.execute("SELECT sandbox_policy FROM threads").fetchone()[0], policy)
        self.assertFalse(ADAPTER.verify(self.target)["ready_for_activation"])

    def test_known_config_storage_is_rebased_but_trust_is_not(self):
        config = '[mcp_servers.node_repl.env]\nCODEX_HOME=' + json.dumps(str(self.source)) + '\n'
        config += 'NODE_REPL_TRUSTED_SERVICES=' + json.dumps(json.dumps({"path": str(self.source / "plugins")})) + '\n'
        (self.source / "config.toml").write_text(config)
        result = ADAPTER.prepare(self.source, self.target)
        self.assertFalse(result["ready_for_activation"])
        import tomllib
        after = tomllib.loads((self.target / "config.toml").read_text())
        self.assertEqual(after["mcp_servers"]["node_repl"]["env"]["CODEX_HOME"], str(self.target))
        self.assertEqual(json.loads(after["mcp_servers"]["node_repl"]["env"]["NODE_REPL_TRUSTED_SERVICES"])["path"], str(self.source / "plugins"))

    def test_unknown_column_and_migration_checksum_are_refused(self):
        for index, change in enumerate(["ALTER TABLE threads ADD COLUMN unknown TEXT",
                                       "UPDATE _sqlx_migrations SET checksum=x'00' WHERE version=64"]):
            with self.subTest(change=change):
                source = self.base / ("schema-source-" + str(index))
                target = self.base / ("schema-target-" + str(index))
                fixture(source)
                with closing(sqlite3.connect(source / "state_5.sqlite")) as connection, connection:
                    connection.execute(change)
                before = ADAPTER.inventory(source)
                with self.assertRaises(Refused):
                    ADAPTER.prepare(source, target)
                self.assertEqual(ADAPTER.inventory(source), before)
                self.assertFalse(target.exists())

    def test_unknown_database_and_nested_database_are_refused(self):
        (self.source / "unexpected.sqlite").write_bytes(b"synthetic")
        with self.assertRaises(Refused):
            ADAPTER.prepare(self.source, self.target)
        (self.source / "unexpected.sqlite").unlink()
        nested = self.source / "plugin" / "nested.sqlite"
        nested.parent.mkdir()
        nested.write_bytes(b"synthetic")
        with self.assertRaises(Refused):
            ADAPTER.prepare(self.source, self.target)

    def test_uppercase_unknown_database_is_not_silently_copied(self):
        (self.source / "EVIL.SQLITE").write_bytes(b"synthetic")
        with self.assertRaises(Refused):
            ADAPTER.prepare(self.source, self.target)

    def test_all_supported_database_schemas_are_validated(self):
        for name in ADAPTER.PROFILE["databases"]:
            if name == "state_5.sqlite":
                continue
            connection = database(self.source / name, name)
            connection.close()
        result = ADAPTER.prepare(self.source, self.target)
        self.assertTrue(result["storage_copy_verified"])

    def test_source_wal_and_shm_bytes_are_not_changed_by_planning(self):
        connection = sqlite3.connect(self.source / "state_5.sqlite")
        try:
            connection.execute("PRAGMA journal_mode=WAL")
            connection.execute("UPDATE threads SET name='synthetic wal update'")
            connection.commit()
            before = ADAPTER.inventory(self.source)
            ADAPTER.plan(self.source, self.target)
            self.assertEqual(ADAPTER.inventory(self.source), before)
            self.assertTrue((self.source / "state_5.sqlite-wal").is_file())
        finally:
            connection.close()

    def test_overlapping_source_and_target_are_refused(self):
        with self.assertRaises(Refused):
            ADAPTER.plan(self.source, self.source / "moved")

    def test_known_generated_links_are_not_followed_or_copied(self):
        if os.name == "nt":
            self.skipTest("native Windows reparse fixtures are controller-owned")
        link = self.source / "tmp" / "arg0-linux" / "codex-arg0-synthetic" / "apply_patch"
        link.parent.mkdir(parents=True)
        link.symlink_to("/missing-external-executable")
        result = ADAPTER.prepare(self.source, self.target)
        self.assertFalse((self.target / link.relative_to(self.source)).exists())
        self.assertFalse((self.target / link.relative_to(self.source)).is_symlink())
        self.assertTrue(link.is_symlink())
        self.assertTrue(any(x["field"] == "app-command-links" for x in result["pending"]))

    def test_rollback_does_not_claim_unchanged_source_after_source_mutation(self):
        ADAPTER.prepare(self.source, self.target)
        (self.source / "new-original-write").write_bytes(b"preserve")
        with self.assertRaises(Refused):
            ADAPTER.rollback(self.target)
        self.assertTrue(self.target.exists())

    def test_existing_target_capacity_and_writer_refusals_preserve_original(self):
        before = ADAPTER.inventory(self.source)
        with patch.object(ADAPTER.shutil, "disk_usage", return_value=type("Usage", (), {"free": 0})()):
            with self.assertRaises(Refused):
                ADAPTER.prepare(self.source, self.target)
        with patch.object(ADAPTER, "writers", side_effect=Refused("writer")):
            with self.assertRaises(Refused):
                ADAPTER.prepare(self.source, self.target)
        self.target.mkdir()
        marker = self.target / "keep"
        marker.write_bytes(b"unrelated")
        with self.assertRaises(Refused):
            ADAPTER.prepare(self.source, self.target)
        self.assertEqual(marker.read_bytes(), b"unrelated")
        self.assertEqual(ADAPTER.inventory(self.source), before)

    def test_partial_copy_failure_does_not_publish_or_change_source(self):
        before = ADAPTER.inventory(self.source)
        with patch.object(ADAPTER.shutil, "copy2", side_effect=OSError("synthetic failure")):
            with self.assertRaises(OSError):
                ADAPTER.prepare(self.source, self.target)
        self.assertFalse(self.target.exists())
        self.assertEqual(ADAPTER.inventory(self.source), before)
        self.assertFalse(list(self.base.glob(".*.revkit-staging-*")))

    def test_rollback_retains_new_target_writes_and_original_bytes(self):
        before = ADAPTER.inventory(self.source)
        ADAPTER.prepare(self.source, self.target)
        (self.target / "post-activation.txt").write_bytes(b"new target write")
        with self.assertRaises(Refused):
            ADAPTER.verify(self.target)
        result = ADAPTER.rollback(self.target)
        self.assertFalse(self.target.exists())
        self.assertEqual((Path(result["retained_target"]) / "post-activation.txt").read_bytes(), b"new target write")
        self.assertEqual(ADAPTER.inventory(self.source), before)

    def test_safe_relative_links_preserved_and_external_links_refused(self):
        if os.name == "nt":
            (self.source / "linked-directory-target").mkdir()
            link = self.source / "external-junction"
            result = subprocess.run(["cmd.exe", "/c", "mklink", "/J", str(link), str(self.base)],
                                    capture_output=True)
            self.assertEqual(result.returncode, 0)
            try:
                with self.assertRaises(Refused):
                    ADAPTER.plan(self.source, self.target)
            finally:
                os.rmdir(link)
            return
        (self.source / "history-link").symlink_to(self.rollout.relative_to(self.source))
        ADAPTER.prepare(self.source, self.target)
        self.assertEqual(os.readlink(self.target / "history-link"), os.readlink(self.source / "history-link"))
        (self.source / "outside-link").symlink_to(self.base)
        with self.assertRaises(Refused):
            ADAPTER.plan(self.source, self.base / "second")

    def test_browser_cache_alias_has_internal_target_identity_and_is_not_recreated(self):
        chrome = self.source / "plugins" / "cache" / "openai-bundled" / "chrome"
        version = chrome / "26.1120.synthetic"
        version.mkdir(parents=True)
        (version / "package.json").write_text('{"synthetic":true}')
        link = chrome / "latest"
        if os.name == "nt":
            result = subprocess.run(["cmd.exe", "/c", "mklink", "/J", str(link), str(version)],
                                    capture_output=True)
            self.assertEqual(result.returncode, 0)
        else:
            link.symlink_to(version.name)
        try:
            before = ADAPTER.inventory(self.source)
            self.assertEqual(before[link.relative_to(self.source).as_posix()]["target_relative"], version.relative_to(self.source).as_posix())
            result = ADAPTER.prepare(self.source, self.target)
            self.assertTrue(any(x["field"] == "browser-plugin-cache" for x in result["pending"]))
            self.assertFalse((self.target / link.relative_to(self.source)).exists())
        finally:
            if os.name == "nt":
                os.rmdir(link)

    def test_real_open_source_handle_is_refused_on_linux(self):
        if os.name == "nt":
            return
        child = subprocess.Popen([sys.executable, "-c", "import sys; f=open(sys.argv[1],'rb'); print('ready',flush=True); sys.stdin.read(1)",
                                  str(self.source / "auth.json")], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(), "ready")
            with self.assertRaises(Refused):
                ADAPTER.plan(self.source, self.target)
        finally:
            child.communicate("x", timeout=5)

    @unittest.skipUnless(os.name == "nt", "requires native Windows access controls")
    def test_windows_acl_drift_in_source_or_target_is_detected(self):
        from codex_adapter_lib import windows_access
        ADAPTER.prepare(self.source, self.target)
        source_file = self.source / "auth.json"
        windows_access(source_file, private=True)
        with self.assertRaises(Refused):
            ADAPTER.verify(self.target)
        other_source = self.base / "second-original"
        other_target = self.base / "second-moved"
        fixture(other_source)
        ADAPTER.prepare(other_source, other_target)
        changed = other_target / "auth.json"
        result = subprocess.run(["icacls.exe", str(changed), "/grant", "*S-1-5-32-545:(RX)"], capture_output=True)
        self.assertEqual(result.returncode, 0)
        with self.assertRaises(Refused):
            ADAPTER.verify(other_target)

    def test_workspace_and_attachment_fields_are_preserved_and_pending(self):
        with closing(sqlite3.connect(self.source / "state_5.sqlite")) as connection, connection:
            connection.execute("UPDATE threads SET cwd=?,agent_path=?", (str(self.source / "worktrees"), str(self.source / "agents")))
        result = ADAPTER.prepare(self.source, self.target)
        fields = {entry["field"] for entry in result["pending"]}
        self.assertIn("threads.cwd", fields)
        self.assertIn("threads.agent_path", fields)

    def test_global_permission_json_is_copied_unchanged_and_pending(self):
        value = json.dumps({"heartbeat-thread-permissions-by-id": {"synthetic": {"writableRoots": [str(self.source)]}}})
        (self.source / ".codex-global-state.json").write_text(value)
        result = ADAPTER.prepare(self.source, self.target)
        self.assertFalse(result["ready_for_activation"])
        self.assertEqual((self.target / ".codex-global-state.json").read_text(), value)


class PathTests(unittest.TestCase):
    def test_ordinary_extended_and_case_insensitive_windows_paths(self):
        old = r"C:\Synthetic\owner\.codex"
        new = r"E:\AI\windows\codex"
        value = r"c:\synthetic\OWNER\.CODEX\sessions\2026\rollout.jsonl"
        self.assertEqual(rebase_storage(value, old, new), new + r"\sessions\2026\rollout.jsonl")
        self.assertEqual(rebase_storage("\\\\?\\" + value, old, new), "\\\\?\\" + new + r"\sessions\2026\rollout.jsonl")
        self.assertTrue(contains_home(old + r"\hooks\policy.py", "\\\\?\\" + old))

    def test_embedded_trust_json_reference_is_detected(self):
        old = r"C:\Synthetic\owner\.codex"
        value = json.dumps({"path": old + r"\plugins\service"})
        self.assertEqual(references(value, old), 1)

    def test_prefix_collision_traversal_and_nonstorage_paths_are_rejected(self):
        old = r"C:\Synthetic\owner\.codex"
        for value in [old + r"-other\sessions\rollout.jsonl", old + r"\sessions\..\auth.jsonl",
                      old + r"\hooks\policy.jsonl", r"\\server\share\sessions\rollout.jsonl"]:
            with self.subTest(value=value), self.assertRaises(Refused):
                storage_relative(value, old)


if __name__ == "__main__":
    unittest.main()

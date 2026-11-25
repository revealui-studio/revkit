"""Exact desktop schema boundaries and preservation of account-scoped state."""
from contextlib import closing
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("desktop_home_migrate", ROOT / "scripts/codex-home-migrate.py")
ADAPTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ADAPTER)
from codex_adapter_lib import Refused

PROFILE = json.loads((ROOT / "scripts/codex-desktop-layout-v1.json").read_text())
SOURCE_HOME = r"C:\fixture\codex"
TARGET_HOME = r"E:\fixture\codex"


def create_database(path, relative_key):
    expected = PROFILE["databases"][relative_key]
    path.parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(path)) as connection:
        for kind in ["table", "index", "trigger", "view"]:
            for row in expected["schema"]:
                if row[0] == kind:
                    connection.execute(row[3])
        connection.execute("PRAGMA user_version=" + str(expected["user_version"]))
        connection.executemany(
            "INSERT INTO codex_schema_migrations "
            "(id,predecessor_id,checksum,applied_at,app_version,build_flavor,build_commit) "
            "VALUES(?,?,?,1,'synthetic-version','synthetic-flavor','synthetic-commit')",
            expected["desktop_migrations"])
        connection.commit()
    return path


def snapshot(path):
    with closing(sqlite3.connect(path)) as connection:
        return ADAPTER.database_snapshot(connection)


def seed_owner_state(path, workspace):
    with closing(sqlite3.connect(path)) as connection:
        connection.execute(
            "INSERT INTO automations "
            "(id,name,prompt,status,cwds,created_at,updated_at,account_id,user_id,installation_id,"
            "local_environment_config_path,execution_environment,notification_policy,model) "
            "VALUES(?,?,?,?,?,1,2,?,?,?,?,?,?,?)",
            ("synthetic-automation", "Owner automation", "Historical prompt " + SOURCE_HOME,
             "PAUSED", json.dumps([workspace]), "account-A", "user-A", "installation-A",
             SOURCE_HOME + r"\environments\owner.toml", "local",
             json.dumps({"policy": "owner-choice"}), "owner-selected-model"))
        connection.execute(
            "INSERT INTO automation_runs "
            "(thread_id,automation_id,status,source_cwd,created_at,updated_at,archived_user_message,archived_assistant_message) "
            "VALUES(?,?,?,?,1,2,?,?)",
            ("synthetic-thread", "synthetic-automation", "ARCHIVED", workspace,
             "Historical user message " + SOURCE_HOME, "Historical response " + SOURCE_HOME))
        connection.execute("INSERT INTO local_thread_catalog_hosts VALUES('local','local')")
        connection.execute(
            "INSERT INTO local_thread_catalog "
            "(host_id,thread_id,display_title,source_created_at,source_updated_at,cwd,source_kind,"
            "observation_sequence,missing_candidate,source_recency_at,project_id) "
            "VALUES('local','synthetic-thread','Owner title',1,2,?,'cli',7,0,2,'owner-project')", (workspace,))
        connection.execute(
            "INSERT INTO thread_timeline_ledger VALUES('local','synthetic-thread',1,'owner-record',?)",
            (json.dumps({"message": "Historical ledger " + SOURCE_HOME, "id": "preserve-id"}),))
        connection.execute("INSERT INTO local_app_server_feature_enablement VALUES('owner-feature',1,2)")
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_schema WHERE type='table'")}
        if "active_chat_turns" in tables:
            connection.execute(
                "INSERT INTO active_chat_turns VALUES('default','account-A','user-A','synthetic-thread','launch-A',2)")
        connection.commit()


class DesktopProfileTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_profiles_recreate_exact_schema_and_migration_chain(self):
        for relative, expected in PROFILE["databases"].items():
            with self.subTest(relative=relative):
                path = create_database(self.root / relative, relative)
                with closing(sqlite3.connect(path)) as connection:
                    self.assertEqual(ADAPTER.schema(connection), expected["schema"])
                    self.assertEqual(connection.execute("PRAGMA integrity_check").fetchall(), [("ok",)])
                    actual = [list(row) for row in connection.execute(
                        "SELECT id,predecessor_id,checksum FROM codex_schema_migrations ORDER BY id")]
                    self.assertEqual(actual, expected["desktop_migrations"])

    def test_both_exact_profiles_validate_with_relative_identity(self):
        for relative in PROFILE["databases"]:
            with self.subTest(relative=relative):
                path = create_database(self.root / relative, relative)
                with closing(ADAPTER.validate_database(path, relative)) as connection:
                    self.assertEqual(connection.execute("PRAGMA user_version").fetchone(), (34,))

    def test_same_user_version_does_not_make_stable_and_development_interchangeable(self):
        path = create_database(self.root / "sqlite/codex.db", "sqlite/codex-dev.db")
        with self.assertRaises(Refused):
            ADAPTER.validate_database(path, "sqlite/codex.db")

    def test_unknown_relative_path_cannot_borrow_known_basename(self):
        path = create_database(self.root / "sqlite/codex.db", "sqlite/codex.db")
        for relative in ["codex.db", "unrecognized/codex.db", "nested/sqlite/codex.db", "sqlite/../codex.db"]:
            with self.subTest(relative=relative), self.assertRaises(Refused):
                ADAPTER.validate_database(path, relative)

    def test_unknown_database_version_is_refused(self):
        path = create_database(self.root / "sqlite/codex.db", "sqlite/codex.db")
        with closing(sqlite3.connect(path)) as connection:
            connection.execute("PRAGMA user_version=35")
        with self.assertRaises(Refused):
            ADAPTER.validate_database(path, "sqlite/codex.db")

    def test_unknown_column_is_refused(self):
        path = create_database(self.root / "sqlite/codex.db", "sqlite/codex.db")
        with closing(sqlite3.connect(path)) as connection:
            connection.execute("ALTER TABLE automations ADD COLUMN unknown_owner_field TEXT")
        with self.assertRaises(Refused):
            ADAPTER.validate_database(path, "sqlite/codex.db")

    def test_changed_migration_checksum_is_refused(self):
        path = create_database(self.root / "sqlite/codex.db", "sqlite/codex.db")
        with closing(sqlite3.connect(path)) as connection:
            connection.execute("UPDATE codex_schema_migrations SET checksum=? WHERE id=?",
                               ("0" * 64, PROFILE["databases"]["sqlite/codex.db"]["desktop_migrations"][0][0]))
            connection.commit()
        with self.assertRaises(Refused):
            ADAPTER.validate_database(path, "sqlite/codex.db")

    def test_changed_migration_predecessor_is_refused(self):
        path = create_database(self.root / "sqlite/codex.db", "sqlite/codex.db")
        with closing(sqlite3.connect(path)) as connection:
            connection.execute("UPDATE codex_schema_migrations SET predecessor_id=? WHERE id=?",
                               ("unknown-predecessor", PROFILE["databases"]["sqlite/codex.db"]["desktop_migrations"][0][0]))
            connection.commit()
        with self.assertRaises(Refused):
            ADAPTER.validate_database(path, "sqlite/codex.db")

    def test_extra_migration_is_refused(self):
        path = create_database(self.root / "sqlite/codex.db", "sqlite/codex.db")
        with closing(sqlite3.connect(path)) as connection:
            connection.execute(
                "INSERT INTO codex_schema_migrations(id,predecessor_id,checksum,applied_at) VALUES(?,?,?,1)",
                ("unknown-migration", None, "0" * 64))
            connection.commit()
        with self.assertRaises(Refused):
            ADAPTER.validate_database(path, "sqlite/codex.db")

    def test_inspection_preserves_all_rows_and_reports_specific_workspace_fields(self):
        paths = []
        for relative in PROFILE["databases"]:
            path = create_database(self.root / relative, relative)
            seed_owner_state(path, SOURCE_HOME + r"\workspaces\owner")
            paths.append(path)
        before = {str(path): snapshot(path) for path in paths}
        required_fields = {"automations.cwds", "automations.local_environment_config_path",
                           "automation_runs.source_cwd", "local_thread_catalog.cwd"}
        for transform in [False, True]:
            with self.subTest(transform=transform):
                changes, pending = ADAPTER.inspect_copy(SOURCE_HOME, self.root, TARGET_HOME, transform)
                self.assertEqual(changes, [])
                fields = {item["field"] for item in pending}
                self.assertTrue(required_fields.issubset(fields), fields)
                for item in pending:
                    self.assertGreater(item["count"], 0)
                    self.assertTrue(item["kind"].startswith("requires-"))
                self.assertEqual({str(path): snapshot(path) for path in paths}, before)

    def test_current_path_fields_outside_source_home_do_not_need_rebasing(self):
        relative = "sqlite/codex.db"
        path = create_database(self.root / relative, relative)
        seed_owner_state(path, r"C:\fixture\codex-other\workspace")
        with closing(sqlite3.connect(path)) as connection:
            connection.execute("UPDATE automations SET local_environment_config_path=?",
                               (r"E:\external\environment.toml",))
            connection.commit()
        before = snapshot(path)
        changes, pending = ADAPTER.inspect_copy(SOURCE_HOME, self.root, TARGET_HOME, True)
        self.assertEqual(changes, [])
        self.assertFalse({"automations.cwds", "automations.local_environment_config_path",
                          "automation_runs.source_cwd", "local_thread_catalog.cwd"}
                         .intersection(item["field"] for item in pending))
        self.assertEqual(snapshot(path), before)

    def test_unknown_nested_database_is_refused_by_copy_inspection(self):
        create_database(self.root / "unexpected/codex.db", "sqlite/codex.db")
        with self.assertRaises(Refused):
            ADAPTER.inspect_copy(SOURCE_HOME, self.root, TARGET_HOME, False)


if __name__ == "__main__":
    unittest.main()

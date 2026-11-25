import importlib.util
import hashlib
import json
import os
import csv
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("shell_config", ROOT / "scripts/codex-shell-config.py")
ADAPTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ADAPTER)
from codex_adapter_lib import Refused


class ShellConfigTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "nt", "requires native Windows inheritance behavior")
    def test_windows_same_parent_replacement_preserves_future_inheritance(self):
        from codex_adapter_lib import private_directory, windows_access, windows_access_inventory
        for protected in [False, True]:
            with self.subTest(protected=protected), tempfile.TemporaryDirectory() as directory:
                parent = Path(directory) / "owner"
                private_directory(parent, create=True)
                config = parent / "config.toml"
                config.write_bytes(b'model="owner-choice"\r\n')
                if protected:
                    windows_access(config, private=True)
                before = windows_access_inventory([config])[0]
                self.assertEqual(before["protected"], protected)
                ADAPTER.configure(config, {"CARGO_HOME": r"E:\AI\cargo"}, "windows", apply=True)
                after = windows_access_inventory([config])[0]
                self.assertEqual(before["inheritance"], after["inheritance"])
                self.assertEqual(before["protected"], after["protected"])
                changed = subprocess.run(["icacls.exe", str(parent), "/grant", "*S-1-5-32-545:(OI)(CI)(RX)"], capture_output=True)
                self.assertEqual(changed.returncode, 0)
                inherited = windows_access_inventory([config])[0]
                if protected:
                    self.assertEqual(after["effective"], inherited["effective"])
                else:
                    self.assertNotEqual(after["effective"], inherited["effective"])

    @unittest.skipUnless(os.name == "nt", "requires native Windows access controls")
    def test_windows_preserves_effective_file_access_and_refuses_write_deny(self):
        from codex_adapter_lib import windows_access_inventory
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.toml"
            config.write_bytes(b'model="owner-choice"\r\n')
            result = subprocess.run(["icacls.exe", str(config), "/grant", "*S-1-5-32-545:(RX)"], capture_output=True)
            self.assertEqual(result.returncode, 0)
            before = windows_access_inventory([config])[0]
            ADAPTER.configure(config, {"CARGO_HOME": r"E:\AI\cargo"}, "windows", apply=True)
            after = windows_access_inventory([config])[0]
            self.assertEqual(before["effective"], after["effective"])
            self.assertEqual(before["owner"], after["owner"])
            identity = subprocess.run(["whoami.exe", "/user", "/fo", "csv", "/nh"],
                                      capture_output=True, text=True, check=True)
            sid = next(csv.reader(identity.stdout.splitlines()))[1]
            result = subprocess.run(["icacls.exe", str(config), "/deny", "*" + sid + ":(WD)"], capture_output=True)
            self.assertEqual(result.returncode, 0)
            original = config.read_bytes()
            with self.assertRaises((OSError, Refused)):
                ADAPTER.configure(config, {"CARGO_HOME": r"E:\AI\cargo-next"}, "windows", apply=True)
            self.assertEqual(config.read_bytes(), original)

    def test_explicit_table_merges_preserving_owner_config_and_secrets(self):
        text = '''# owner preference
model = "owner-choice"
approval_policy = "on-request"
[shell_environment_policy]
inherit = "core"
ignore_default_excludes = false
[shell_environment_policy.set]
BASH_ENV = "~/.config/shell/env.sh"
EXAMPLE_SECRET = "synthetic-sentinel"
[plugins."owner-plugin"]
enabled = true
'''
        values = {"CARGO_HOME": r"E:\AI\toolchains\cargo", "GH_CONFIG_DIR": r"E:\AI\windows\gh"}
        result = ADAPTER.render(text, values, "windows")
        parsed = tomllib.loads(result)
        self.assertEqual(parsed["model"], "owner-choice")
        self.assertEqual(parsed["approval_policy"], "on-request")
        policy = parsed["shell_environment_policy"]
        self.assertEqual(policy["inherit"], "core")
        self.assertFalse(policy["ignore_default_excludes"])
        self.assertEqual(policy["set"]["EXAMPLE_SECRET"], "synthetic-sentinel")
        self.assertEqual(policy["set"]["BASH_ENV"], "~/.config/shell/env.sh")
        self.assertEqual(policy["set"]["CARGO_HOME"], values["CARGO_HOME"])
        self.assertIn("# owner preference", result)

    def test_inline_map_is_merged_without_changing_other_tables(self):
        text = r'''[shell_environment_policy]
inherit = "core"
set = { BASH_ENV = "~/.config/shell/env.sh", CARGO_HOME = "C:\\old" }
[mcp_servers.owned]
command = "owner-command"
'''
        result = tomllib.loads(ADAPTER.render(text, {"CARGO_HOME": r"E:\AI\cargo"}, "windows"))
        self.assertEqual(result["shell_environment_policy"]["set"]["CARGO_HOME"], r"E:\AI\cargo")
        self.assertEqual(result["mcp_servers"]["owned"]["command"], "owner-command")

    def test_missing_policy_uses_core_and_no_secret_values_are_added(self):
        text = 'model = "owner-choice"\n'
        values = {"NVM_DIR": "/srv/synthetic-home/.nvm"}
        parsed = tomllib.loads(ADAPTER.render(text, values, "linux"))
        self.assertEqual(parsed["shell_environment_policy"], {"inherit": "core", "set": values})

    def test_idempotent_semantics(self):
        text = '[shell_environment_policy]\ninherit="core"\n'
        values = {"PNPM_HOME": "/srv/synthetic-home/.local/share/pnpm"}
        once = ADAPTER.render(text, values, "linux")
        twice = ADAPTER.render(once, values, "linux")
        self.assertEqual(tomllib.loads(once), tomllib.loads(twice))

    def test_unapproved_names_are_rejected(self):
        for name in ["PATH", "NODE_OPTIONS", "BASH_ENV", "CODEX_HOME", "OPENAI_API_KEY", "EXAMPLE_TOKEN"]:
            with self.subTest(name=name), self.assertRaises(Refused):
                ADAPTER.render("", {name: "/srv/synthetic-home/value"}, "linux")

    def test_cross_platform_and_relative_paths_are_rejected(self):
        for platform, value in [("linux", r"C:\Synthetic\owner\.nvm"),
                                ("linux", "/mnt/c/runtime"), ("windows", "relative"),
                                ("windows", r"\\wsl.localhost\Ubuntu\home\synthetic")]:
            key = "NVM_HOME" if platform == "windows" else "NVM_DIR"
            with self.subTest(platform=platform, value=value), self.assertRaises(Refused):
                ADAPTER.render("", {key: value}, platform)

    def test_owner_filters_are_preserved_and_conflicts_refuse(self):
        base = '[shell_environment_policy]\ninherit="core"\n'
        for suffix in ['include_only=["PATH"]\n', 'exclude=["CARGO_*"]\n',
                       '[shell_environment_policy.filters]\n"CARGO_*"="exclude"\n',
                       '[shell_environment_policy.filters]\n"PATH"="include"\n']:
            with self.subTest(suffix=suffix), self.assertRaises(Refused):
                ADAPTER.render(base + suffix, {"CARGO_HOME": "/srv/synthetic-home/.cargo"}, "linux")

    def test_compatible_filter_form_does_not_gain_legacy_arrays(self):
        text = '''[shell_environment_policy]
inherit="core"
ignore_default_excludes=false
[shell_environment_policy.filters]
"AWS_*"="exclude"
"CARGO_HOME"="include"
'''
        parsed = tomllib.loads(ADAPTER.render(text, {"CARGO_HOME": "/srv/synthetic-home/.cargo"}, "linux"))
        policy = parsed["shell_environment_policy"]
        self.assertEqual(policy["filters"], {"AWS_*": "exclude", "CARGO_HOME": "include"})
        self.assertNotIn("include_only", policy)

    def test_other_inheritance_is_not_silently_changed(self):
        for value in ["all", "none"]:
            with self.subTest(value=value), self.assertRaises(Refused):
                ADAPTER.render('[shell_environment_policy]\ninherit="' + value + '"\n',
                               {"NVM_DIR": "/srv/synthetic-home/.nvm"}, "linux")

    def test_plan_does_not_write_and_apply_has_exact_private_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.toml"
            before = '# kept\nmodel="owner-choice"\n'
            config.write_text(before)
            values = {"NVM_DIR": "/srv/synthetic-home/.nvm"}
            result = ADAPTER.configure(config, values, "linux")
            self.assertFalse(result["applied"])
            self.assertEqual(config.read_text(), before)
            result = ADAPTER.configure(config, values, "linux", apply=True)
            self.assertTrue(result["applied"])
            backups = list(config.parent.rglob("config.toml.revkit-before-*"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_text(), before)
            if os.name == "nt":
                from codex_adapter_lib import private_directory
                private_directory(backups[0].parent)
            else:
                self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)

    def test_crlf_backup_and_hash_match_physical_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.toml"
            before = b'# kept\r\nmodel="owner-choice"\r\n'
            config.write_bytes(before)
            result = ADAPTER.configure(config, {"NVM_DIR": "/srv/synthetic-home/.nvm"}, "linux", apply=True)
            self.assertEqual(result["before_sha256"], hashlib.sha256(before).hexdigest())
            backups = list(config.parent.rglob("config.toml.revkit-before-*"))
            self.assertEqual(backups[0].read_bytes(), before)
            self.assertEqual(result["after_sha256"], hashlib.sha256(config.read_bytes()).hexdigest())

    def test_windows_case_insensitive_key_is_updated_without_duplicate(self):
        text = '[shell_environment_policy]\ninherit="core"\n[shell_environment_policy.set]\ncargo_home="C:/old"\n'
        parsed = tomllib.loads(ADAPTER.render(text, {"CARGO_HOME": r"E:\AI\cargo"}, "windows"))
        self.assertEqual(parsed["shell_environment_policy"]["set"], {"cargo_home": r"E:\AI\cargo"})

    def test_existing_backup_link_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.toml"
            config.write_text('model="owner-choice"\n')
            digest = hashlib.sha256(config.read_bytes()).hexdigest()
            if os.name == "nt":
                from codex_adapter_lib import private_directory
                backup_root = config.parent / ".revkit-config-backups"
                private_directory(backup_root, create=True)
            else:
                backup_root = config.parent
            backup = backup_root / (config.name + ".revkit-before-" + digest[:16])
            backup.symlink_to(config)
            with self.assertRaises(Refused):
                ADAPTER.configure(config, {"NVM_DIR": "/srv/synthetic-home/.nvm"}, "linux", apply=True)

    def test_cli_output_never_echoes_values(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.toml"
            values = Path(directory) / "values.json"
            config.write_text('model="owner-choice"\n')
            values.write_text(json.dumps({"CARGO_HOME": "/srv/synthetic-home/private-location"}))
            result = subprocess.run([sys.executable, str(ROOT / "scripts/codex-shell-config.py"),
                                     "plan", "--config", str(config), "--platform", "linux",
                                     "--values-file", str(values)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("private-location", result.stdout + result.stderr)
            self.assertEqual(json.loads(result.stdout)["variables"], ["CARGO_HOME"])


if __name__ == "__main__":
    unittest.main()

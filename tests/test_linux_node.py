import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('linux_node', ROOT / 'scripts/provision-linux-node.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LinuxNodeTests(unittest.TestCase):
    def test_owner_environment_preserved_and_exported_guard_reconciled(self):
        old = '[ -n "$_SHELL_ENV_LOADED" ] && return 0 2>/dev/null\n_SHELL_ENV_LOADED=1\nexport _SHELL_ENV_LOADED\nexport OWNER_SETTING=preserved\n'
        new = module.reconcile_env(old)
        self.assertNotIn('export _SHELL_ENV_LOADED', new)
        self.assertIn('export OWNER_SETTING=preserved', new)
        self.assertEqual(new, module.reconcile_env(new))

    def test_unknown_guard_refused(self):
        with self.assertRaises(ValueError):
            module.reconcile_env('export _SHELL_ENV_LOADED=1\nexport _SHELL_ENV_LOADED\n')

    def test_legacy_fnm_initialization_is_explicit_and_owner_code_survives(self):
        original = 'export OWNER_SETTING=kept\nif command -v fnm >/dev/null 2>&1; then\n    eval "$(fnm env)"\nfi\n'
        changed = module.reconcile_legacy_fnm(original)
        self.assertIn('export OWNER_SETTING=kept', changed)
        self.assertIn('[ "${REVKIT_NODE_MANAGER:-nvm}" = fnm ]', changed)
        self.assertEqual(changed, module.reconcile_legacy_fnm(changed))

    def test_default_selected_silently_despite_conflicting_path_and_inherited_guard(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            nvm = home / '.nvm'
            nvm.mkdir()
            node_bin = home / 'desired/bin'
            node_bin.mkdir(parents=True)
            (node_bin / 'node').write_text('#!/bin/sh\nprintf "v26.13.1\\n"\n')
            (node_bin / 'node').chmod(0o755)
            (nvm / 'nvm.sh').write_text('nvm() { export PATH="$HOME/desired/bin:$PATH"; }\n')
            env = {'HOME': str(home), 'PATH': '/usr/bin:/bin', '_SHELL_ENV_LOADED': '1', 'NVM_DIR': str(nvm)}
            cmd = f'. "{ROOT}/shell/lib/node-env.sh"; revkit_node_env; node --version'
            result = subprocess.run(['bash', '--noprofile', '--norc', '-c', cmd], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'v26.13.1\n')
            self.assertEqual(result.stderr, '')

    def test_unowned_executable_preserved(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            executable = root / 'node'
            executable.write_text('owner executable')
            try:
                module.replace_link(executable, root / 'desired', root / 'backup', [root / 'managed'], True)
            except ValueError:
                pass
            else:
                self.fail('unowned executable was accepted')
            self.assertEqual(executable.read_text(), 'owner executable')

    def test_private_mode_survives_atomic_environment_edit(self):
        with tempfile.TemporaryDirectory() as temp:
            file = Path(temp) / 'env.sh'
            file.write_text('owner configuration')
            file.chmod(0o600)
            module.atomic_bytes(file, b'preserved owner configuration')
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)

    def test_systemd_environment_preserves_unrelated_variables_and_path_entries(self):
        home = Path('/srv/fixture-home')
        desired = home / '.nvm/versions/node/v26.13.1'
        original = 'OWNER=kept\nPATH=/owner/bin:/srv/fixture-home/.local/share/fnm/node-versions/v24/installation/bin:/usr/bin\n'
        converted = module.reconcile_environment_path(original, home, desired)
        self.assertIn('OWNER=kept\n', converted)
        self.assertIn('/owner/bin:/usr/bin', converted)
        self.assertNotIn('/fnm/', converted)
        self.assertEqual(module.reconcile_environment_path(converted, home, desired), converted)
        self.assertIn('OWNER=kept\nPATH=', module.reconcile_environment_path('OWNER=kept', home, desired))

    def test_incomplete_runtime_is_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ValueError):
                module.artifact_files(Path(temp))

    def test_links_backed_up_without_removing_old_runtime(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            managed = root / 'managed'
            managed.mkdir()
            old = managed / 'old'
            old.write_text('old runtime')
            link = root / 'node'
            link.symlink_to(old)
            new = managed / 'new'
            new.write_text('new runtime')
            module.replace_link(link, new, root / 'backup', [managed])
            self.assertEqual(link.resolve(), new)
            self.assertEqual((root / 'backup/node').resolve(), old)
            self.assertEqual(old.read_text(), 'old runtime')


if __name__ == '__main__':
    unittest.main()

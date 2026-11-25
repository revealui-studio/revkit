import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


boot = load('boot', 'provision-wsl-boot.py')
shell = load('shell', 'reconcile-linux-shell.py')
helper = load('helper', 'provision-wsl-disk-helper.py')
OLD_NIX = '\n'.join(['# Nix', f"if [ -e '{shell.NIX_SCRIPT}' ]; then",
                     f"    . '{shell.NIX_SCRIPT}'", 'fi', '# End Nix', '', ''])


class BootTests(unittest.TestCase):
    def test_plan_preserves_existing_configuration_and_never_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source'
            etc = root / 'etc'
            windows = root / 'windows'
            for path in [source, etc, windows]:
                path.mkdir()
            (source / 'wsl.conf').write_text('[boot]\nsystemd=true\n')
            (source / 'wslconfig').write_text('[wsl2]\nmemory=8GB\n')
            owner = '[boot]\ninitTimeout=60000\n'
            (etc / 'wsl.conf').write_text(owner)
            proposed = boot.proposed_files(source, etc, windows)
            self.assertEqual([row[2] for row in proposed], ['preserve', 'seed'])
            self.assertEqual((etc / 'wsl.conf').read_text(), owner)
            self.assertFalse((windows / '.wslconfig').exists())

    def test_atomic_seed_refuses_existing_file_and_symbolic_destination(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'wsl.conf'
            self.assertTrue(boot.seed_missing(path, b'first\n'))
            self.assertFalse(boot.seed_missing(path, b'replacement\n'))
            self.assertEqual(path.read_bytes(), b'first\n')
            link = root / 'link'
            link.symlink_to(root / 'missing')
            self.assertFalse(boot.seed_missing(link, b'new\n'))
            self.assertTrue(link.is_symlink())


class ShellTests(unittest.TestCase):
    def test_nix_guard_sources_once_under_strict_shell(self):
        with tempfile.TemporaryDirectory() as directory:
            stub = Path(directory) / 'nix-daemon.sh'
            stub.write_text('NIX_TEST_COUNT=$(( ${NIX_TEST_COUNT:-0} + 1 ))\n')
            integration = shell.NIX_BLOCK.replace(shell.NIX_SCRIPT, str(stub))
            result = subprocess.run(['/bin/bash', '-euc', integration + integration +
                                     'printf "%s" "$NIX_TEST_COUNT"'],
                                    check=True, capture_output=True, text=True)
            self.assertEqual(result.stdout, '1')

    def fixture(self, directory):
        etc = Path(directory)
        (etc / 'profile.d').mkdir()
        (etc / 'bash.bashrc').write_text(OLD_NIX + OLD_NIX + 'old base\n')
        (etc / 'bash.bashrc.backup-before-nix').write_text(OLD_NIX + 'old base\n')
        (etc / 'bash.bashrc.dpkg-dist').write_text('new base\n')
        (etc / 'profile.d/nix.sh').write_text(OLD_NIX + OLD_NIX)
        return etc, hashlib.md5(b'new base\n').hexdigest()

    def test_duplicate_known_blocks_reconcile_to_package_base_and_one_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            etc, md5 = self.fixture(directory)
            desired, _ = shell.plan(etc, md5)
            self.assertEqual(desired[0][1], (shell.NIX_BLOCK + 'new base\n').encode())
            self.assertEqual(desired[1][1], shell.NIX_BLOCK.encode())
            self.assertTrue((etc / 'bash.bashrc').read_text().endswith('old base\n'))

    def test_owner_change_and_unknown_nix_block_refuse(self):
        with tempfile.TemporaryDirectory() as directory:
            etc, md5 = self.fixture(directory)
            with (etc / 'bash.bashrc').open('a') as stream:
                stream.write('owner customization\n')
            with self.assertRaises(ValueError) as caught:
                shell.plan(etc, md5)
            self.assertIn('owner changes', str(caught.exception))
        with self.assertRaises(ValueError) as caught:
            shell.strip_nix(OLD_NIX.replace('if [ -e ', 'if [ -f '))
        self.assertIn('Unrecognized Nix', str(caught.exception))

    def test_package_checksum_mismatch_refuses(self):
        with tempfile.TemporaryDirectory() as directory:
            etc, _ = self.fixture(directory)
            with self.assertRaises(ValueError) as caught:
                shell.plan(etc, '0' * 32)
            self.assertIn('package conffile checksum', str(caught.exception))

    def test_apply_backups_modes_and_idempotence(self):
        with tempfile.TemporaryDirectory() as directory:
            etc, md5 = self.fixture(directory)
            (etc / 'bash.bashrc').chmod(0o640)
            before = (etc / 'bash.bashrc').read_bytes()
            desired, observed = shell.plan(etc, md5)
            with patch.object(shell, 'root_custody'):
                backup = shell.apply(desired, observed, etc / 'backups')
            self.assertEqual((backup / 'bash.bashrc').read_bytes(), before)
            self.assertEqual((etc / 'bash.bashrc').stat().st_mode & 0o777, 0o640)
            self.assertEqual(len(json.loads((backup / 'receipt.json').read_text())['files']), 2)
            desired, observed = shell.plan(etc, md5)
            with patch.object(shell, 'root_custody'):
                self.assertIsNone(shell.apply(desired, observed, etc / 'backups'))

    def test_pre_activation_change_refuses_without_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            etc, md5 = self.fixture(directory)
            desired, observed = shell.plan(etc, md5)
            (etc / 'profile.d/nix.sh').write_text('owner update\n')
            with patch.object(shell, 'root_custody'):
                with self.assertRaises(ValueError) as caught:
                    shell.apply(desired, observed, etc / 'backups')
                self.assertIn('changed during planning', str(caught.exception))
            self.assertFalse((etc / 'backups').exists())

    def test_partial_activation_failure_restores_prior_file(self):
        with tempfile.TemporaryDirectory() as directory:
            etc, md5 = self.fixture(directory)
            desired, observed = shell.plan(etc, md5)
            original = (etc / 'bash.bashrc').read_bytes()
            replace = shell.atomic
            calls = []

            def fail_second(path, data, metadata):
                calls.append(path)
                if len(calls) == 2:
                    raise OSError('synthetic publication failure')
                replace(path, data, metadata)

            with patch.object(shell, 'root_custody'), patch.object(shell, 'atomic', side_effect=fail_second):
                with self.assertRaises(OSError):
                    shell.apply(desired, observed, etc / 'backups')
            self.assertEqual((etc / 'bash.bashrc').read_bytes(), original)


class HelperTests(unittest.TestCase):
    def test_managed_update_requires_unchanged_previous_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source.py'
            dest = root / 'lib/helper.py'
            receipt = root / 'state/receipt.json'
            source.write_bytes(b'reviewed first\n')
            with patch.object(helper, 'custody'), patch.object(helper.os, 'fchown'):
                first = hashlib.sha256(source.read_bytes()).hexdigest()
                helper.publish(source, dest, receipt, first)
                self.assertEqual(dest.read_bytes(), source.read_bytes())
                self.assertEqual(dest.stat().st_mode & 0o777, 0o644)
                self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)
                source.write_bytes(b'reviewed second\n')
                second = hashlib.sha256(source.read_bytes()).hexdigest()
                helper.publish(source, dest, receipt, second)
                self.assertEqual(json.loads(receipt.read_text())['sha256'], second)
                dest.write_bytes(b'unknown change\n')
                with self.assertRaises(ValueError) as caught:
                    helper.inspect(source, dest, receipt)
                self.assertIn('differs from its deployment receipt', str(caught.exception))

    def test_unknown_destination_and_missing_approved_sha_refuse(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source.py'
            dest = root / 'helper.py'
            receipt = root / 'receipt.json'
            source.write_text('reviewed helper\n')
            dest.write_text('owner helper\n')
            with patch.object(helper, 'custody'):
                with self.assertRaises(ValueError) as caught:
                    helper.inspect(source, dest, receipt)
                self.assertIn('no managed receipt', str(caught.exception))
                dest.unlink()
                with self.assertRaises(ValueError) as caught:
                    helper.publish(source, dest, receipt, None)
                self.assertIn('approved source SHA256', str(caught.exception))
            self.assertFalse(dest.exists())

    def test_unsafe_symlink_and_writable_parent_refuse(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / 'target'
            target.write_text('data')
            link = root / 'link'
            link.symlink_to(target)
            with self.assertRaises(ValueError) as caught:
                helper.custody(link)
            self.assertIn('Unsafe root-owned', str(caught.exception))
            root.chmod(0o777)
            with self.assertRaises(ValueError) as caught:
                helper.custody(target)
            self.assertIn('Unsafe root-owned', str(caught.exception))


if __name__ == '__main__':
    unittest.main()

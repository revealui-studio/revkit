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


class SelectedWorkerBootTests(unittest.TestCase):
    def policy(self,original):
        return {'schemaVersion':1,'role':'cold-backup-worker-v1','registrationId':'11111111-1111-4111-8111-111111111111',
                'distro':'spare-worker','rootfsUuid':'22222222-2222-4222-8222-222222222222',
                'defaultUser':'fixtureuser','defaultUid':1000,'initTimeoutMs':60000,'wslConfSha256':hashlib.sha256(original).hexdigest()}

    def test_selected_role_adds_only_timeout_and_preserves_owner_bytes(self):
        original=b'# owner\r\n[boot]\r\nsystemd=true\r\n[user]\r\ndefault=fixtureuser\r\n[network]\r\ngenerateResolvConf=false\r\n'
        policy=self.policy(original)
        plan,desired=boot.worker_boot_plan(boot.worker_policy(json.dumps(policy)),original,root_uuid=policy['rootfsUuid'],account_uid=1000)
        self.assertEqual(desired,original.replace(b'[user]',b'initTimeout=60000\r\n[user]'))
        self.assertFalse(plan['coldStartAccepted']);self.assertEqual(plan['startupWarningCause'],'unproved')
        policy['wslConfSha256']=hashlib.sha256(desired).hexdigest()
        repeat,new=boot.worker_boot_plan(policy,desired,root_uuid=policy['rootfsUuid'],account_uid=1000)
        self.assertFalse(repeat['changed']);self.assertEqual(desired,new)

    def test_role_account_rootfs_and_prior_bytes_are_fail_closed(self):
        original=b'[boot]\nsystemd=true\n[user]\ndefault=fixtureuser\n'
        policy=self.policy(original)
        for key,value in [('distro','Ubuntu'),('distro','Ubuntu-Recovery-20261124'),('initTimeoutMs',True),('initTimeoutMs',9999),('defaultUid',0)]:
            changed=dict(policy);changed[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):boot.worker_policy(json.dumps(changed))
        for uid,root,data in [(0,policy['rootfsUuid'],original),(1000,'wrong',original),(1000,policy['rootfsUuid'],original+b'# drift')]:
            with self.assertRaises(ValueError):boot.worker_boot_plan(policy,data,root_uuid=root,account_uid=uid)
        policy['defaultUser']='renamed'
        with self.assertRaises(ValueError):boot.worker_boot_plan(policy,original,root_uuid=policy['rootfsUuid'],account_uid=1000)

    def test_failed_worker_publication_retains_actual_original_and_new_attempt(self):
        original=b'[boot]\nsystemd=true\n[user]\ndefault=fixtureuser\n';policy=self.policy(original)
        plan,desired=boot.worker_boot_plan(policy,original,root_uuid=policy['rootfsUuid'],account_uid=1000)
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);path=root/'wsl.conf';path.write_bytes(original);state=root/'custody'
            actual_lstat=Path.lstat
            def observed(path):
                info=actual_lstat(path)
                return type('Info',(),{'st_uid':0,'st_mode':info.st_mode & ~0o022})()
            with patch.object(Path,'lstat',observed),patch.object(boot.os,'replace',side_effect=OSError('publication failed')):
                with self.assertRaises(OSError):boot.apply_worker_plan(policy,plan,desired,path,state)
            self.assertEqual(path.read_bytes(),original)
            attempts=list(state.iterdir());self.assertEqual(len(attempts),1)
            self.assertEqual((attempts[0]/'original-wsl.conf').read_bytes(),original)
            self.assertEqual(json.loads((attempts[0]/'plan.json').read_text())['beforeSha256'],plan['beforeSha256'])
            self.assertEqual(len(list(root.glob('.revkit-worker-*'))),1)

    def test_readiness_requires_actual_system_manager_and_user_session_not_timeout_assumption(self):
        original=b'[boot]\nsystemd=true\ninitTimeout=60000\n[user]\ndefault=fixtureuser\n';policy=self.policy(original)
        def query(argv,**kwargs):
            value=b'running\n' if argv[-1]=='is-system-running' else b'ActiveState=active\nSubState=running\nResult=success\n'
            return subprocess.CompletedProcess(argv,0,stdout=value,stderr=b'')
        with patch.object(boot,'selected_worker_context',return_value=(policy['rootfsUuid'],1000)),patch.object(boot.subprocess,'run',side_effect=query),patch.object(Path,'stat',return_value=type('Info',(),{'st_mode':0o140000})()),patch.object(Path,'read_text',return_value='synthetic-boot'):
            result=boot.worker_readiness(policy,original)
            self.assertTrue(result['readyNow']);self.assertFalse(result['coldStartAccepted'])
            with patch.object(boot.subprocess,'run',return_value=subprocess.CompletedProcess([],0,stdout=b'degraded',stderr=b'')):
                with self.assertRaises(ValueError):boot.worker_readiness(policy,original)


class ColdBootReportTests(unittest.TestCase):
    def receipt(self):
        return {'recorded_at': '2026-11-25T08:17:00Z', 'commands': [
            {'command': ['systemd-analyze', 'time'], 'exit_code': 0,
             'stdout': 'Startup finished in 1min 14.639s (userspace)'},
            {'command': ['systemd-analyze', 'critical-chain'], 'exit_code': 0,
             'stdout': 'multi-user.target @52.099s\n└─libvirtd.service @43.492s +8.606s'},
            {'command': ['systemd-analyze', '--user', 'critical-chain'], 'exit_code': 1,
             'stdout': ''}]}

    def test_saved_report_preserves_consumers_and_separates_desktop_adoption(self):
        data = json.dumps(self.receipt()).encode()
        result = boot.coldboot_report(data)
        self.assertEqual(result['evidenceSha256'], hashlib.sha256(data).hexdigest())
        self.assertEqual(result['services'], 'preserved')
        self.assertIn('unverified', result['desktopAdoption'])
        self.assertEqual(result['criticalChain'][1], {
            'unit': 'libvirtd.service', 'startedAfter': '43.492s', 'duration': '8.606s'})

    def test_missing_failed_duplicate_or_empty_command_refuses(self):
        for mode in ['missing', 'failed', 'duplicate', 'empty']:
            receipt = self.receipt()
            if mode == 'missing':
                receipt['commands'].pop(0)
            elif mode == 'failed':
                receipt['commands'][0]['exit_code'] = 1
            elif mode == 'duplicate':
                receipt['commands'].append(receipt['commands'][0])
            else:
                receipt['commands'][1]['stdout'] = 'no unit timing'
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                boot.coldboot_report(json.dumps(receipt).encode())

    def test_report_refuses_provisioning_before_opening_files(self):
        with patch('sys.argv', ['provision-wsl-boot.py', '--apply', '--boot-evidence', '/missing']), \
                patch.object(boot, 'proposed_files') as proposed:
            with self.assertRaises(SystemExit):
                boot.main()
            proposed.assert_not_called()

    def test_report_rejects_oversized_input(self):
        with self.assertRaises(ValueError):
            boot.coldboot_report(b' ' * (4 * 1024 * 1024 + 1))


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

import importlib.util
import json
from pathlib import Path
import stat
import tempfile
from types import SimpleNamespace
import unittest

SPEC = importlib.util.spec_from_file_location('wsl_disk_identity', Path(__file__).parents[1] / 'scripts/wsl-disk-identity.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class DiskIdentityTests(unittest.TestCase):
    def setUp(self):
        self.identity = {
            'schemaVersion': 1, 'serial': 'synthetic-disk', 'model': 'synthetic USB disk',
            'diskBytes': 2 * 1024 * 1024, 'partitionBytes': 512 * 1024,
            'partitionStartSectors': 2048, 'partitionSectors': 1024,
            'partitionUuid': '00000000-0000-0000-0000-000000000001',
            'filesystemUuid': '00000000-0000-0000-0000-000000000002',
            'filesystemLabel': 'revealfleet-data', 'mountPoint': '/mnt/synthetic',
        }
        self.commands = []
        self.clock = 0
        self.absent = 0
        self.uuid = self.identity['partitionUuid']
        self.mounted = False
        self.fs_uuid = self.identity['filesystemUuid']

    def runner(self, command, timeout):
        self.commands.append(command)
        if command[0] == 'lsblk':
            if self.absent:
                self.absent -= 1
                return SimpleNamespace(returncode=0, stdout='{"blockdevices": []}')
            data = {'blockdevices': [{'path': '/dev/sdz', 'type': 'disk', 'size': self.identity['diskBytes'], 'children': [
                {'path': '/dev/sdz1', 'type': 'part', 'size': self.identity['partitionBytes']}]}]}
        elif command[0] == 'sfdisk':
            data = {'partitiontable': {'label': 'gpt', 'sectorsize': 512, 'partitions': [{
                'node': '/dev/sdz1', 'start': 2048, 'size': 1024, 'uuid': self.uuid,
                'type': '0fc63daf-8483-4772-8e79-3d69d8477de4'}]}}
        elif command[0] == 'blkid':
            return SimpleNamespace(returncode=0, stdout='TYPE=ext4\nUUID=' + self.fs_uuid + '\nLABEL=revealfleet-data\n')
        elif command[0] == 'findmnt':
            if not self.mounted:
                return SimpleNamespace(returncode=1, stdout='')
            data = {'filesystems': [{'source': '/dev/sdz1', 'fstype': 'ext4', 'options': 'ro'}]}
        else:
            raise AssertionError(command)
        return SimpleNamespace(returncode=0, stdout=json.dumps(data))

    def sleep(self, delay):
        self.clock += delay

    def inspect(self, deadline=30):
        return MODULE.inspect(self.identity, runner=self.runner, now=lambda: self.clock,
                              sleep=self.sleep, deadline_seconds=deadline,
                              block_stat=lambda path: SimpleNamespace(st_mode=stat.S_IFBLK, st_rdev=1),
                              resolve=lambda value: value)

    def test_exact_not_mounted_is_not_successfully_mounted(self):
        result = self.inspect()
        self.assertEqual(result['mountState'], 'NOT_MOUNTED')
        self.assertTrue(result['identityVerified'])
        self.assertTrue(all(c[0] in ['lsblk', 'sfdisk', 'blkid', 'findmnt'] for c in self.commands))

    def test_absent_guest_serial_is_not_misrepresented_as_observed_windows_serial(self):
        original=self.runner
        def runner(command,timeout):
            result=original(command,timeout)
            if command[0]=='lsblk':
                value=json.loads(result.stdout)
                for row in value['blockdevices']:row['serial']=None
                result.stdout=json.dumps(value)
            return result
        self.runner=runner
        result=self.inspect()
        self.assertEqual(result['serialModelAuthority'],'configured-windows-identity-correlated-by-geometry')
        self.assertEqual(result['serial'],self.identity['serial'])

    def test_changed_parent_geometry_and_ambiguous_equal_sized_disks_refuse(self):
        original=self.runner
        for mode in ('parent-size','ambiguous','offset'):
            def runner(command,timeout):
                result=original(command,timeout)
                if command[0]=='lsblk':
                    value=json.loads(result.stdout)
                    if mode=='parent-size':value['blockdevices'][0]['size']+=512
                    elif mode=='ambiguous':value['blockdevices']*=2
                    result.stdout=json.dumps(value)
                elif command[0]=='sfdisk' and mode=='offset':
                    value=json.loads(result.stdout);value['partitiontable']['partitions'][0]['start']+=1
                    result.stdout=json.dumps(value)
                return result
            self.runner=runner
            with self.subTest(mode=mode),self.assertRaises(MODULE.IdentityError):self.inspect(deadline=1)
        self.runner=original

    def test_exact_mounted_identity_passes(self):
        self.mounted = True
        self.assertEqual(self.inspect()['mountState'], 'MOUNTED')

    def test_delayed_partition_is_bounded_and_revalidated(self):
        self.absent = 3
        self.assertTrue(self.inspect()['identityVerified'])
        self.assertEqual(self.clock, 0.75)
        self.assertIn('sfdisk', [c[0] for c in self.commands])

    def test_unready_disk_times_out_without_mount_or_write(self):
        self.absent = 1000
        with self.assertRaises(MODULE.IdentityError):
            self.inspect(deadline=1)
        self.assertEqual(self.clock, 1)
        self.assertTrue(all(c[0] == 'lsblk' for c in self.commands))

    def test_wrong_partition_uuid_refuses_before_filesystem_probe(self):
        self.uuid = '00000000-0000-0000-0000-000000000099'
        with self.assertRaises(MODULE.IdentityError):
            self.inspect()
        self.assertNotIn('blkid', [c[0] for c in self.commands])

    def test_wrong_filesystem_refuses(self):
        self.fs_uuid = '00000000-0000-0000-0000-000000000099'
        with self.assertRaises(MODULE.IdentityError):
            self.inspect()

    def test_unknown_layout_and_geometry_refuse(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'identity.json'
            path.write_text(json.dumps(self.identity))
            self.assertEqual(MODULE.load_identity(path), self.identity)
            self.identity['partitionBytes'] += 1
            path.write_text(json.dumps(self.identity))
            with self.assertRaises(MODULE.IdentityError):
                MODULE.load_identity(path)
            self.identity['unexpected'] = True
            path.write_text(json.dumps(self.identity))
            with self.assertRaises(MODULE.IdentityError):
                MODULE.load_identity(path)


class PrivilegedMountBoundaryTests(unittest.TestCase):
    def test_sandbox_scope_rejects_the_separate_data_disk_before_probing(self):
        import subprocess
        with tempfile.TemporaryDirectory() as directory:
            identity = {
                'schemaVersion': 1, 'serial': 'synthetic-disk', 'model': 'synthetic USB disk',
                'diskBytes': 2 * 1024 * 1024, 'partitionBytes': 512 * 1024,
                'partitionStartSectors': 2048, 'partitionSectors': 1024,
                'partitionUuid': '00000000-0000-0000-0000-000000000001',
                'filesystemUuid': '00000000-0000-0000-0000-000000000002',
                'filesystemLabel': 'revealfleet-data', 'mountPoint': '/mnt/synthetic',
            }
            path = Path(directory) / 'identity.json'
            path.write_text(json.dumps(identity))
            result = subprocess.run(['/usr/bin/python3', '-I', str(Path(__file__).parents[1] / 'scripts/wsl-disk-identity.py'),
                                     '--identity', str(path), '--require-mount-point', '/mnt/sandbox', '--require-label', 'Sandbox'],
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 1)
            self.assertIn('privileged helper scope', result.stderr)

    def test_unconfigured_privileged_helper_refuses_before_mounting(self):
        import subprocess
        with tempfile.TemporaryDirectory() as directory:
            source = Path(__file__).parents[1] / 'shell/bin/mount-sandbox-drive.sh'
            copied = Path(directory) / 'mount-sandbox-drive.sh'
            text = source.read_text()
            text = text.replace('/usr/local/lib/revealfleet/wsl-disk-identity.py', str(Path(directory) / 'absent-helper.py'))
            text = text.replace('/etc/revealfleet/disks/sandbox.json', str(Path(directory) / 'absent-identity.json'))
            copied.write_text(text)
            result = subprocess.run(['bash', str(copied), '--mount-only'], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 1)
            self.assertIn('no filesystem was mounted', result.stderr)


if __name__ == '__main__':
    unittest.main()

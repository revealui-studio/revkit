"""Actual Linux fixture observations and fail-closed provenance boundaries."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('borg_fixture', ROOT / 'scripts/wsl-borg-fixture.py')
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)


class ProvenanceTests(unittest.TestCase):
    def test_unsigned_or_mutated_tool_never_executes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary, signature = root / 'borg', root / 'borg.asc'
            binary.write_bytes(b'unreviewed executable')
            signature.write_bytes(b'not a signature')
            with mock.patch.object(fixture, 'run') as runner:
                with self.assertRaises(ValueError):
                    fixture.verify_tool(root, binary, signature, root / 'key', {})
                runner.assert_not_called()

    def test_non_ext4_parent_refuses_before_download(self):
        with tempfile.TemporaryDirectory() as directory:
            fs = subprocess.CompletedProcess([], 0, stdout='tmpfs\n')
            with mock.patch.object(fixture.subprocess, 'run', return_value=fs), mock.patch.object(fixture, 'fetch') as fetch:
                with self.assertRaises(ValueError):
                    fixture.fixture(Path(directory))
                fetch.assert_not_called()

    def test_source_checkout_refuses_before_download_or_evidence_creation(self):
        with mock.patch.object(fixture, 'fetch') as fetch, mock.patch.object(fixture.tempfile, 'mkdtemp') as create:
            with self.assertRaises(ValueError):
                fixture.fixture(ROOT)
            fetch.assert_not_called()
            create.assert_not_called()


@unittest.skipUnless(os.name == 'posix' and shutil.which('getfacl') and shutil.which('setfacl'), 'requires Linux ACL tools')
class ActualMetadataTests(unittest.TestCase):
    def setUp(self):
        mapping = Path('/proc/self/uid_map')
        if mapping.exists():
            ranges = [tuple(map(int, row.split())) for row in mapping.read_text().splitlines()]
            if not any(start <= 65534 < start + length for start, outside, length in ranges):
                self.skipTest('sandbox UID map cannot represent named ACL subject; approved native test required')
        fs = subprocess.run(['findmnt', '-n', '-o', 'FSTYPE', '-T', str(ROOT)], capture_output=True, text=True, check=True).stdout.strip()
        if fs != 'ext4':
            self.skipTest('actual ext4 observer coverage unavailable; no mount created')
        self.temp = tempfile.TemporaryDirectory(prefix='.borg-observer-test-', dir=ROOT)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = fixture.private_env(self.root)
        self.tree = self.root / 'source'
        fixture.make_source(self.tree, self.env)
        self.before = fixture.observe(self.tree, self.env)

    def test_real_links_sparse_acl_xattr_and_flags_are_observed(self):
        rows = {row['path']: row for row in self.before}
        self.assertEqual(rows['directory/payload']['hardlinkGroup'], ['directory/payload', 'hardlink'])
        self.assertEqual(rows['fifo']['type'], 'fifo')
        self.assertTrue(rows['sparse']['sparse'])
        self.assertEqual(rows['symlink']['linkTarget'], 'directory/payload')
        self.assertIn('user:65534:r--', rows['directory/payload']['acl'])
        self.assertIn('default:user:65534:r-x', rows['directory']['acl'])
        self.assertIn('user.revkit-fixture', rows['directory/payload']['xattrs'])
        self.assertTrue(rows['flags']['flags'] & fixture.NODUMP)
        fixture.compare(self.before, fixture.observe(self.tree, self.env))

    def test_actual_content_corruption_is_detected(self):
        path = self.tree / 'directory/payload'
        old = path.stat()
        path.write_bytes(b'changed data')
        os.utime(path, ns=(old.st_atime_ns, old.st_mtime_ns))
        with self.assertRaises(ValueError):
            fixture.compare(self.before, fixture.observe(self.tree, self.env))

    def test_actual_acl_xattr_mode_and_link_changes_are_detected(self):
        path = self.tree / 'directory/payload'
        for mutation in ('acl', 'xattr', 'mode', 'hardlink'):
            before = fixture.observe(self.tree, self.env)
            if mutation == 'acl':
                subprocess.run(['setfacl', '-m', 'u:65534:---', str(path)], check=True)
            elif mutation == 'xattr':
                os.setxattr(path, 'user.revkit-fixture', b'changed')
            elif mutation == 'mode':
                path.chmod(0o600)
            else:
                (self.tree / 'hardlink').unlink()
                shutil.copyfile(path, self.tree / 'hardlink')
            with self.assertRaises(ValueError):
                fixture.compare(before, fixture.observe(self.tree, self.env))

    def test_actual_path_and_timestamp_changes_are_detected(self):
        (self.tree / 'a').rename(self.tree / 'renamed')
        with self.assertRaises(ValueError):
            fixture.compare(self.before, fixture.observe(self.tree, self.env))
        (self.tree / 'renamed').rename(self.tree / 'a')
        before = fixture.observe(self.tree, self.env)
        os.utime(self.tree / 'A', ns=(1900000000123456789, 1700000000000000000))
        with self.assertRaises(ValueError):
            fixture.compare(before, fixture.observe(self.tree, self.env))


class PrivilegedBoundaryTests(unittest.TestCase):
    def test_default_root_refusal_and_explicit_nonroot_refusal_precede_writes(self):
        with mock.patch.object(fixture.os, 'geteuid', return_value=0), mock.patch.object(fixture.tempfile, 'mkdtemp') as create:
            with self.assertRaises(ValueError): fixture.fixture(Path('/tmp'))
            create.assert_not_called()
        with mock.patch.object(fixture.os, 'geteuid', return_value=1000), mock.patch.object(fixture.os, 'mknod') as node:
            with self.assertRaises(ValueError): fixture.privileged_workspace('/var/lib/revkit-synthetic-fixtures/00000000-0000-4000-8000-000000000001', '/tmp', 'a'*64)
            node.assert_not_called()

    def test_existing_empty_nonempty_and_symlink_workspaces_refuse(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory); leaf = base/'00000000-0000-4000-8000-000000000001'
            with mock.patch.object(fixture, 'PRIVILEGED_BASE', base), mock.patch.object(fixture.os, 'geteuid', return_value=0), mock.patch.object(fixture, 'require_root_custody') as custody:
                leaf.mkdir()
                for nonempty in (False, True):
                    if nonempty: (leaf/'preserve').write_text('original')
                    with self.assertRaises(ValueError): fixture.privileged_workspace(leaf, base, 'a'*64)
                (leaf/'preserve').unlink(); leaf.rmdir(); leaf.symlink_to(base/'absent')
                with self.assertRaises(ValueError): fixture.privileged_workspace(leaf, base, 'a'*64)
                custody.assert_not_called()

    def test_production_paths_and_writable_custody_refuse(self):
        with mock.patch.object(fixture.os, 'geteuid', return_value=0):
            for path in ('/mnt/e/backups/new', '/home/user/live', '/dev/sda', '/var/lib/revkit-synthetic-fixtures/../source'):
                with self.assertRaises(ValueError): fixture.privileged_workspace(path, '/tmp', 'a'*64)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError): fixture.require_root_custody(Path(directory))

    def test_missing_capabilities_are_explicit_incomplete_cases(self):
        import errno
        with tempfile.TemporaryDirectory() as directory:
            with mock.patch.object(fixture.os, 'chown', side_effect=PermissionError(errno.EPERM, 'unavailable')), mock.patch.object(fixture.os, 'mknod', side_effect=PermissionError(errno.EPERM, 'unavailable')), mock.patch.object(fixture.os, 'setxattr', side_effect=PermissionError(errno.EPERM, 'unavailable')), mock.patch.object(fixture.fcntl, 'ioctl', side_effect=PermissionError(errno.EPERM, 'unavailable')):
                cases = fixture.make_privileged_source(Path(directory))
            self.assertEqual(len(cases), 7)
            self.assertTrue(all(c['status']=='unavailable' for c in cases))
            self.assertFalse(fixture.privileged_complete([], cases))

    def test_device_observation_never_opens_or_hashes_nodes(self):
        import stat
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); device=root/'device';device.touch();original=Path.lstat
            def lstat(path, *args, **kwargs):
                s=original(path, *args, **kwargs)
                if path != device:return s
                return SimpleNamespace(st_mode=stat.S_IFCHR|0o600,st_uid=1000,st_gid=1000,st_rdev=0,st_dev=s.st_dev,st_ino=s.st_ino,st_nlink=1,st_mtime_ns=s.st_mtime_ns,st_atime_ns=s.st_atime_ns)
            with mock.patch.object(Path,'lstat',lstat), mock.patch.object(fixture,'flags',return_value=0), mock.patch.object(fixture,'run',return_value=subprocess.CompletedProcess([],0,stdout=b'')), mock.patch.object(fixture.os,'open',side_effect=AssertionError('device must not open')):
                rows=fixture.observe(root,{})
            self.assertEqual(rows[1]['type'],'character');self.assertIsNone(rows[1]['contentSha256'])

    def test_sparse_property_is_strict_but_allocation_amount_is_not_extent_identity(self):
        a=[{'path':'s','type':'file','size':8192,'sparse':True,'allocatedBytes':4096}]
        b=[dict(a[0],allocatedBytes=6144)]
        result=fixture.compare(a,b)
        self.assertEqual(result['logicalAllocationUpperBoundBytes'],8192)
        self.assertEqual(result['sparseCreditBytes'],0)
        self.assertEqual(result['allocationGrowthBytes'],2048)
        with self.assertRaises(ValueError):fixture.compare(a,[dict(a[0],sparse=False,allocatedBytes=8192)])

    def test_prepared_syscall_status_cannot_replace_observed_foreign_ids(self):
        names=('foreign-uid-gid','block-node','char-node','security.capability','trusted-xattr','immutable','append-only')
        cases=[{'case':name,'status':'prepared'} for name in names]
        with self.assertRaises(ValueError):
            fixture.privileged_complete([{'path':'foreign-owner','uid':0,'gid':0}],cases)

    def test_mount_manifest_refuses_even_fixed_synthetic_base(self):
        from types import SimpleNamespace
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory)/'base';base.mkdir(mode=0o700)
            tools=Path(directory)/'tools';sha='a'*64;bundle=tools/sha;bundle.mkdir(parents=True)
            script=bundle/'wsl-borg-fixture.py';script.touch()
            for name in ('borg',fixture.ASSET+'.asc','release-key.asc'):(bundle/name).touch()
            original=Path.read_text
            def read(path,*args,**kwargs):
                if str(path)=='/proc/self/uid_map':return '0 0 4294967295\n'
                if str(path)=='/proc/self/mountinfo':return '1 0 8:1 / '+str(base)+' rw - ext4 /dev/test rw\n'
                return original(path,*args,**kwargs)
            hashes={'wsl-borg-fixture.py':sha,'borg':fixture.SHA256,fixture.ASSET+'.asc':fixture.SIGNATURE_SHA256,'release-key.asc':fixture.PUBLIC_KEY_SHA256}
            leaf=base/'00000000-0000-4000-8000-000000000001'
            with mock.patch.object(fixture,'PRIVILEGED_BASE',base),mock.patch.object(fixture,'PRIVILEGED_TOOLS',tools),mock.patch.object(fixture,'__file__',str(script)),mock.patch.object(fixture.os,'geteuid',return_value=0),mock.patch.object(fixture.sys,'flags',SimpleNamespace(isolated=True)),mock.patch.object(fixture,'require_root_custody',side_effect=lambda p:Path(p)),mock.patch.object(fixture,'digest',side_effect=lambda p:hashes[Path(p).name]),mock.patch.object(Path,'read_text',read):
                with self.assertRaises(ValueError):fixture.privileged_workspace(leaf,bundle,sha)
            self.assertFalse(leaf.exists())

if __name__ == '__main__':
    unittest.main()

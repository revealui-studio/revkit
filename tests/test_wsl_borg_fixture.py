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


if __name__ == '__main__':
    unittest.main()

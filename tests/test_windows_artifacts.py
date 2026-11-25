import importlib.util
import io
import tarfile
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('windows_artifacts', Path(__file__).parents[1] / 'scripts/build-windows-artifacts.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class WindowsArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.policy = {'schemaVersion': 1, 'roots': ['scripts', 'powershell'],
                       'excludedParts': ['logs'], 'excludedLeaves': ['local-config.ps1'],
                       'required': ['scripts/windows-artifact-scope.json', 'powershell/maintained.ps1']}
        (self.source / 'scripts').mkdir()
        (self.source / 'powershell').mkdir()
        (self.source / 'scripts/windows-artifact-scope.json').write_text(json.dumps(self.policy))
        (self.source / 'powershell/maintained.ps1').write_text('maintained synthetic source')
        (self.source / 'powershell/local-config.ps1').write_text('owner-local data must not travel')
        self.dirty = False

    def run_git(self, args, **options):
        command = args[3]
        if command == 'diff':
            return SimpleNamespace(returncode=1 if self.dirty else 0, stdout=b'')
        if command == 'rev-parse':
            return SimpleNamespace(returncode=0, stdout=b'1' * 40 + b'\n')
        if command == 'archive':
            stream = io.BytesIO()
            with tarfile.open(fileobj=stream, mode='w:') as archive:
                for relative in ['scripts/windows-artifact-scope.json', 'powershell/maintained.ps1', 'powershell/local-config.ps1']:
                    path = self.source / relative
                    info = tarfile.TarInfo(relative)
                    data = path.read_bytes()
                    info.size = len(data)
                    archive.addfile(info, io.BytesIO(data))
            return SimpleNamespace(returncode=0, stdout=stream.getvalue())
        if command == 'ls-files':
            return SimpleNamespace(returncode=0, stdout=b'scripts/windows-artifact-scope.json\0powershell/maintained.ps1\0powershell/local-config.ps1\0')
        raise AssertionError(args)

    def test_packages_committed_source_with_hash_manifest_and_no_owner_local_code(self):
        destination = self.root / 'package'
        result = MODULE.package(self.source, destination, run=self.run_git)
        manifest = json.loads((destination / 'artifact-source-manifest.json').read_text())
        self.assertEqual(result['sourceCommit'], '1' * 40)
        self.assertEqual(result['files'], 2)
        self.assertEqual(len(result['manifestSha256']), 64)
        self.assertFalse((destination / 'powershell/local-config.ps1').exists())
        self.assertEqual(manifest['kind'], 'revealfleet-windows-artifact-source')

    def test_refuses_dirty_source_and_existing_output(self):
        destination = self.root / 'package'
        self.dirty = True
        with self.assertRaises(MODULE.ArtifactError):
            MODULE.package(self.source, destination, run=self.run_git)
        self.assertFalse(destination.exists())
        self.dirty = False
        destination.mkdir()
        (destination / 'owner.txt').write_text('preserve')
        with self.assertRaises(MODULE.ArtifactError):
            MODULE.package(self.source, destination, run=self.run_git)
        self.assertEqual((destination / 'owner.txt').read_text(), 'preserve')

    def test_refuses_symlink_escape_and_path_traversal(self):
        outside = self.root / 'outside'
        outside.write_text('outside user data')
        (self.source / 'powershell/maintained.ps1').unlink()
        (self.source / 'powershell/maintained.ps1').symlink_to(outside)
        with self.assertRaises(MODULE.ArtifactError):
            MODULE.package(self.source, self.root / 'package', run=self.run_git)
        for path in ['../escape', 'scripts/../../escape', 'scripts/data\\..\\escape', '/absolute', 'scripts/C:drive']:
            self.assertFalse(MODULE.is_selected(path, self.policy))

    def test_atomic_publish_never_replaces_a_destination_created_after_preflight(self):
        staging = self.root / 'staging'
        staging.mkdir()
        (staging / 'source.txt').write_text('staged')
        destination = self.root / 'package'
        destination.mkdir()
        with self.assertRaises(OSError):
            MODULE.publish_no_replace(staging, destination)
        self.assertTrue(staging.exists())
        self.assertEqual(list(destination.iterdir()), [])

    def test_unsupported_destination_refuses_before_reading_git_or_staging_code(self):
        destination = self.root / 'package'
        with patch.object(MODULE, 'publish_no_replace', side_effect=OSError(22, 'unsupported')):
            with self.assertRaises(MODULE.ArtifactError) as caught:
                MODULE.package(self.source, destination, run=lambda *a, **k: self.fail('Git must not run'))
        self.assertIn('errno 22', str(caught.exception))
        self.assertFalse(destination.exists())
        self.assertFalse(any(self.root.glob('.revkit-publish-probe-*')))


if __name__ == '__main__':
    unittest.main()

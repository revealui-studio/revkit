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
            for path in ('/srv/backup-source/new', '/srv/user-data/live', '/dev/sda', '/var/lib/revkit-synthetic-fixtures/../source'):
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

class RecoveryBoundaryTests(unittest.TestCase):
    def test_recovery_refuses_root_and_checkout_before_tool_or_secret_creation(self):
        for root in (True, False):
            with mock.patch.object(fixture.os, 'geteuid', return_value=0 if root else 1000), \
                 mock.patch.object(fixture, 'prepare_tool') as tool, \
                 mock.patch.object(fixture, 'private_secret') as secret:
                with self.assertRaises(ValueError): fixture.recovery_fixture(ROOT, None)
                tool.assert_not_called()
                secret.assert_not_called()

    def test_passphrase_never_enters_environment_and_output_is_redacted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            phrase = root / 'passphrase'
            fixture.private_secret(phrase, b'synthetic-test-secret\n')
            def backend(command, **kwargs):
                self.assertNotIn('BORG_PASSPHRASE', kwargs['env'])
                self.assertEqual(os.read(kwargs['pass_fds'][0], 100), b'synthetic-test-secret\n')
                self.assertEqual(kwargs['env']['BORG_PASSPHRASE_FD'], str(kwargs['pass_fds'][0]))
                return subprocess.CompletedProcess(command, 44, stdout=b'synthetic-test-secret', stderr=b'synthetic-test-secret')
            with mock.patch.object(fixture.subprocess, 'run', side_effect=backend):
                with self.assertRaises(RuntimeError) as caught:
                    fixture.recovery_borg('/synthetic/borg', ['list'], cwd=root, env={}, passphrase=phrase)
                self.assertNotIn('secret', str(caught.exception))
                result = fixture.recovery_borg('/synthetic/borg', ['list'], cwd=root, env={}, passphrase=phrase, expected_exit=44)
                self.assertNotIn('secret', str(result))
            with mock.patch.object(fixture.subprocess, 'run') as run:
                with self.assertRaises(ValueError):
                    fixture.recovery_borg('/synthetic/borg', [], cwd=root, env={'BORG_PASSCOMMAND': 'anything'}, passphrase=phrase)
                phrase.chmod(0o644)
                with self.assertRaises(ValueError):
                    fixture.recovery_borg('/synthetic/borg', [], cwd=root, env={}, passphrase=phrase)
                run.assert_not_called()

    def test_synthetic_key_loss_requires_export_and_preserves_other_config(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repo = root / 'repository'
            repo.mkdir()
            key = root / 'recovery-artifacts/exported-key'
            key.parent.mkdir()
            config = repo / 'config'
            config.write_text('[repository]\nversion = 1\nid = synthetic-id\nkey = synthetic-encrypted-key\n')
            with self.assertRaises(ValueError): fixture.remove_synthetic_key(root, repo, key)
            self.assertIn('key =', config.read_text())
            key.write_text('synthetic-export')
            (repo / 'lock.exclusive').mkdir()
            with self.assertRaises(ValueError): fixture.remove_synthetic_key(root, repo, key)
            (repo / 'lock.exclusive').rmdir()
            fixture.remove_synthetic_key(root, repo, key)
            parsed = fixture.configparser.ConfigParser()
            parsed.read(config)
            self.assertFalse(parsed.has_option('repository', 'key'))
            self.assertEqual(parsed['repository']['id'], 'synthetic-id')
            self.assertEqual(key.read_text(), 'synthetic-export')
            with self.assertRaises(ValueError): fixture.remove_synthetic_key(root, repo, key)

    def test_negative_control_must_actually_reject(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            phrase = root / 'passphrase'
            fixture.private_secret(phrase, b'synthetic\n')
            with mock.patch.object(fixture.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, b'', b'')):
                with self.assertRaises(RuntimeError):
                    fixture.recovery_borg('/synthetic/borg', [], cwd=root, env={}, passphrase=phrase, expected_exit=44)

    def test_real_sparse_matrix_reports_small_hole_loss_without_relaxing_content(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as directory:
            root = Path(directory)
            env = fixture.private_env(root)
            tree = root / 'source'
            fixture.make_sparse_matrix(tree)
            before = fixture.observe(tree, env)
            after = [dict(row) for row in before]
            small = next(row for row in after if row['path'] == 'retained-shape-8MiB')
            self.assertTrue(small['sparse'])
            small.update(sparse=False, allocatedBytes=small['size']+4096)
            report = fixture.sparse_assessment(before, after)
            self.assertFalse(report['accepted'])
            self.assertEqual(report['sparseCreditBytes'], 0)
            self.assertIn('sparse', report['reason'])
            small['sparse'] = True
            small['contentSha256'] = 'corrupt'
            self.assertFalse(fixture.sparse_assessment(before, after)['accepted'])


class CandidateProfileTests(unittest.TestCase):
    def test_legacy_receipts_and_missing_privilege_cannot_be_combined_acceptance(self):
        old = [{'path': 'old-only', 'type': 'file', 'size': 8, 'sparse': False, 'allocatedBytes': 4096}]
        report = fixture.candidate_assessment(old, old, [], False)
        self.assertTrue(report['strictInventory']['accepted'])
        self.assertFalse(report['layoutDatasetComplete'])
        self.assertFalse(report['combinedCandidateAccepted'])
        with self.assertRaises(ValueError): fixture.fixture(ROOT, profile='unreviewed')
        with mock.patch.object(fixture.os, 'geteuid', return_value=0), mock.patch.object(fixture, 'prepare_tool') as tool:
            with self.assertRaises(ValueError): fixture.fixture(ROOT, profile=fixture.CANDIDATE_PROFILE)
            tool.assert_not_called()

    def test_candidate_controller_plan_never_executes_or_creates_workspace(self):
        import contextlib
        import io
        import json
        output = io.StringIO()
        with mock.patch.object(fixture.sys, 'argv', ['fixture', '--privileged-plan', '--profile', fixture.CANDIDATE_PROFILE]), \
             mock.patch.object(fixture, 'fixture') as execute, \
             mock.patch.object(fixture, 'privileged_workspace') as create, contextlib.redirect_stdout(output):
            fixture.main()
        plan = json.loads(output.getvalue())
        self.assertEqual(plan['archiveProfile']['id'], fixture.CANDIDATE_PROFILE)
        argv = plan['controllerArgv']
        self.assertEqual(argv[argv.index('--profile')+1], fixture.CANDIDATE_PROFILE)
        self.assertEqual(plan['sourceSha256'], fixture.digest(Path(fixture.__file__)))
        self.assertEqual(Path(plan['workspaceMustBeNew']).parent, fixture.PRIVILEGED_BASE)
        self.assertFalse(plan['productionExecutionAllowed'])
        execute.assert_not_called()
        create.assert_not_called()

    def test_old_encrypted_protocol_cannot_be_silently_relabelled_candidate(self):
        import contextlib
        import io
        with mock.patch.object(fixture.sys, 'argv', ['fixture', '--run-recovery', '--parent', str(ROOT), '--profile', fixture.CANDIDATE_PROFILE]), \
             mock.patch.object(fixture, 'recovery_fixture') as execute, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as caught: fixture.main()
            self.assertEqual(caught.exception.code, 2)
            execute.assert_not_called()

    def test_dense_to_sparse_is_rejected_as_well_as_sparse_to_dense(self):
        dense = [{'path': 'dense-zero', 'type': 'file', 'size': 65536, 'sparse': False, 'allocatedBytes': 65536}]
        sparse = [dict(dense[0], sparse=True, allocatedBytes=0)]
        self.assertFalse(fixture.sparse_assessment(dense, sparse)['accepted'])
        self.assertFalse(fixture.sparse_assessment(sparse, dense)['accepted'])
        with self.assertRaises(ValueError): fixture.compare(dense, sparse)

    def test_range_observer_never_opens_block_or_character_entries(self):
        rows = [{'path': 'block-node', 'type': 'block'}, {'path': 'char-node', 'type': 'character'}]
        with mock.patch.object(fixture.os, 'open', side_effect=AssertionError('must never open a device')):
            self.assertEqual(fixture.observed_ranges(Path('/synthetic-only'), rows), {})

    def test_old_privileged_inventory_cannot_be_promoted_without_candidate_layouts(self):
        paths = {'foreign-uid-gid': 'foreign-owner', 'block-node': 'block-node',
                 'char-node': 'char-node', 'security.capability': 'capability-data',
                 'trusted-xattr': 'capability-data', 'immutable': 'immutable', 'append-only': 'append-only'}
        cases = [{'case': name, 'status': 'prepared'} for name in paths]
        rows = [{'path': path, 'type': 'file', 'size': 1, 'allocatedBytes': 4096, 'sparse': False}
                for path in sorted(set(paths.values()))]
        # Model admission only; never privileged execution or actual metadata proof.
        with mock.patch.object(fixture, 'privileged_complete', return_value=True):
            report = fixture.candidate_assessment(rows, rows, cases, True)
        self.assertTrue(report['privilegedMetadataVerified'])
        self.assertFalse(report['layoutDatasetComplete'])
        self.assertFalse(report['combinedCandidateAccepted'])

    def test_cost_uses_file_and_range_boundaries_not_aggregate_average(self):
        entries = [{'path': 'one', 'type': 'file', 'size': 65536},
                   {'path': 'two', 'type': 'file', 'size': 1}]
        ranges = {'one': [{'offset': 0, 'bytes': 32768, 'data': True},
                          {'offset': 32768, 'bytes': 32768, 'data': False}],
                  'two': [{'offset': 0, 'bytes': 1, 'data': True}]}
        cost = fixture.candidate_cost(entries, ranges)
        self.assertEqual(cost['fixedDataChunkReferencesNoReuseModel'], 3)
        self.assertEqual(cost['logicalDataBytes'], 65537)
        self.assertEqual(cost['indexAndChunksCacheBaseSensitivityBytes'], 252)
        self.assertEqual(cost['indexAndChunksCacheGrowthSensitivityBytes'], 3024)
        self.assertFalse(cost['productionBudgetAccepted'])
        self.assertFalse(cost['fullSourceCensus'])
        self.assertEqual(cost['sparseCreditBytes'], 0)

    def test_missing_incomplete_overlapping_and_oversize_census_refuses(self):
        rows = [{'path': 's', 'type': 'file', 'size': 10}]
        for ranges in ({}, {'s': []}, {'s': [{'offset': 1, 'bytes': 10, 'data': True}]},
                       {'s': [{'offset': 0, 'bytes': 11, 'data': False}]},
                       {'s': [{'offset': 0, 'bytes': True, 'data': True}]}):
            with self.assertRaises(ValueError): fixture.candidate_cost(rows, ranges)
        size = fixture.CANDIDATE_LOGICAL_LIMIT + 1
        with self.assertRaises(ValueError):
            fixture.candidate_cost([dict(rows[0], size=size)], {'s': [{'offset': 0, 'bytes': size, 'data': False}]})

    def test_actual_dense_empty_hole_and_short_gap_preconditions_and_cost(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as directory:
            root = Path(directory)
            env = fixture.private_env(root)
            tree = root / 'source'
            tree.mkdir()
            fixture.make_candidate_layouts(tree / 'layouts')
            before = fixture.observe(tree, env)
            ranges = fixture.observed_ranges(tree, before)
            fixture.candidate_preconditions(before, ranges)
            cost = fixture.candidate_cost(before, ranges)
            self.assertLess(cost['logicalDataBytes'], fixture.CANDIDATE_LOGICAL_LIMIT)
            by_path = {row['path']: row for row in before}
            self.assertEqual(ranges['layouts/empty'], [])
            self.assertFalse(by_path['layouts/dense-zero']['sparse'])
            self.assertTrue(by_path['layouts/all-hole']['sparse'])
            self.assertTrue(all(part['data'] for part in ranges['layouts/dense-zero']))
            damaged = [dict(row) for row in before]
            next(row for row in damaged if row['path'] == 'layouts/dense-zero')['sparse'] = True
            with self.assertRaises(ValueError): fixture.candidate_preconditions(damaged, ranges)


class ContainerBinaryTests(unittest.TestCase):
    def transact(self, code, data, expected_input=None, expected_output=None, sha=None, timeout=5):
        import io
        import hashlib
        import sys
        target = io.BytesIO()
        with tempfile.TemporaryDirectory() as directory:
            status = fixture.binary_transaction([sys.executable, '-I', '-c', code], cwd=directory,
                env={'PATH': '/usr/bin:/bin'}, source=io.BytesIO(data), target=target,
                expected_input=len(data) if expected_input is None else expected_input,
                expected_output=len(data) if expected_output is None else expected_output,
                expected_output_sha256=hashlib.sha256(data).hexdigest() if sha is None else sha, timeout=timeout)
        return status, target.getvalue()

    def test_binary_nontext_echo_and_simultaneous_output_before_input(self):
        import hashlib
        data = bytes(range(256))*1024+b'\x00\xff\n'
        prefix = bytes(1024*1024)
        code = 'import sys;sys.stdout.buffer.write(bytes(1024*1024));sys.stdout.buffer.flush();sys.stdout.buffer.write(sys.stdin.buffer.read())'
        result, output = self.transact(code, data, expected_output=len(prefix)+len(data),
                                      sha=hashlib.sha256(prefix+data).hexdigest())
        self.assertEqual(output, prefix+data)
        self.assertEqual(result['inputSha256'], hashlib.sha256(data).hexdigest())

    def test_zero_exit_truncation_extra_bytes_corruption_diagnostics_and_failure_refuse(self):
        data = bytes(range(256))*1024
        for code in (
            'import sys;d=sys.stdin.buffer.read();sys.stdout.buffer.write(d[:len(d)//2])',
            'import sys;d=sys.stdin.buffer.read();sys.stdout.buffer.write(d+b"x")',
            'import sys;d=sys.stdin.buffer.read();sys.stdout.buffer.write(bytes(len(d)))',
            'import sys;d=sys.stdin.buffer.read();sys.stdout.buffer.write(d);sys.stderr.write("synthetic diagnostic")',
            'import sys;sys.stderr.buffer.write(bytes(131072));sys.stderr.buffer.flush()',
            'import sys;sys.exit(7)'):
            with self.assertRaises(RuntimeError) as caught: self.transact(code, data)
            self.assertNotIn('synthetic diagnostic', str(caught.exception))
        with self.assertRaises(RuntimeError):
            self.transact('import sys;sys.stdin.buffer.read()', data, expected_input=len(data)+1, expected_output=0)

    def test_timeout_cancels_child_instead_of_accepting_a_partial_stream(self):
        with self.assertRaises(RuntimeError): self.transact('import time;time.sleep(30)', b'', timeout=.1)

    def test_container_cannot_run_as_root_or_reinterpret_filesystem_profile(self):
        with mock.patch.object(fixture.os, 'geteuid', return_value=0), mock.patch.object(fixture, 'prepare_tool') as tool:
            with self.assertRaises(ValueError):fixture.container_fixture(ROOT, None)
            tool.assert_not_called()


if __name__ == '__main__':
    unittest.main()

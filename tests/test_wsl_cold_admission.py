"""Pure admission boundaries and real ephemeral SSH signatures, no root operations."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
SPEC=importlib.util.spec_from_file_location('admission',ROOT/'scripts/lib/wsl_cold_admission.py')
a=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(a)


def policy():
    return dict(schemaVersion=1,profile='cold-vhd-container-v1',sourceCommit='a'*40,expiresAt=int(time.time())+600,
        operation='backup',transactionId='11111111-1111-4111-8111-111111111111',archiveId='11111111-1111-4111-8111-111111111111',
        keyCustody='keyfile-blake2-independent-v1',
        controller=dict(packageManifestSha256='b'*64,files={},journalDirectory='X:\\private',
            source=dict(distro='source',registrationId='22222222-2222-4222-8222-222222222222',vhdx='X:\\source.vhdx',fileIdentity='synthetic',containerBytes=1024,hardware={}),
            protected=dict(distro='protected',registrationId='33333333-3333-4333-8333-333333333333',vhdx='X:\\protected.vhdx',hardware={}),
            workerVhdx=dict(path='X:\\worker.vhdx',hardware={}),restore=dict(path='X:\\restore.vhdx',hardware={},overheadBytes=1024,hardwareGuarantee='isolated-restore-test',archiveReceiptSha256='',nativeArchiveId='',imageBytes=1024)),
        worker=dict(registrationId='44444444-4444-4444-8444-444444444444',distro='worker',machineId='machine',kernelBootId='kernel',controlBudget=dict(bootInitMilliseconds=60000,launchAllowanceMilliseconds=30000,operationMilliseconds=15000,reconciliationMilliseconds=30000,frontendTeardownMilliseconds=5000),
            interpreter='/usr/bin/python3.14',interpreterSha256='c'*64,files={},borg='/opt/revkit/borg',borgSha256=a.BORG_SHA,state='/var/lib/revkit-cold'),
        repository=dict(path='/synthetic/mount/repository',id='d'*64,mountPath='/synthetic/mount',fsUuid='55555555-5555-4555-8555-555555555555',partitionUuid='66666666-6666-4666-8666-666666666666',deviceSerial='test',deviceModel='synthetic USB',deviceBytes=4096,partitionBytes=2048,partitionOffsetBytes=512,filesystemLabel='synthetic'),
        budget=dict(repositoryAdditionalBytes=2048,workspaceAdditionalBytes=1024,reserveBytes=64*1024**3,timeoutSeconds=120),
        acceptance=dict(windowsReceiptSha256='e'*64,selectedWorkerReceiptSha256='f'*64,custodyReceiptSha256='a'*64,capacityReceiptSha256='b'*64))


class AdmissionTests(unittest.TestCase):
    def test_exact_signed_operation_and_no_savings(self):
        self.assertEqual(a.validate(policy())['operation'],'backup')
        for mutate in (lambda p:p.update(schemaVersion=True),lambda p:p.update(expiresAt=1),
                       lambda p:p.update(keyCustody='repokey-blake2'),
                       lambda p:p['worker'].update(registrationId=p['controller']['source']['registrationId']),
                       lambda p:p['budget'].update(repositoryAdditionalBytes=1023),
                       lambda p:p['budget'].update(reserveBytes=0),
                       lambda p:p['acceptance'].update(windowsReceiptSha256=True),
                       lambda p:p.update(testMode=True)):
            p=policy(); mutate(p)
            with self.assertRaises((a.AdmissionError,ValueError)): a.validate(p)

    def test_signed_prepare_does_not_require_future_acceptance_or_create_a_repo(self):
        p=policy();p['operation']='prepare';p['repository']['id']=''
        p['acceptance']={key:'' for key in p['acceptance']}
        self.assertEqual(a.validate(p)['operation'],'prepare')
        # The SAME document cannot admit backup by switching a bool or wire flag.
        p['operation']='backup'
        with self.assertRaises(a.AdmissionError):a.validate(p)

    def test_duplicate_nonfinite_and_oversized_policy_refused(self):
        for value in (b'{"x":1,"x":2}',b'{"x":NaN}',b'[]',b'x'*1048577):
            with self.assertRaises(a.AdmissionError): a.bounded_json(value)

    def test_actual_user_writable_source_cannot_be_immutable_root_code(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'code';path.write_bytes(b'not admitted')
            with self.assertRaises(a.AdmissionError):a.protected(path)
        with mock.patch.object(a.os,'geteuid',return_value=1000),mock.patch.object(a,'command') as command:
            with self.assertRaises(a.AdmissionError):a.load()
            command.assert_not_called()

    def test_shared_filesystem_capacity_aggregates_and_refuses(self):
        p=policy()
        fs=mock.Mock(f_bavail=64*1024**3+2500,f_frsize=1)
        with mock.patch.object(a.os,'stat',return_value=mock.Mock(st_dev=7)),mock.patch.object(a.os,'statvfs',return_value=fs):
            with self.assertRaises(a.AdmissionError):a.capacity(p)
            fs.f_bavail+=1000
            result=a.capacity(p)
            self.assertEqual(result[7][1],64*1024**3+3072)

    def test_real_detached_signature_rejects_tampered_policy_and_wrong_signer(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);key=root/'ephemeral-test-key';document=root/'policy.json'
            subprocess.run(['/usr/bin/ssh-keygen','-q','-t','ed25519','-N','','-f',str(key)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
            raw=json.dumps(policy(),sort_keys=True).encode(); document.write_bytes(raw)
            subprocess.run(['/usr/bin/ssh-keygen','-Y','sign','-f',str(key),'-n',a.NAMESPACE,str(document)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
            signers=root/'allowed_signers';signers.write_text('revkit-owner '+(root/'ephemeral-test-key.pub').read_text())
            argv=['/usr/bin/ssh-keygen','-Y','verify','-f',str(signers),'-I','revkit-owner','-n',a.NAMESPACE,'-s',str(document)+'.sig']
            a.command(argv,data=raw)
            with self.assertRaises(a.AdmissionError):a.command(argv,data=raw+b' ')
            with self.assertRaises(a.AdmissionError):a.command([*argv[:6],'wrong-owner',*argv[7:]],data=raw)
            # Synthetic signing key remains only in this private test directory.
            # It never becomes a trust anchor or production credential.

    def test_kernel_cancel_tombstone_precedes_stop_and_live_group_refuses(self):
        p=policy()
        with tempfile.TemporaryDirectory() as directory:
            state=Path(directory);p['worker']['state']=str(state)
            tx=p['transactionId']
            original=Path
            # Actual private tombstone I/O; manager/kernel observations are mocked.
            with mock.patch.object(a,'protected',side_effect=lambda value,**kwargs:original(value)),mock.patch.object(a.subprocess,'run') as stop,mock.patch.object(a,'kernel_group_empty',return_value=True) as empty:
                def observe(*args,**kwargs):
                    self.assertTrue((state/('cancel-'+tx+'.json')).exists())
                    return subprocess.CompletedProcess(args[0],1,stdout=b'LoadState=not-found\n',stderr=b'')
                stop.side_effect=observe
                result=a.reconcile(p,'a'*64,tx)
                self.assertTrue(result['futureLaunchCancelled']);self.assertTrue(result['linuxUnitEmpty'])
                stop.assert_called_once()
                empty.return_value=False
                with self.assertRaises(a.AdmissionError):a.reconcile(p,'a'*64,tx)
                stop.side_effect=PermissionError('denied')
                with self.assertRaises(PermissionError):a.reconcile(p,'a'*64,tx)

    def test_kernel_permission_failure_is_not_absence(self):
        with mock.patch.object(Path,'read_text',side_effect=PermissionError('denied')):
            with self.assertRaises(PermissionError):a.kernel_group_empty(Path('/not-a-real-job'))

    def test_cancel_marker_permission_failure_is_not_absence(self):
        with mock.patch.object(Path,'lstat',side_effect=PermissionError('denied')):
            with self.assertRaises(PermissionError):a.cancellation_present(Path('/not-a-real-marker'))

    def test_parent_absence_does_not_override_actual_unit_descendants(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'cgroup.procs').write_text(str(os.getpid())+'\n999999\n');(root/'cgroup.stat').write_text('nr_descendants 0\n')
            deployment=object.__new__(a.Deployment);deployment.control_group=root
            with self.assertRaises(a.AdmissionError):deployment.children_absent()
            (root/'cgroup.procs').write_text(str(os.getpid())+'\n');deployment.children_absent()
            (root/'cgroup.stat').write_text('nr_descendants 1\n')
            with self.assertRaises(a.AdmissionError):deployment.children_absent()

class RepositoryCorrelationTests(unittest.TestCase):
    def test_exact_guest_mount_and_kernel_continuity_detect_rebind_without_usb_serial(self):
        p=policy();repo=p['repository'];device=os.makedev(8,17);disk=os.makedev(8,16)
        observed={'mountState':'MOUNTED','diskPath':'/dev/ephemeral','partitionPath':'/dev/ephemeral1','serial':repo['deviceSerial']}
        row={'fstype':'ext4','target':repo['mountPath'],'source':'/dev/ephemeral1','uuid':repo['fsUuid'],'partuuid':repo['partitionUuid'],'maj:min':'8:17','id':42,'fsroot':'/'}
        def info(path,*args,**kwargs):
            if str(path)=='/dev/ephemeral':return mock.Mock(st_mode=0o060000,st_rdev=disk,st_ino=100)
            if str(path)=='/dev/ephemeral1':return mock.Mock(st_mode=0o060000,st_rdev=device,st_ino=101)
            return mock.Mock(st_dev=device,st_ino=102)
        with mock.patch.object(a,'disk_probe',return_value=observed) as probe,mock.patch.object(a,'command',side_effect=lambda *args,**kw:json.dumps({'filesystems':[row]}).encode()),mock.patch.object(a.os,'stat',side_effect=info),mock.patch.object(Path,'read_text',return_value='10\n') as sequence:
            baseline=a.filesystem_observation(p,Path(repo['path']))
            self.assertEqual(probe.call_args.args[0]['serial'],repo['deviceSerial'])
            self.assertEqual(baseline[6:8],(10,42))
            sequence.return_value='11\n'
            self.assertNotEqual(baseline,a.filesystem_observation(p,Path(repo['path'])))
            sequence.return_value='10\n';row['id']=43
            self.assertNotEqual(baseline,a.filesystem_observation(p,Path(repo['path'])))
            for field,value in [('uuid','wrong'),('partuuid','wrong'),('source','/dev/absent'),('maj:min','8:18'),('fsroot','/bind-subdir')]:
                prior=row[field];row[field]=value
                with self.subTest(field=field),self.assertRaises(a.AdmissionError):a.filesystem_observation(p,Path(repo['path']))
                row[field]=prior
            observed['mountState']='NOT_MOUNTED'
            with self.assertRaises(a.AdmissionError):a.filesystem_observation(p,Path(repo['path']))
            observed['mountState']='MOUNTED';sequence.side_effect=FileNotFoundError('detached')
            with self.assertRaises(FileNotFoundError):a.filesystem_observation(p,Path(repo['path']))

    def test_continuity_drift_refuses_in_existing_transaction_check(self):
        deployment=object.__new__(a.Deployment);deployment.policy=policy();deployment.observation=('original',)
        with mock.patch.object(a,'repository_observation',return_value=('rebound',)),mock.patch.object(deployment,'reserve') as reserve:
            with self.assertRaises(a.AdmissionError):deployment.check()
            reserve.assert_not_called()

class ColdControlBudgetTests(unittest.TestCase):
    def test_explicit_startup_plus_work_contract_refuses_bad_types_or_unbounded_values(self):
        p=policy();self.assertEqual(a.control_budget(p['worker']['controlBudget'])['bootInitMilliseconds'],60000)
        for key,value in [('bootInitMilliseconds',9999),('launchAllowanceMilliseconds',True),('operationMilliseconds',60001),('reconciliationMilliseconds',0),('frontendTeardownMilliseconds',10001)]:
            changed=copy.deepcopy(p);changed['worker']['controlBudget'][key]=value
            with self.subTest(key=key),self.assertRaises(a.AdmissionError):a.validate(changed)
        a.verify_boot_contract(p,b'[boot]\nsystemd=true\ninitTimeout=60000\n[user]\ndefault=fixture\n')
        for data in (b'[boot]\nsystemd=true\n',b'[boot]\nsystemd=false\ninitTimeout=60000\n'):
            with self.assertRaises(a.AdmissionError):a.verify_boot_contract(p,data)
        # Kernel session only; a removed per-distro-named field cannot silently
        # adopt the new signed schema.
        p['worker']['bootId']=p['worker'].pop('kernelBootId')
        with self.assertRaises(a.AdmissionError):a.validate(p)

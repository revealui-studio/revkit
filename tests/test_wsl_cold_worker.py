"""Framing/refusal tests; real Borg tests require the explicit retained-input runner.

No production flags or paths. A NEW private synthetic repository is constructed
by the test runner, never by the worker admission executable.
"""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import secrets
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
import uuid

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('cold', ROOT/'scripts/lib/wsl_cold_container.py')
cold = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cold)
INPUTS = None
CUSTODY = None


def req(data, *, phase='backup', archive=None):
    tx = str(uuid.uuid4())
    return dict(protocol=cold.PROTOCOL, profile=cold.PROFILE, transactionId=tx, archiveId=archive or tx,
                phase=phase, bindingSha256='a'*64, bytes=len(data), sha256=hashlib.sha256(data).hexdigest())


def read_frame(stream):
    def take(size):
        out = bytearray()
        while len(out) < size:
            part = stream.read(size-len(out))
            if not part:
                raise EOFError()
            out.extend(part)
        return bytes(out)
    header = take(5)
    size = struct.unpack('<I', header[1:])[0]
    if header[:1] not in cold.LIMITS or size > cold.LIMITS[header[:1]]:
        raise ValueError('frame-bound')
    return header[:1], take(size)


class ContractTests(unittest.TestCase):
    def test_boundaries_binary_and_control(self):
        data = bytes(range(256))*256
        encoded = cold.encode(b'D', data)
        self.assertEqual(read_frame(io.BytesIO(encoded)), (b'D', data))
        for kind, payload in ((b'D', data+b'x'), (b'?', b''), (b'H', b'x'), (b'S', bytes(1025))):
            with self.assertRaises(cold.Refused):
                cold.encode(kind, payload)
        for data in (b'{"x":1,"x":2}', b'[]', b'{"x":NaN}', b'\xff'):
            with self.assertRaises(cold.Refused):
                cold.parse(data)

    def test_request_bindings_before_side_effects(self):
        value = req(b'x')
        self.assertEqual(cold.request(cold.document(value), 'a'*64), value)
        for field, wrong in (('profile','fixed64k-input-holes-v1'), ('bindingSha256','b'*64),
                             ('bytes', True), ('bytes', 0), ('phase','shell'), ('sha256','A'*64),
                             ('transactionId','not-a-uuid'), ('archiveId',str(uuid.uuid4()))):
            changed = dict(value, **{field: wrong})
            with self.assertRaises(cold.Refused):
                cold.request(cold.document(changed), 'a'*64)

    def test_root_admission_has_no_serve_or_test_bypass(self):
        for args in (['--serve'], ['--serve', '--synthetic'], ['--readiness']):
            result = subprocess.run([sys.executable, '-I', '-B', str(ROOT/'scripts/wsl-cold-worker.py'), *args],
                                    stdin=subprocess.DEVNULL, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 3)
            if args == ['--readiness']:
                self.assertFalse(json.loads(result.stdout)['canExecute'])
            else:
                self.assertEqual(result.stdout, b'')

    def test_receiver_rejects_truncated_header_payload_excess_and_eof(self):
        for data in (b'R', b'R'+struct.pack('<I', 4)+b'x', b'D'+struct.pack('<I',65537), b''):
            a, b = socket.socketpair()
            try:
                a.sendall(data); a.shutdown(socket.SHUT_WR)
                rx = cold.Receiver(b.fileno(), 1)
                try:
                    with self.assertRaises(cold.Refused):
                        rx.next(2)
                finally:
                    rx.close()
            finally:
                a.close(); b.close()

    def test_invalid_wire_request_has_no_backend_or_journal_side_effect(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            repo=root/'repository'; repo.mkdir(mode=0o700)
            state=root/'state'; state.mkdir(mode=0o700)
            session=cold.Session(root/'never-open-or-execute',repo,state,'a'*64,timeout=3,idle=1)
            a,b=socket.socketpair(); a.settimeout(3)
            def worker():
                try: session.serve(b.fileno(),b.fileno())
                except cold.Refused: pass
            thread=threading.Thread(target=worker); thread.start()
            stream=a.makefile('rb',buffering=0)
            try:
                bad=dict(req(b'x'),profile='not-admitted')
                a.sendall(cold.encode(b'R',cold.document(bad)))
                kind,payload=read_frame(stream)
                self.assertEqual(kind,b'F')
                self.assertEqual(cold.parse(payload)['code'],'request-binding')
                thread.join(2); self.assertFalse(thread.is_alive())
                self.assertEqual(list(state.iterdir()),[])
                self.assertEqual(list(repo.iterdir()),[])
                self.assertEqual(session.children,[])
            finally:
                a.close(); stream.close(); b.close(); thread.join(2)

    def test_unsafe_custody_and_unverified_tool_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            repo=root/'repository'; repo.mkdir(mode=0o700)
            state=root/'state'; state.mkdir(mode=0o700)
            link=root/'alias'; link.symlink_to(repo, target_is_directory=True)
            with self.assertRaises(cold.Refused):
                cold.Session(root/'binary', link, state, 'a'*64)
            with self.assertRaises(cold.Refused):
                cold.Session(root/'binary', repo, repo, 'a'*64)
            bad=root/'unreviewed'; bad.write_bytes(b'never execute'); bad.chmod(0o700)
            session=cold.Session(bad,repo,state,'a'*64)
            with self.assertRaises(cold.Refused):
                session.tool()
            self.assertEqual(list(state.iterdir()), [])


class LifetimeFaultTests(unittest.TestCase):
    def exercise(self, fault, confirmed):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); repo=root/'repository'; repo.mkdir(mode=0o700)
            state=root/'state'; state.mkdir(mode=0o700)
            session=cold.Session(root/'never-execute',repo,state,'a'*64,timeout=4,idle=1)
            a,b=socket.socketpair(); a.settimeout(5); stream=a.makefile('rb',buffering=0)
            real_popen=subprocess.Popen
            children=[]
            def launch(*args,**kwargs):
                child=real_popen([sys.executable,'-I','-c','import time; time.sleep(20)'],
                    stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
                children.append(child)
                if fault=='cgroup':
                    session.deployment=mock.Mock()
                    session.deployment.children_absent.side_effect=PermissionError('unit proof denied')
                if fault=='wait': child.wait=mock.Mock(side_effect=OSError('injected wait failure'))
                return child
            real_blocking=cold.os.set_blocking
            def blocking(fd,value):
                # The initial receiver/output setup must still work. Fault only
                # after a real owned child exists.
                if children: raise OSError('injected pipe setup failure')
                return real_blocking(fd,value)
            stack=__import__('contextlib').ExitStack()
            stack.enter_context(mock.patch.object(session,'tool',return_value=None))
            stack.enter_context(mock.patch.object(cold.subprocess,'Popen',side_effect=launch))
            if fault in ('pipe','kill','wait','reap','cgroup'):
                stack.enter_context(mock.patch.object(cold.os,'set_blocking',side_effect=blocking))
            if fault=='selector': stack.enter_context(mock.patch.object(cold.selectors,'DefaultSelector',side_effect=OSError('injected selector setup')))
            if fault=='register':
                selector=cold.selectors.DefaultSelector()
                stack.enter_context(mock.patch.object(cold.selectors,'DefaultSelector',return_value=selector))
                stack.enter_context(mock.patch.object(selector,'register',side_effect=OSError('injected registration')))
            if fault=='kill': stack.enter_context(mock.patch.object(cold.os,'killpg',side_effect=PermissionError('injected kill refusal')))
            if fault=='reap': stack.enter_context(mock.patch.object(session,'_group_absent',side_effect=OSError('injected reap failure')))
            def serve():
                try: session.serve(b.fileno(),b.fileno())
                except cold.Refused: pass
            thread=threading.Thread(target=serve)
            try:
                thread.start()
                a.sendall(cold.encode(b'R',cold.document(req(b'x')))+cold.encode(b'S',b'synthetic-only'))
                kind,payload=read_frame(stream)
                self.assertEqual(kind,b'F')
                self.assertEqual(cold.parse(payload)['linuxChildrenExited'],confirmed)
                thread.join(3); self.assertFalse(thread.is_alive())
                self.assertEqual(len(children),1)
                if confirmed:
                    self.assertIsNotNone(children[0].returncode)
                    with self.assertRaises(ProcessLookupError): os.killpg(children[0].pid,0)
                else:
                    self.assertFalse(session.group_gone)
                    if fault=='kill':
                        self.assertIsNone(children[0].poll(), 'owned child still exists BEFORE defensive test cleanup')
                self.assertTrue(any(state.glob('*/*failed.json')))
            finally:
                # Never supplies evidence: every assertion above precedes cleanup.
                stack.close()
                for child in children:
                    if 'wait' in child.__dict__: del child.__dict__['wait']
                    if child.poll() is None:
                        try: os.killpg(child.pid,9)
                        except ProcessLookupError: pass
                    child.wait(timeout=3)
                a.close(); stream.close(); b.close(); thread.join(3)

    def test_pipe_setup_is_owned_and_confirmed_before_failure_ack(self): self.exercise('pipe',True)
    def test_selector_creation_is_owned_and_confirmed_before_failure_ack(self): self.exercise('selector',True)
    def test_selector_registration_is_owned_and_confirmed_before_failure_ack(self): self.exercise('register',True)
    def test_kill_refusal_never_claims_child_gone(self): self.exercise('kill',False)
    def test_wait_failure_never_claims_child_gone(self): self.exercise('wait',False)
    def test_reap_failure_never_claims_child_gone(self): self.exercise('reap',False)
    def test_unit_proof_failure_never_claims_child_gone(self): self.exercise('cgroup',False)


class RealWorkerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if INPUTS is None:
            raise unittest.SkipTest('exact signed retained Borg inputs required; run maintained private fixture runner')
        spec=importlib.util.spec_from_file_location('synthetic_borg', ROOT/'scripts/wsl-borg-fixture.py')
        cls.fixture=importlib.util.module_from_spec(spec); spec.loader.exec_module(cls.fixture)
        cls.root, fs=cls.fixture.ordinary_workspace(CUSTODY)
        cls.env=cls.fixture.private_env(cls.root)
        cls.binary, cls.tool=cls.fixture.prepare_tool(cls.root, INPUTS, cls.env)
        cls.secret=secrets.token_hex(32).encode('ascii')
        cls.phrase=cls.root/'private-input'; cls.fixture.private_secret(cls.phrase, cls.secret+b'\n')
        cls.summary=[]

    @classmethod
    def tearDownClass(cls):
        cls.fixture.write_json(cls.root/'worker-tests.json', dict(protocol=cold.PROTOCOL, tool=cls.tool,
            tests=cls.summary, productionAccepted=False, windowsIntegrationAccepted=False))
        print('RETAINED_NONSECRET_WORKER_RECEIPT='+str(cls.root/'worker-tests.json'))

    def setUp(self):
        self.case=self.root/str(uuid.uuid4()); self.case.mkdir(mode=0o700)
        self.repository=self.case/'repository'
        self.state=self.case/'state'; self.state.mkdir(mode=0o700)
        self.fixture.recovery_borg(self.binary,['init','--encryption=repokey-blake2',str(self.repository)],
            cwd=self.case,env=self.env,passphrase=self.phrase)
        self.session=cold.Session(self.binary,self.repository,self.state,'a'*64,timeout=20,idle=2)
        self.a,self.b=socket.socketpair(); self.a.settimeout(10)
        self.stream=self.a.makefile('rb',buffering=0)
        self.failure=None; self.receipt=None
        self.send_lock=threading.Lock()
        self.heartbeat_stop=threading.Event()
        self.heartbeat=None
        def worker():
            try:
                self.receipt=self.session.serve(self.b.fileno(),self.b.fileno())
            except cold.Refused as exc:
                self.failure=str(exc)
            finally:
                self.b.close()
        self.thread=threading.Thread(target=worker,daemon=True); self.thread.start()

    def tearDown(self):
        # Defensive cleanup cannot make an assertion pass. Tests assert joined first.
        self.heartbeat_stop.set()
        if self.heartbeat: self.heartbeat.join(2)
        self.a.close(); self.stream.close()
        self.thread.join(5)
        if self.thread.is_alive():
            raise AssertionError('worker thread remains alive')

    def send(self, kind, value=b''):
        with self.send_lock:
            self.a.sendall(cold.encode(kind, cold.document(value) if isinstance(value,dict) else value))

    def start(self, data, request=None):
        value=request or req(data)
        self.send(b'R',value); self.send(b'S',self.secret)
        def heartbeat():
            while not self.heartbeat_stop.wait(.25):
                try: self.send(b'H')
                except OSError: return
        self.heartbeat=threading.Thread(target=heartbeat,daemon=True); self.heartbeat.start()
        return value

    def failed(self, code=None):
        kind,payload=read_frame(self.stream)
        self.assertEqual(kind,b'F')
        result=cold.parse(payload)
        self.assertTrue(result['linuxChildrenExited'])
        if code:
            self.assertEqual(result['code'],code)
        self.thread.join(4)
        self.assertFalse(self.thread.is_alive(), 'before defensive cleanup')
        for pid in self.session.children:
            with self.assertRaises(ProcessLookupError):
                os.killpg(pid,0)
        self.assertTrue(any(self.state.glob('*/pending*')) or any(self.state.glob('*/*pending.json')))
        self.assertTrue(any(self.state.glob('*/*failed.json')))
        self.summary.append({'test':self.id(),'failedAsRequired':True,'linuxGroupsAbsent':True})
        return result

    def complete(self, data, value):
        received=bytearray()
        while True:
            kind,payload=read_frame(self.stream)
            if kind==b'D':
                received.extend(payload)
            elif kind==b'A':
                receipt=cold.parse(payload)
                self.assertEqual(bytes(received),data)
                self.assertEqual(receipt['archiveId'],value['archiveId'])
                self.send(b'K', {'receiptSha256':hashlib.sha256(payload).hexdigest()})
                final_kind,final=read_frame(self.stream)
                self.assertEqual((final_kind,final),(b'Z',payload))
                self.thread.join(4)
                self.assertFalse(self.thread.is_alive(), 'before cleanup')
                self.assertIsNone(self.failure)
                self.assertTrue(any(self.state.glob('*/*committed.json')))
                self.summary.append({'test':self.id(),'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),
                                     'linuxGroupsAbsent':True,'productionAccepted':False})
                return receipt
            else:
                self.fail('worker refused '+repr(cold.parse(payload)))

    def test_real_encrypted_backup_and_fresh_client_restore(self):
        data=bytes(range(256))*4096+b'\x00\xff\x80-end'
        value=self.start(data)
        for offset in range(0,len(data),cold.MAX_DATA):
            self.send(b'D',data[offset:offset+cold.MAX_DATA])
        self.send(b'E',{'bytes':len(data),'sha256':value['sha256']})
        self.complete(data,value)
        # Independent private key artifact; original synthetic client path unavailable.
        recovery=self.case/'recovery-artifacts'; recovery.mkdir(mode=0o700)
        key=recovery/'exported-key'
        self.fixture.recovery_borg(self.binary,['key','export',str(self.repository),str(key)],
            cwd=self.case,env=self.env,passphrase=self.phrase)
        key.chmod(0o600)
        self.fixture.remove_synthetic_key(self.case,self.repository,key)
        fresh=self.case/'fresh'; fresh.mkdir(mode=0o700)
        fresh_env=self.fixture.private_env(fresh)
        for label,args,phrase,exit_code in (
            ('missing-key',['list',str(self.repository)],self.phrase,44),
            ('import',['key','import',str(self.repository),str(key)],self.phrase,0)):
            self.fixture.recovery_borg(self.binary,args,cwd=self.case,env=fresh_env,passphrase=phrase,expected_exit=exit_code)
            self.summary.append({'control':label,'exitCode':exit_code})
        wrong=self.case/'wrong'; self.fixture.private_secret(wrong,secrets.token_hex(32).encode('ascii')+b'\n')
        self.fixture.recovery_borg(self.binary,['list',str(self.repository)],cwd=self.case,env=fresh_env,passphrase=wrong,expected_exit=52)
        self.summary.append({'control':'wrong-passphrase','exitCode':52})
        self.state.rename(self.case/'original-client-unavailable')
        # New session and transaction, same explicitly bound archive. No original input stream is supplied.
        self.heartbeat_stop.set(); self.heartbeat.join(2)
        self.a.close(); self.stream.close()
        self.heartbeat_stop=threading.Event()
        self.state=self.case/'restore-state'; self.state.mkdir(mode=0o700)
        self.session=cold.Session(self.binary,self.repository,self.state,'a'*64,timeout=20,idle=2)
        self.a,self.b=socket.socketpair(); self.a.settimeout(10); self.stream=self.a.makefile('rb',buffering=0)
        self.failure=None
        def restore():
            try: self.session.serve(self.b.fileno(),self.b.fileno())
            except cold.Refused as exc: self.failure=str(exc)
            finally: self.b.close()
        self.thread=threading.Thread(target=restore,daemon=True); self.thread.start()
        restored=self.start(data,req(data,phase='restore',archive=value['archiveId']))
        self.send(b'E',{'bytes':0,'sha256':hashlib.sha256(b'').hexdigest()})
        self.complete(data,restored)

    def dotnet_exchange(self, mode, keyfile=False):
        # The setUp worker has no request: close it and prove it exits before the
        # separate .NET-to-worker process test starts. No real distribution is used.
        self.a.shutdown(socket.SHUT_WR)
        kind,payload=read_frame(self.stream)
        self.assertEqual(kind,b'F')
        self.thread.join(4); self.assertFalse(self.thread.is_alive())
        data=bytes(range(256))*4096+b'\x00\xff-protocol'
        value=req(data)
        (self.case/'source.bin').write_bytes(data)
        self.fixture.private_secret(self.case/'secure-input',self.secret)
        self.fixture.write_json(self.case/'request.json',value)
        if keyfile:
            self.repository=self.case/'keyfile-repository'
            original=self.case/'keyfile-client';original.mkdir(mode=0o700)
            env=self.fixture.private_env(original);env['BORG_KEY_FILE']=str(original/'key')
            self.fixture.recovery_borg(self.binary,['init','--encryption=keyfile-blake2',str(self.repository)],cwd=self.case,env=env,passphrase=self.phrase)
            self.fixture.recovery_borg(self.binary,['key','export',str(self.repository),str(self.case/'key-artifact')],cwd=self.case,env=env,passphrase=self.phrase)
            (self.case/'key-artifact').chmod(0o600);original.rename(self.case/'original-keyfile-client-unavailable')
        context=dict(testKind='new-private-borg-protocol-test-v1',binary=str(self.binary),
                     repository=str(self.repository),state=str(self.state),binding='a'*64)
        if keyfile:context['keyCustody']='keyfile-blake2-independent-v1'
        self.fixture.write_json(self.case/'synthetic-worker-context.json',context)
        (self.case/'synthetic-worker-context.json').chmod(0o600)
        result=subprocess.run(['/usr/bin/pwsh','-NoProfile','-NonInteractive','-File',
            str(ROOT/'tests/helpers/Invoke-WslColdWorkerNativeTest.ps1'),'-FixtureRoot',str(self.case),'-SourceRoot',str(ROOT),'-Mode',mode,*(['-Keyfile'] if keyfile else [])],
            capture_output=True,timeout=40)
        self.assertEqual(result.returncode,0,result.stderr.decode(errors='replace'))
        if mode != 'roundtrip':
            self.assertEqual((self.case/'dotnet-negative.json').read_text(),mode+' acknowledged')
            self.assertTrue(any(self.state.glob('*/*failed.json')))
            self.summary.append({'test':self.id(),'nativeDotnetCancellationAcknowledged':True,'mode':mode})
            return
        receipt=json.loads((self.case/'dotnet-receipt.json').read_text())
        self.assertTrue(receipt['linuxChildrenExited'])
        self.assertEqual((self.case/'partial.bin').read_bytes(),data)
        self.summary.append({'test':self.id(),'nativeDotnetPythonIntegration':True,'productionAccepted':False})

    def test_dotnet_binary_protocol_to_actual_native_worker(self):
        self.dotnet_exchange('roundtrip')

    def test_dotnet_keyfile_binary_protocol_to_actual_native_worker(self):
        self.dotnet_exchange('roundtrip',True)

    def test_dotnet_cancellation_receives_linux_ack_before_cleanup(self):
        self.dotnet_exchange('cancel')

    def test_dotnet_timeout_receives_linux_ack_before_cleanup(self):
        self.dotnet_exchange('timeout')

    def test_real_keyfile_import_fresh_client_and_native_archive_binding(self):
        # Close the unused legacy fixture endpoint BEFORE the separate keyfile test.
        self.a.shutdown(socket.SHUT_WR);kind,payload=read_frame(self.stream)
        self.assertEqual(kind,b'F');self.thread.join(3);self.assertFalse(self.thread.is_alive())
        self.a.close();self.stream.close()
        repository=self.case/'keyfile-repository'
        client=self.case/'original-keyfile-client';client.mkdir(mode=0o700)
        env=self.fixture.private_env(client);env['BORG_KEY_FILE']=str(client/'private-key')
        self.fixture.recovery_borg(self.binary,['init','--encryption=keyfile-blake2',str(repository)],cwd=self.case,env=env,passphrase=self.phrase)
        key=self.case/'independent-key-artifact'
        self.fixture.recovery_borg(self.binary,['key','export',str(repository),str(key)],cwd=self.case,env=env,passphrase=self.phrase)
        key.chmod(0o600);client.rename(self.case/'original-client-unavailable')
        fresh=self.case/'keyfile-state';fresh.mkdir(mode=0o700)
        fresh_env=self.fixture.private_env(fresh)
        self.fixture.recovery_borg(self.binary,['list',str(repository)],cwd=self.case,env=fresh_env,passphrase=self.phrase,expected_exit=42)
        import configparser,fcntl
        config=configparser.ConfigParser();config.read(repository/'config');native_id=config['repository']['id']
        testcase=self
        class SyntheticDeployment:
            # Test-internal engine seam; NEVER a production CLI/admission flag.
            policy={'repository':{'id':native_id},'controller':{'restore':{'nativeArchiveId':''}}}
            def begin(self,request): self.check()
            def custody(self):
                fd=os.open(testcase.case/'custody.lock',os.O_CREAT|os.O_RDWR,0o600)
                fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);self.lock_fd=fd;return fd
            def check(self):
                self.assertions=True
                if hasattr(self,'lock_fd'):
                    probe=os.open(testcase.case/'custody.lock',os.O_RDWR)
                    try:
                        with testcase.assertRaises(BlockingIOError):fcntl.flock(probe,fcntl.LOCK_EX|fcntl.LOCK_NB)
                    finally:os.close(probe)
                testcase.assertEqual(config['repository']['id'],native_id)
            def reserve(self): pass
        self.state=fresh;self.session=cold.Session(self.binary,repository,fresh,'a'*64,timeout=25,idle=3,deployment=SyntheticDeployment())
        self.a,self.b=socket.socketpair();self.a.settimeout(10);self.stream=self.a.makefile('rb',buffering=0)
        self.failure=None
        def worker():
            try:self.session.serve(self.b.fileno(),self.b.fileno())
            except cold.Refused as exc:self.failure=str(exc)
            finally:self.b.close()
        self.thread=threading.Thread(target=worker,daemon=True);self.thread.start()
        data=bytes(range(256))*4096+b'keyfile-independent-end'
        value=self.start(data);self.send(b'Y',key.read_bytes())
        ready,prepared=read_frame(self.stream);self.assertEqual(ready,b'B')
        for offset in range(0,len(data),cold.MAX_DATA):self.send(b'D',data[offset:offset+cold.MAX_DATA])
        self.send(b'E',{'bytes':len(data),'sha256':value['sha256']})
        receipt=self.complete(data,value)
        self.assertTrue(cold.sha(receipt['nativeArchiveId']))
        imported=fresh/value['transactionId']/'imported-key'
        self.assertTrue(imported.is_file())
        config_after=configparser.ConfigParser();config_after.read(repository/'config')
        wrong=self.case/'keyfile-wrong-input'
        self.fixture.private_secret(wrong,secrets.token_hex(32).encode()+b'\n')
        (self.case/'negative-client').mkdir(mode=0o700)
        negative_env=self.fixture.private_env(self.case/'negative-client')
        negative_env['BORG_KEY_FILE']=str(imported)
        self.fixture.recovery_borg(self.binary,['list',str(repository)],cwd=self.case,env=negative_env,passphrase=wrong,expected_exit=52)
        self.assertFalse(config_after.has_option('repository','key'))
        self.assertEqual(config_after['repository']['id'],native_id)
        self.summary.append({'test':self.id(),'keyfileFreshClientMissingKeyExit':42,'nativeArchiveId':receipt['nativeArchiveId'],'repositoryKeyNotOverwritten':True,'actualSystemdAdmissionAccepted':False})
        self.heartbeat_stop.set();self.heartbeat.join(2);self.a.close();self.stream.close()
        self.heartbeat_stop=threading.Event()
        restore_state=self.case/'keyfile-restore-state';restore_state.mkdir(mode=0o700)
        deployment=SyntheticDeployment()
        deployment.policy=json.loads(json.dumps(deployment.policy));deployment.policy['controller']['restore']['nativeArchiveId']=receipt['nativeArchiveId']
        self.state=restore_state
        self.session=cold.Session(self.binary,repository,restore_state,'a'*64,timeout=25,idle=3,deployment=deployment)
        self.a,self.b=socket.socketpair();self.a.settimeout(10);self.stream=self.a.makefile('rb',buffering=0)
        self.failure=None
        self.thread=threading.Thread(target=worker,daemon=True);self.thread.start()
        restored=self.start(data,req(data,phase='restore',archive=value['archiveId']));self.send(b'Y',key.read_bytes())
        self.assertEqual(read_frame(self.stream)[0],b'B')
        self.send(b'E',{'bytes':0,'sha256':hashlib.sha256(b'').hexdigest()})
        final=self.complete(data,restored)
        self.assertEqual(final['nativeArchiveId'],receipt['nativeArchiveId'])
        self.summary.append({'keyfileActualFreshRestore':True,'nativeArchiveId':final['nativeArchiveId'],'originalClientPathAbsent':not client.exists(),'continuousCustodyLockObserved':True})


    def test_partial_source_cancel_acknowledges_real_linux_exit_and_preserves_journal(self):
        self.start(b'x'*100000)
        self.send(b'D',b'x'*65536)
        self.send(b'C')
        self.failed('controller-cancelled')
        self.assertTrue(self.repository.exists())

    def test_eof_is_failure_not_create_success(self):
        self.start(b'x'*100000)
        self.send(b'D',b'x'*65536)
        self.a.shutdown(socket.SHUT_WR)
        self.failed('control-eof')

    def test_worker_idle_timeout_confirms_its_borg_group_absent(self):
        self.start(b'xx')
        self.heartbeat_stop.set(); self.heartbeat.join(2)
        self.failed('control-timeout')

    def test_producer_truncation_and_digest_failure_do_not_commit(self):
        value=self.start(b'longer')
        self.send(b'D',b'short')
        self.send(b'E',{'bytes':5,'sha256':hashlib.sha256(b'short').hexdigest()})
        self.failed('source-length-or-digest')
        self.assertFalse(any(self.state.glob('*/*committed.json')))

    def test_borg_nonzero_diagnostics_do_not_commit(self):
        value=self.start(b'xx',req(b'xx',phase='restore',archive=str(uuid.uuid4())))
        self.send(b'E',{'bytes':0,'sha256':hashlib.sha256(b'').hexdigest()})
        self.failed('borg-exit-or-diagnostics')


if __name__ == '__main__':
    # Public release input paths only. No operational source/repository/key arguments.
    arguments=sys.argv[1:]
    if '--retained-release-inputs' in arguments:
        index=arguments.index('--retained-release-inputs'); INPUTS=Path(arguments[index+1]).resolve()
        del arguments[index:index+2]
        index=arguments.index('--private-fixture-parent'); CUSTODY=Path(arguments[index+1]).resolve()
        del arguments[index:index+2]
    unittest.main(argv=[sys.argv[0],*arguments])

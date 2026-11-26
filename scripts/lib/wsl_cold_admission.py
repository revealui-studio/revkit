"""Signed, root-owned cold worker deployment admission. No provisioning actions."""
import configparser
import hashlib
import importlib.util
import json
import os
import selectors
import signal
from pathlib import Path
import stat
import subprocess
import sys
import time
import uuid

POLICY = Path('/etc/revkit/cold-container-v1.json')
SIGNERS = Path('/etc/revkit/cold-container-allowed-signers')
NAMESPACE = 'revkit-cold-deployment-v1'
BORG_SHA = 'c8457f70660064d0f45b38283ab4cc65b342970012013201d3aec713a75898fb'


class AdmissionError(Exception):
    pass


def protected(path, *, directory=False):
    path=Path(path)
    if not path.is_absolute() or path.resolve(strict=True)!=path:
        raise AdmissionError('immutable-canonical-path')
    for item in (path,*path.parents):
        info=item.lstat()
        if info.st_uid!=0 or info.st_mode & 0o022 or stat.S_ISLNK(info.st_mode):
            raise AdmissionError('immutable-root-owner-mode')
    info=path.stat()
    if directory != stat.S_ISDIR(info.st_mode) or (not directory and not stat.S_ISREG(info.st_mode)):
        raise AdmissionError('immutable-file-type')
    return path


def bounded_json(data):
    if len(data)>1048576:
        raise AdmissionError('policy-bound')
    def pairs(rows):
        result={}
        for key,value in rows:
            if key in result: raise AdmissionError('policy-duplicate')
            result[key]=value
        return result
    try:
        value=json.loads(data,object_pairs_hook=pairs,parse_constant=lambda _: (_ for _ in ()).throw(AdmissionError('policy-number')))
        if not isinstance(value,dict): raise AdmissionError('policy-object')
        return value
    except (ValueError,UnicodeError,RecursionError):
        raise AdmissionError('policy-json') from None


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def command(argv, *, data=None, limit=65536, timeout_seconds=15):
    # Only fixed internal OS/SSH queries; bounded simultaneous pipes, no shell.
    data=data or b''
    if len(data)>1048576: raise AdmissionError('control-input-bound')
    child=subprocess.Popen(argv,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
        start_new_session=True,env={'PATH':'/usr/bin:/bin','LANG':'C.UTF-8'})
    selector=None; outputs={'out':bytearray(),'err':bytearray()};position=0;deadline=time.monotonic()+timeout_seconds
    try:
        selector=selectors.DefaultSelector()
        for pipe,label in ((child.stdin,'in'),(child.stdout,'out'),(child.stderr,'err')):
            os.set_blocking(pipe.fileno(),False)
            selector.register(pipe,selectors.EVENT_WRITE if label=='in' else selectors.EVENT_READ,label)
        while selector.get_map() or child.poll() is None:
            if time.monotonic()>deadline: raise AdmissionError('admission-control-timeout')
            for key,_ in selector.select(.05):
                pipe,label=key.fileobj,key.data
                if label=='in':
                    if position<len(data):
                        try: position+=os.write(pipe.fileno(),data[position:position+65536])
                        except BlockingIOError: pass
                    if position==len(data):selector.unregister(pipe);pipe.close()
                else:
                    chunk=os.read(pipe.fileno(),4096)
                    if not chunk:selector.unregister(pipe);pipe.close()
                    else:
                        outputs[label].extend(chunk)
                        if len(outputs[label])>limit:raise AdmissionError('admission-control-output-bound')
        if child.wait(timeout=1)!=0:raise AdmissionError('admission-command-refused')
        return bytes(outputs['out'])
    except BaseException:
        try:os.killpg(child.pid,signal.SIGKILL)
        except ProcessLookupError:pass
        child.wait(timeout=5)
        raise
    finally:
        if selector is not None:selector.close()
        for pipe in (child.stdin,child.stdout,child.stderr):pipe.close()


def fields(value,names):
    if not isinstance(value,dict) or set(value)!=set(names): raise AdmissionError('policy-fields')


def positive(value, minimum=1):
    if type(value) is not int or value<minimum or value>2**63-1: raise AdmissionError('policy-integer')


def validate(policy, *, allow_expired=False):
    fields(policy,('schemaVersion','profile','sourceCommit','expiresAt','controller','worker','repository','budget','acceptance','keyCustody','operation','transactionId','archiveId'))
    if type(policy['schemaVersion']) is not int or policy['schemaVersion']!=1 or policy['profile']!='cold-vhd-container-v1' or policy['keyCustody']!='keyfile-blake2-independent-v1':
        raise AdmissionError('policy-version-key-custody')
    if len(policy['sourceCommit'])!=40 or any(c not in '0123456789abcdef' for c in policy['sourceCommit']): raise AdmissionError('policy-source')
    positive(policy['expiresAt'])
    if not allow_expired and not time.time()<policy['expiresAt']<=time.time()+86400: raise AdmissionError('policy-expired-or-too-long')
    fields(policy['worker'],('registrationId','distro','machineId','bootId','interpreter','interpreterSha256','files','borg','borgSha256','state'))
    fields(policy['repository'],('path','id','mountPath','fsUuid','partitionUuid','deviceSerial','deviceModel','deviceBytes','partitionBytes','partitionOffsetBytes','filesystemLabel'))
    fields(policy['budget'],('repositoryAdditionalBytes','workspaceAdditionalBytes','reserveBytes','timeoutSeconds'))
    fields(policy['acceptance'],('windowsReceiptSha256','selectedWorkerReceiptSha256','custodyReceiptSha256','capacityReceiptSha256'))
    fields(policy['controller'],('packageManifestSha256','files','source','protected','workerVhdx','restore','journalDirectory'))
    if policy['operation'] not in ('prepare','backup','restore') or any(str(uuid.UUID(policy[k]))!=policy[k] for k in ('transactionId','archiveId')):
        raise AdmissionError('signed-operation-binding')
    if policy['operation']=='backup' and policy['transactionId']!=policy['archiveId']: raise AdmissionError('new-archive-required')
    worker=policy['worker']; repository=policy['repository']
    for value in (worker['registrationId'],repository['fsUuid'],repository['partitionUuid']):
        if str(uuid.UUID(value))!=value: raise AdmissionError('policy-uuid')
    if worker['borgSha256']!=BORG_SHA: raise AdmissionError('borg-release-pin')
    for value in policy['acceptance'].values():
        if policy['operation']=='prepare' and value=='': continue
        if not isinstance(value,str) or len(value)!=64 or any(c not in '0123456789abcdef' for c in value): raise AdmissionError('acceptance-digest')
    for key in ('repositoryAdditionalBytes','workspaceAdditionalBytes'): positive(policy['budget'][key])
    positive(policy['budget']['reserveBytes'],64*1024**3)
    if not 1<=policy['budget']['timeoutSeconds']<=86400: raise AdmissionError('timeout-bound')
    for key in ('deviceBytes','partitionBytes','partitionOffsetBytes'): positive(repository[key])
    if repository['partitionBytes']%512 or repository['partitionOffsetBytes']%512 or repository['partitionBytes']+repository['partitionOffsetBytes']>repository['deviceBytes']: raise AdmissionError('repository-geometry')
    if any(not isinstance(repository[k],str) or not repository[k].strip() or repository[k]!=repository[k].strip() for k in ('deviceSerial','deviceModel','filesystemLabel')): raise AdmissionError('repository-windows-identity')
    if not repository['deviceSerial'].strip() or (len(repository['id'])!=64 and not (policy['operation']=='prepare' and repository['id']=='')): raise AdmissionError('repository-identity')
    fields(policy['controller']['source'],('distro','registrationId','vhdx','fileIdentity','containerBytes','hardware'))
    fields(policy['controller']['protected'],('distro','registrationId','vhdx','hardware'))
    fields(policy['controller']['restore'],('path','hardware','overheadBytes','hardwareGuarantee','archiveReceiptSha256','imageBytes','nativeArchiveId'))
    fields(policy['controller']['workerVhdx'],('path','hardware'))
    ids=[policy['worker']['registrationId'],policy['controller']['source']['registrationId'],policy['controller']['protected']['registrationId']]
    if any(str(uuid.UUID(value))!=value for value in ids) or len(set(ids))!=3: raise AdmissionError('worker-source-protected-alias')
    positive(policy['controller']['source']['containerBytes'])
    positive(policy['controller']['restore']['overheadBytes'])
    positive(policy['controller']['restore']['imageBytes'])
    if policy['operation']=='backup' and policy['budget']['repositoryAdditionalBytes']<policy['controller']['source']['containerBytes']:
        raise AdmissionError('full-container-no-savings-budget')
    return policy


def repository_observation(policy):
    repo=protected(policy['repository']['path'],directory=True)
    if repo.parent!=Path(policy['repository']['mountPath']): raise AdmissionError('repository-mount-root-custody')
    if stat.S_IMODE(repo.stat().st_mode)!=0o700: raise AdmissionError('exclusive-repository-mode')
    # No named/default ACL can grant another user access behind mode bits.
    for item in (repo,Path(policy['worker']['state'])):
        if any(name in ('system.posix_acl_access','system.posix_acl_default') for name in os.listxattr(item)):
            raise AdmissionError('exclusive-custody-acl')
    config=configparser.ConfigParser(); config.read(repo/'config')
    if config.get('repository','id',fallback='')!=policy['repository']['id']:
        raise AdmissionError('repository-native-id')
    # A production keyfile repo must not carry an embedded repokey key.
    if config.has_option('repository','key'): raise AdmissionError('repokey-not-independent-keyfile')
    return filesystem_observation(policy,repo)


def disk_probe(identity):
    # Reuse the maintained geometry/blkid observer. Its serial/model fields are
    # explicitly Windows policy claims, NOT Linux USB observations.
    spec=importlib.util.spec_from_file_location('revkit_disk_identity',Path(__file__).parent.parent/'wsl-disk-identity.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    def run(argv,remaining):
        # Commands originate only in the maintained probe, never policy strings.
        executable={'lsblk':'/usr/bin/lsblk','sfdisk':'/usr/sbin/sfdisk','blkid':'/usr/sbin/blkid','findmnt':'/usr/bin/findmnt'}[argv[0]]
        if argv[0]=='findmnt':
            # inspect() allows a not-mounted result; production refuses it below.
            return subprocess.CompletedProcess(argv,0,command([executable,*argv[1:]],timeout_seconds=min(15,remaining)).decode())
        return subprocess.CompletedProcess(argv,0,command([executable,*argv[1:]],timeout_seconds=min(15,remaining)).decode())
    return module.inspect(identity,deadline_seconds=15,runner=run)


def filesystem_observation(policy,target):
    expected=policy['repository']
    identity=dict(schemaVersion=1,serial=expected['deviceSerial'],model=expected['deviceModel'],
        diskBytes=expected['deviceBytes'],partitionBytes=expected['partitionBytes'],
        partitionStartSectors=expected['partitionOffsetBytes']//512,partitionSectors=expected['partitionBytes']//512,
        partitionUuid=expected['partitionUuid'],filesystemUuid=expected['fsUuid'],
        filesystemLabel=expected['filesystemLabel'],mountPoint=expected['mountPath'])
    observed=disk_probe(identity)
    if observed['mountState']!='MOUNTED': raise AdmissionError('repository-not-mounted')
    mount=bounded_json(command(['/usr/bin/findmnt','--json','--target',str(target),'--output','TARGET,SOURCE,FSTYPE,UUID,PARTUUID,MAJ:MIN,ID,FSROOT']))
    rows=mount.get('filesystems',[])
    if len(rows)!=1: raise AdmissionError('repository-mount-ambiguous')
    row=rows[0]
    if (row['fstype']!='ext4' or row['target']!=expected['mountPath'] or row['uuid']!=expected['fsUuid'] or
            row['partuuid']!=expected['partitionUuid'] or row['fsroot']!='/'):
        raise AdmissionError('repository-mounted-filesystem')
    device=os.stat(observed['partitionPath']); disk=os.stat(observed['diskPath']);info=Path(target).stat()
    if (not stat.S_ISBLK(device.st_mode) or not stat.S_ISBLK(disk.st_mode) or
            info.st_dev!=device.st_rdev or os.stat(row['source']).st_rdev!=device.st_rdev or
            row['maj:min']!=str(os.major(device.st_rdev))+':'+str(os.minor(device.st_rdev))):
        raise AdmissionError('repository-device-mount-custody')
    # DISKSEQ increments on kernel disk (re)registration. Mount ID detects a
    # remount, even if UUID/geometry and /dev name were copied or reused.
    sequence=(Path('/sys/dev/block')/(str(os.major(disk.st_rdev))+':'+str(os.minor(disk.st_rdev)))/'diskseq').read_text().strip()
    if not sequence.isdecimal() or int(sequence)<=0 or type(row['id']) is not int or row['id']<=0:
        raise AdmissionError('repository-kernel-continuity-unavailable')
    return (info.st_dev,info.st_ino,device.st_rdev,device.st_ino,disk.st_rdev,disk.st_ino,int(sequence),row['id'],row['source'],row['target'])


def capacity(policy):
    reserve=policy['budget']['reserveBytes']
    domains={}
    for path,amount in ((policy['repository']['path'],policy['budget']['repositoryAdditionalBytes']),
                        (policy['worker']['state'],policy['budget']['workspaceAdditionalBytes'])):
        observed_path=Path(path) if Path(path).exists() else Path(path).parent
        info=os.stat(observed_path); fs=os.statvfs(observed_path)
        if info.st_dev not in domains: domains[info.st_dev]=[fs.f_bavail*fs.f_frsize,reserve]
        domains[info.st_dev][1]+=amount
    if any(free<required for free,required in domains.values()): raise AdmissionError('worker-capacity-refused')
    return domains


def load(*, allow_expired=False):
    # Fixed root trust anchor; neither argv nor wire input can select a policy/key.
    if os.geteuid()!=0 or not sys.flags.isolated or not sys.dont_write_bytecode: raise AdmissionError('root-isolated-worker-required')
    for name in ('LD_PRELOAD','LD_LIBRARY_PATH','BORG_PASSPHRASE','BORG_NEW_PASSPHRASE','BORG_PASSCOMMAND'):
        if name in os.environ: raise AdmissionError('secret-or-loader-environment-refused')
    raw=protected(POLICY).read_bytes(); policy=validate(bounded_json(raw),allow_expired=allow_expired)
    protected(SIGNERS); protected(str(POLICY)+'.sig')
    command(['/usr/bin/ssh-keygen','-Y','verify','-f',str(SIGNERS),'-I','revkit-owner','-n',NAMESPACE,'-s',str(POLICY)+'.sig'],data=raw)
    worker=policy['worker']
    if Path(__file__).resolve().parents[2]!=Path('/opt/revkit-wsl-backup')/policy['sourceCommit']:
        raise AdmissionError('source-addressed-worker-release')
    if Path('/etc/machine-id').read_text().strip()!=worker['machineId'] or (not allow_expired and Path('/proc/sys/kernel/random/boot_id').read_text().strip()!=worker['bootId']):
        raise AdmissionError('selected-worker-machine-boot')
    interpreter=protected(worker['interpreter'])
    if Path(sys.executable).resolve()!=interpreter or digest(interpreter)!=worker['interpreterSha256']:
        raise AdmissionError('interpreter-binding')
    for path,expected in worker['files'].items():
        if digest(protected(path))!=expected: raise AdmissionError('worker-source-binding')
    expected_files={str(Path(__file__).resolve()),str(Path(__file__).with_name('wsl_cold_container.py').resolve()),str(Path(__file__).parent.parent/'wsl-cold-worker.py'),str(Path(__file__).parent.parent/'wsl-disk-identity.py')}
    if set(worker['files'])!=expected_files: raise AdmissionError('worker-runtime-closure')
    if digest(protected(worker['borg']))!=BORG_SHA: raise AdmissionError('borg-binding')
    protected(worker['state'],directory=True)
    if stat.S_IMODE(Path(worker['state']).stat().st_mode)!=0o700: raise AdmissionError('worker-private-state')
    if allow_expired: return policy,hashlib.sha256(raw).hexdigest(),None
    if policy['operation']=='prepare' and not Path(policy['repository']['path']).exists():
        mount=protected(policy['repository']['mountPath'],directory=True)
        filesystem_observation(policy,mount);capacity(policy)
        return policy,hashlib.sha256(raw).hexdigest(),None
    observed=repository_observation(policy); capacity(policy)
    return policy,hashlib.sha256(raw).hexdigest(),observed


def cancellation_present(path):
    try: Path(path).lstat()
    except FileNotFoundError: return False
    return True


class Deployment:
    def __init__(self,policy,binding,observation):
        self.policy,self.binding,self.observation=policy,binding,observation
        self.repo=Path(policy['repository']['path'])
        self.state=Path(policy['worker']['state'])
        self.initial=capacity(policy)

    def begin(self,request):
        # An OS-supervised control group, not wsl.exe parent lifetime, owns the job.
        self.transaction=request['transactionId']
        if cancellation_present(self.state/('cancel-'+self.transaction+'.json')): raise AdmissionError('transaction-cancelled-before-launch')
        unit='revkit-cold-'+self.transaction+'.service'
        values={}
        raw=command(['/usr/bin/systemctl','show',unit,'--property=MainPID,ControlGroup,KillMode,RuntimeMaxUSec,ActiveState'])
        for line in raw.decode().splitlines():
            key,sep,value=line.partition('=')
            if sep: values[key]=value
        if values.get('MainPID')!=str(os.getpid()) or values.get('KillMode')!='control-group' or values.get('ActiveState') not in ('active','activating'):
            raise AdmissionError('supervised-worker-lifetime-required')
        duration=values.get('RuntimeMaxUSec','')
        units={'d':86400,'h':3600,'min':60,'s':1,'ms':.001,'us':.000001}
        seconds=0
        for part in duration.split():
            matched=False
            for suffix in sorted(units,key=len,reverse=True):
                if part.endswith(suffix) and part[:-len(suffix)].isdigit():
                    seconds+=int(part[:-len(suffix)])*units[suffix]; matched=True; break
            if not matched: raise AdmissionError('worker-runtime-bound')
        if not 0<seconds<=self.policy['budget']['timeoutSeconds']+30: raise AdmissionError('worker-runtime-bound')
        group=values.get('ControlGroup','')
        if group!='/system.slice/'+unit: raise AdmissionError('worker-control-group')
        self.control_group=Path('/sys/fs/cgroup'+group)
        current=Path('/proc/self/cgroup').read_text()
        if '0::'+group+'\n'!=current: raise AdmissionError('worker-control-group-binding')
        # Policy age, source size and request binding remain exact through commit.
        if (request['bindingSha256']!=self.binding or any(request[k]!=self.policy[k] for k in ('transactionId','archiveId')) or request['phase']!=self.policy['operation'] or
                request['bytes']!=(self.policy['controller']['restore']['imageBytes'] if request['phase']=='restore' else self.policy['controller']['source']['containerBytes'])):
            raise AdmissionError('live-request-policy-binding')
        self.check()

    def children_absent(self):
        # No Popen/parent/PGID exception can substitute for this kernel proof.
        with (self.control_group/'cgroup.procs').open() as stream: raw=stream.read(65537)
        if len(raw)>65536 or set(raw.split())!={str(os.getpid())}: raise AdmissionError('unit-descendants-still-present')
        rows=dict(line.split() for line in (self.control_group/'cgroup.stat').read_text().splitlines())
        if rows.get('nr_descendants')!='0': raise AdmissionError('unit-subgroups-unconfirmed')

    def custody(self):
        # Filesystem-resident lock shared across workers/distros, root-only repo
        # access excludes ordinary clients. Root administrators remain trusted.
        import fcntl
        path=self.repo.parent/('.revkit-cold-'+self.policy['repository']['id']+'.lock')
        protected(self.repo.parent,directory=True)
        fd=os.open(path,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
        try:
            info=os.fstat(fd)
            if info.st_uid!=0 or stat.S_IMODE(info.st_mode)!=0o600 or not stat.S_ISREG(info.st_mode): raise AdmissionError('repository-custody-lock')
            fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
            return fd
        except BaseException:
            os.close(fd); raise

    def reserve(self):
        if time.time()>=self.policy['expiresAt']: raise AdmissionError('live-admission-expired')
        if hasattr(self,'transaction') and cancellation_present(self.state/('cancel-'+self.transaction+'.json')): raise AdmissionError('transaction-cancelled')
        # Conservative shared-filesystem growth accounting, not a filesystem quota.
        domains={}
        for path in (self.repo,self.state):
            info=path.stat(); fs=os.statvfs(path)
            domains[info.st_dev]=fs.f_bavail*fs.f_frsize
        for device,free in domains.items():
            baseline,required=self.initial[device]
            growth=max(0,baseline-free)
            allowance=required-self.policy['budget']['reserveBytes']
            if free<self.policy['budget']['reserveBytes'] or growth>allowance:
                raise AdmissionError('measured-worker-growth-budget-exceeded')

    def check(self):
        if hasattr(self,'transaction') and cancellation_present(self.state/('cancel-'+self.transaction+'.json')): raise AdmissionError('transaction-cancelled')
        if time.time()>=self.policy['expiresAt']: raise AdmissionError('live-admission-expired')
        if repository_observation(self.policy)!=self.observation: raise AdmissionError('repository-continuity-changed')
        self.reserve()


def reconcile(policy,binding,transaction):
    if str(uuid.UUID(transaction))!=transaction or transaction!=policy['transactionId']: raise AdmissionError('cancel-uuid')
    state=protected(policy['worker']['state'],directory=True)
    path=state/('cancel-'+transaction+'.json')
    data=json.dumps({'transactionId':transaction,'bindingSha256':binding,'cancelled':True},sort_keys=True).encode()
    try:
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    except FileExistsError:
        fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
        with os.fdopen(fd,'rb') as stream:existing=stream.read(4097)
        if existing!=data: raise AdmissionError('cancel-binding-changed')
    else:
        with os.fdopen(fd,'wb') as stream:
            stream.write(data);stream.flush();os.fsync(stream.fileno())
        fd=os.open(state,os.O_RDONLY|os.O_DIRECTORY)
        try: os.fsync(fd)
        finally: os.close(fd)
    unit='revkit-cold-'+transaction+'.service'
    # A structured manager observation must succeed (not a guessed exit code).
    observed=subprocess.run(['/usr/bin/systemctl','show',unit,'--all','--property=LoadState,ActiveState,ControlGroup'],
        stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15)
    if len(observed.stdout)>65536 or len(observed.stderr)>65536: raise AdmissionError('unit-observation-bound')
    values=dict(line.split('=',1) for line in observed.stdout.decode().splitlines() if '=' in line)
    if observed.returncode and values.get('LoadState')!='not-found': raise AdmissionError('unit-observation-refused')
    if values.get('LoadState') not in ('loaded','not-found'): raise AdmissionError('unit-load-state-unconfirmed')
    if values['LoadState']=='loaded':
        command(['/usr/bin/systemctl','stop',unit])  # No other service/kill-all/reset-failed.
    group=Path('/sys/fs/cgroup/system.slice')/unit
    if not kernel_group_empty(group): raise AdmissionError('cancel-control-group-still-populated')
    # Durable cancellation prevents a delayed wsl.exe/systemd-run from later
    # starting a backend after the empty-group observation. Group path is fixed
    # and independently checked by begin(); arbitrary slices are never accepted.
    return {'transactionId':transaction,'bindingSha256':binding,'linuxUnitEmpty':True,'futureLaunchCancelled':True}


def kernel_group_empty(group):
    # Path.exists() suppresses permission errors on modern Python. Only actual
    # ENOENT under a verified mounted cgroup hierarchy may establish absence.
    Path('/sys/fs/cgroup/cgroup.controllers').read_text()
    if not stat.S_ISDIR(Path('/sys/fs/cgroup/system.slice').stat().st_mode): raise AdmissionError('cgroup-hierarchy-unavailable')
    try: group.stat()
    except FileNotFoundError: return True
    rows=dict(line.split() for line in (group/'cgroup.events').read_text().splitlines())
    if rows.get('populated') not in ('0','1'): raise AdmissionError('kernel-group-state-unconfirmed')
    return rows['populated']=='0'


def status(policy,binding,transaction):
    if str(uuid.UUID(transaction))!=transaction or transaction!=policy['transactionId']:raise AdmissionError('status-uuid')
    marker=Path(policy['worker']['state'])/('cancel-'+transaction+'.json')
    cancelled=False
    try:fd=os.open(marker,os.O_RDONLY|os.O_NOFOLLOW)
    except FileNotFoundError:pass
    else:
        with os.fdopen(fd,'rb') as stream:
            raw=stream.read(4097)
        expected=json.dumps({'transactionId':transaction,'bindingSha256':binding,'cancelled':True},sort_keys=True).encode()
        if raw!=expected:raise AdmissionError('cancel-binding-changed')
        cancelled=True
    group=Path('/sys/fs/cgroup/system.slice')/('revkit-cold-'+transaction+'.service')
    return {'transactionId':transaction,'bindingSha256':binding,'linuxUnitEmpty':kernel_group_empty(group),'futureLaunchCancelled':cancelled}

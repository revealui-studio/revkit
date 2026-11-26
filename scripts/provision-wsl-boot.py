#!/usr/bin/env python3
"""Seed missing WSL configuration explicitly; preserve existing host policy."""

import argparse
import configparser
import pwd
import shutil
import stat
import subprocess
import uuid
import hashlib
import json
import os
from pathlib import Path
import tempfile


def proposed_files(source, etc=Path('/etc'), windows_home=None):
    pairs = [(source / 'wsl.conf', etc / 'wsl.conf')]
    if windows_home is not None:
        if not windows_home.is_absolute() or not windows_home.is_dir():
            raise ValueError('Windows home must be an explicit existing absolute directory')
        pairs.append((source / 'wslconfig', windows_home / '.wslconfig'))
    result = []
    for src, dest in pairs:
        data = src.read_bytes().replace(b'\r\n', b'\n')
        result.append((dest, data, 'preserve' if dest.exists() or dest.is_symlink() else 'seed'))
    return result


def seed_missing(dest, data):
    if dest.exists() or dest.is_symlink():
        return False
    if not dest.parent.is_dir():
        raise ValueError(f'Configuration parent does not exist: {dest.parent}')
    with tempfile.NamedTemporaryFile(dir=dest.parent, prefix='.revkit-wsl-', delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), 0o644)
            os.link(temporary, dest)
        except FileExistsError:
            return False
        finally:
            temporary.unlink()
    return True



def coldboot_report(data):
    """Analyze an existing receipt only; this does not probe or change the host."""
    if len(data) > 4 * 1024 * 1024:
        raise ValueError('Boot evidence exceeds report limit')
    receipt = json.loads(data)
    if not isinstance(receipt, dict):
        raise ValueError('Boot evidence requires a receipt object')
    commands = receipt.get('commands')
    if not isinstance(commands, list):
        raise ValueError('Boot evidence requires a commands array')
    selected = {}
    for command in [('systemd-analyze', 'time'), ('systemd-analyze', 'critical-chain')]:
        matches = [row for row in commands if isinstance(row, dict)
                   and row.get('command') == list(command)]
        if len(matches) != 1 or matches[0].get('exit_code') != 0:
            raise ValueError('Boot evidence requires one successful ' + ' '.join(command))
        output = matches[0].get('stdout')
        if not isinstance(output, str) or not output.strip():
            raise ValueError('Boot evidence has no successful output')
        selected[command[-1]] = output
    units = []
    for line in selected['critical-chain'].splitlines():
        name, separator, timing = line.lstrip(' │└├─').partition(' @')
        if not separator:
            continue
        if not name or any(char not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.@:-\\' for char in name):
            raise ValueError('Malformed critical-chain unit')
        started, _, duration = timing.partition(' +')
        units.append({'unit': name, 'startedAfter': started, 'duration': duration or None})
    if not units:
        raise ValueError('Boot evidence has no critical-chain units')
    return {'schema': 1, 'mode': 'saved-boot-evidence-report',
            'evidenceSha256': hashlib.sha256(data).hexdigest(),
            'recordedAt': receipt.get('recorded_at'),
            'startup': selected['time'].strip(), 'criticalChain': units,
            'services': 'preserved', 'configuration': 'preserved',
            'desktopAdoption': 'unverified; separate controller cold-start receipt required',
            'nextEvidence': 'Review unit dependencies and per-unit boot journals before proposing consumer readiness changes'}


def worker_policy(data):
    if len(data)>16384:raise ValueError('Worker policy exceeds 16KiB')
    value=json.loads(data)
    required={'schemaVersion','role','registrationId','distro','rootfsUuid','defaultUser','defaultUid','initTimeoutMs','wslConfSha256'}
    if not isinstance(value,dict) or set(value)!=required or type(value['schemaVersion']) is not int or value['schemaVersion']!=1 or value['role']!='cold-backup-worker-v1':
        raise ValueError('Explicit selected-worker boot policy required')
    for key in ('registrationId','rootfsUuid'):
        if str(uuid.UUID(value[key]))!=value[key]: raise ValueError('Canonical selected-worker UUID required')
    if value['distro'] in ('Ubuntu','Ubuntu-Recovery-20261124') or not value['distro'] or not value['defaultUser'] or type(value['defaultUid']) is not int or value['defaultUid']<=0:
        raise ValueError('Worker must be distinct from main/protected and preserve explicit ordinary account')
    if type(value['initTimeoutMs']) is not int or not 10000<=value['initTimeoutMs']<=120000:
        raise ValueError('Reviewed worker init timeout must be 10000..120000 milliseconds')
    if len(value['wslConfSha256'])!=64 or any(c not in '0123456789abcdef' for c in value['wslConfSha256']):raise ValueError('Exact original configuration digest required')
    return value


def worker_boot_plan(policy, original, *, root_uuid, account_uid):
    if root_uuid!=policy['rootfsUuid'] or account_uid!=policy['defaultUid'] or hashlib.sha256(original).hexdigest()!=policy['wslConfSha256']:
        raise ValueError('Selected worker filesystem/account/configuration changed')
    if len(original)>1048576:raise ValueError('Worker configuration exceeds 1MiB')
    text=original.decode('utf-8'); config=configparser.ConfigParser(interpolation=None);config.read_string(text)
    if config.defaults() or config.get('boot','systemd',fallback='')!='true' or config.get('user','default',fallback='')!=policy['defaultUser']:
        raise ValueError('Existing systemd/default-user choices must match reviewed worker policy')
    # Preserve every unrelated byte; only a single explicit boot key is changed.
    lines=text.splitlines(keepends=True);section=None;found=None;insert=None
    newline='\r\n' if '\r\n' in text else '\n'
    for index,line in enumerate(lines):
        stripped=line.strip()
        if stripped.startswith('[') and stripped.endswith(']'):
            if section=='boot' and insert is None:insert=index
            section=stripped[1:-1]
        elif section=='boot' and not stripped.startswith(('#',';')):
            key,sep,_=stripped.partition('=')
            if sep and key.strip().lower()=='inittimeout':
                if found is not None:raise ValueError('Ambiguous worker timeout key')
                found=index
    replacement='initTimeout='+str(policy['initTimeoutMs'])+newline
    if found is not None:lines[found]=replacement
    else:
        position=insert if insert is not None else len(lines)
        if position and not lines[position-1].endswith(('\n','\r')):lines[position-1]+=newline
        lines.insert(position,replacement)
    desired=''.join(lines).encode()
    plan={'schemaVersion':1,'role':policy['role'],'registrationId':policy['registrationId'],'distro':policy['distro'],
          'rootfsUuid':root_uuid,'defaultUser':policy['defaultUser'],'defaultUid':account_uid,
          'initTimeoutMs':policy['initTimeoutMs'],'beforeSha256':hashlib.sha256(original).hexdigest(),
          'afterSha256':hashlib.sha256(desired).hexdigest(),'changed':desired!=original,
          'services':'preserved','hostResources':'preserved','coldStartAccepted':False,'startupWarningCause':'unproved'}
    return plan,desired


def selected_worker_context(policy):
    query=subprocess.run(['/usr/bin/findmnt','--json','--mountpoint','/','--output','UUID'],check=True,capture_output=True,timeout=10)
    rows=json.loads(query.stdout).get('filesystems',[])
    if len(rows)!=1:raise ValueError('Worker root filesystem ambiguous')
    return rows[0]['uuid'],pwd.getpwnam(policy['defaultUser']).pw_uid


def apply_worker_plan(policy, plan, desired, path=Path('/etc/wsl.conf'), state=Path('/var/lib/revkit/worker-boot')):
    # No unknown source, symlinks, account changes, service or lifecycle action.
    for item in (Path(__file__).absolute(),*Path(__file__).absolute().parents,path,*path.parents):
        info=item.lstat()
        if info.st_uid!=0 or info.st_mode & 0o022 or stat.S_ISLNK(info.st_mode):raise ValueError('Root-owned immutable provisioner/configuration required')
    if hashlib.sha256(path.read_bytes()).hexdigest()!=plan['beforeSha256']:raise ValueError('Configuration changed before publication')
    if not plan['changed']:return None
    # Custody checked before mkdir; prior attempts and original bytes retained.
    ancestor=state
    while not ancestor.exists():ancestor=ancestor.parent
    for item in (ancestor,*ancestor.parents):
        info=item.lstat()
        if info.st_uid!=0 or info.st_mode & 0o022 or stat.S_ISLNK(info.st_mode):raise ValueError('Protected worker evidence parent required')
    state.mkdir(parents=True,exist_ok=True,mode=0o700)
    attempt=state/str(uuid.uuid4());attempt.mkdir(mode=0o700)
    with (attempt/'original-wsl.conf').open('xb') as out:out.write(path.read_bytes());out.flush();os.fsync(out.fileno())
    with (attempt/'plan.json').open('x') as out:json.dump(plan,out);out.flush();os.fsync(out.fileno())
    for directory in (attempt,state,state.parent):
        fd=os.open(directory,os.O_RDONLY|os.O_DIRECTORY)
        try:os.fsync(fd)
        finally:os.close(fd)
    temporary=path.parent/('.revkit-worker-'+attempt.name)
    # Copy metadata from the reviewed original; no host permission changes.
    try:
        with temporary.open('xb') as out:out.write(desired);out.flush();os.fsync(out.fileno())
        shutil.copystat(path,temporary,follow_symlinks=False)
        if hashlib.sha256(path.read_bytes()).hexdigest()!=plan['beforeSha256']:raise ValueError('Configuration changed during publication')
        os.replace(temporary,path)
        fd=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY)
        try:os.fsync(fd)
        finally:os.close(fd)
    except BaseException:
        # Original and any temporary publication remain evidence; no guessed rollback.
        raise
    return str(attempt)


def worker_readiness(policy, config_bytes):
    root_uuid,uid=selected_worker_context(policy)
    config=configparser.ConfigParser(interpolation=None);config.read_string(config_bytes.decode())
    if root_uuid!=policy['rootfsUuid'] or uid!=policy['defaultUid'] or config.get('user','default',fallback='')!=policy['defaultUser'] or config.get('boot','systemd',fallback='')!='true' or config.getint('boot','initTimeout',fallback=10000)!=policy['initTimeoutMs']:
        raise ValueError('Selected worker boot readiness binding differs')
    def query(argv):
        result=subprocess.run(argv,check=True,capture_output=True,timeout=15)
        if result.stderr or len(result.stdout)>65536:raise ValueError('Worker readiness diagnostics/output refused')
        return result.stdout.decode().strip()
    if query(['/usr/bin/systemctl','is-system-running'])!='running':raise ValueError('Worker system manager is not running')
    status=query(['/usr/bin/systemctl','show','user@0.service','--property=ActiveState,SubState,Result'])
    values=dict(line.split('=',1) for line in status.splitlines())
    if values!={'ActiveState':'active','SubState':'running','Result':'success'}:raise ValueError('Root worker user-session readiness unproved')
    if not stat.S_ISSOCK(Path('/run/user/0/bus').stat().st_mode):raise ValueError('Root worker bus unavailable')
    return {'schemaVersion':1,'role':policy['role'],'registrationId':policy['registrationId'],'rootfsUuid':root_uuid,
            'bootId':Path('/proc/sys/kernel/random/boot_id').read_text().strip(),'readyNow':True,
            'coldStartAccepted':False,'productionAdmitted':False,'startupWarningCause':'unproved'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--windows-home', type=Path)
    parser.add_argument('--revert', action='store_true')
    parser.add_argument('--boot-evidence', type=Path, help='Report from a saved native startup JSON receipt; no live commands')
    parser.add_argument('--worker-policy',type=Path)
    parser.add_argument('--reviewed-plan-sha256')
    parser.add_argument('--worker-readiness',action='store_true')
    args = parser.parse_args()
    if args.worker_policy is not None:
        if args.revert or args.windows_home is not None or args.boot_evidence is not None or (args.apply and args.worker_readiness):parser.error('Worker role is separate from host seed/report operations')
        policy=worker_policy(args.worker_policy.read_bytes())
        current=Path('/etc/wsl.conf').read_bytes()
        if args.worker_readiness:
            print(json.dumps(worker_readiness(policy,current),indent=2));return
        root_uuid,uid=selected_worker_context(policy)
        plan,desired=worker_boot_plan(policy,current,root_uuid=root_uuid,account_uid=uid)
        raw=json.dumps(plan,sort_keys=True,separators=(',',':')).encode()
        digest=hashlib.sha256(raw).hexdigest()
        if args.apply:
            if os.geteuid()!=0 or args.reviewed_plan_sha256!=digest:parser.error('Root and exact reviewed worker plan SHA256 required')
            plan['evidenceDirectory']=apply_worker_plan(policy,plan,desired)
        print(json.dumps({'plan':plan,'planSha256':digest,'applied':args.apply},indent=2));return
    if args.worker_readiness or args.reviewed_plan_sha256:parser.error('Explicit worker policy required')
    if args.boot_evidence is not None:
        if args.apply or args.revert or args.windows_home is not None:
            parser.error('--boot-evidence is report-only and cannot be combined with provisioning')
        with args.boot_evidence.open('rb') as stream:
            data = stream.read(4 * 1024 * 1024 + 1)
        print(json.dumps(coldboot_report(data), indent=2))
        return
    if args.revert:
        parser.error('Historical optimization has no prior-state receipt. Refusing to guess service or configuration settings.')
    source = Path(__file__).resolve().parents[1] / 'shell' / 'config'
    proposed = proposed_files(source, windows_home=args.windows_home)
    if args.apply and os.geteuid() != 0:
        parser.error('--apply requires root')
    result = {'schema': 1, 'mode': 'apply' if args.apply else 'plan',
              'services': 'preserved', 'defaultTarget': 'preserved', 'files': []}
    for dest, data, action in proposed:
        if args.apply and action == 'seed':
            action = 'seeded' if seed_missing(dest, data) else 'preserve'
        result['files'].append({'path': str(dest), 'action': action,
                                'templateSha256': hashlib.sha256(data).hexdigest()})
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()

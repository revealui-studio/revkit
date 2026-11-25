#!/usr/bin/env python3
"""Private synthetic Borg observer; never backs up an operator-supplied source.

Extends WslBackup.ps1's evidence design with actual Linux fixture observations.
No production executor, mount, secret key, retention or system installation.
"""
import argparse
import array
import datetime
import fcntl
import errno
import struct
import uuid
import sys
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import tempfile
import urllib.request

VERSION = '1.4.5'
ASSET = 'borg-linux-glibc231-x86_64'
SHA256 = 'c8457f70660064d0f45b38283ab4cc65b342970012013201d3aec713a75898fb'
SIGNATURE_SHA256 = '712575c6a800e0ba4bf496d846927a8de36de9b5fe03b20f6d3a23fdd4741e4e'
FINGERPRINT = '6D5BEF9ADD2075805747B70F9F88FB52FAF7B393'
RELEASE = 'https://github.com/borgbackup/borg/releases/download/1.4.5/'
KEY_URL = 'https://keys.openpgp.org/vks/v1/by-fingerprint/' + FINGERPRINT
GIB = 1024 ** 3
GETFLAGS = 0x80086601
SETFLAGS = 0x40086602
NODUMP = 0x40
PRIVILEGED_BASE = Path("/var/lib/revkit-synthetic-fixtures")
PRIVILEGED_TOOLS = Path("/var/lib/revkit-synthetic-fixture-tools")
PUBLIC_KEY_SHA256 = "01fcff7ffea31147c63c242ff70c78c846056e4805c35ab9e740c09ac43f37b9"


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def write_json(path, value):
    with path.open('x', encoding='utf-8') as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())


def run(command, *, cwd, env, timeout=120):
    result = subprocess.run(command, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=timeout, check=False)
    if result.returncode:
        raise RuntimeError(f'{Path(command[0]).name} {command[1:]} failed '
                           f'({result.returncode}): {result.stderr.decode(errors="replace")[:2000]}')
    return result


def fetch(url, target, limit, expected=None):
    # Only this maintained release/key profile calls fetch. No mirror fallback.
    with urllib.request.urlopen(url, timeout=45) as response, target.open('xb') as out:
        if not response.url.startswith('https://'):
            raise ValueError('Non-HTTPS download refused')
        total = 0
        while chunk := response.read(1024 * 1024):
            total += len(chunk)
            if total > limit:
                raise ValueError('Release input exceeds bounded download size')
            out.write(chunk)
    if expected and digest(target) != expected:
        raise ValueError(f'Pinned release digest differs: {target.name}')


def verify_tool(root, binary, signature, public_key, env):
    """Verify pinned bytes and upstream detached signature before any execution."""
    for path, expected in ((binary, SHA256), (signature, SIGNATURE_SHA256)):
        if path.is_symlink() or not path.is_file() or digest(path) != expected:
            raise ValueError('Unverified Borg release input')
    keyring = root / 'release-key.gpg'
    run(['/usr/bin/gpg', '--no-options', '--batch', '--no-autostart', '--homedir',
         str(root / 'gnupg'), '--output', str(keyring), '--dearmor', str(public_key)],
        cwd=root, env=env)
    verified = run(['/usr/bin/gpgv', '--homedir', str(root / 'gnupg'), '--status-fd', '1',
                    '--keyring', str(keyring), str(signature), str(binary)], cwd=root, env=env)
    valid = []
    for line in verified.stdout.decode().splitlines():
        words = line.split()
        if words[:2] == ['[GNUPG:]', 'VALIDSIG']:
            valid.append(words)
        if len(words) > 1 and words[1] in ('BADSIG', 'ERRSIG', 'EXPKEYSIG', 'EXPSIG', 'REVKEYSIG'):
            raise ValueError('Release signature is invalid, expired or revoked')
    if len(valid) != 1 or valid[0][-1] != FINGERPRINT:
        raise ValueError('Release signer differs from documented full primary fingerprint')
    binary.chmod(0o700)  # Only the freshly downloaded, verified private file.
    version = run([str(binary), '--version'], cwd=root, env=env).stdout.decode().strip()
    if version != 'borg ' + VERSION:
        raise ValueError('Verified binary reports unexpected version')
    return {'version': VERSION, 'sha256': digest(binary), 'signatureSha256': digest(signature),
            'publicKeySha256': digest(public_key), 'primaryFingerprint': FINGERPRINT,
            'releaseUrl': RELEASE + ASSET, 'signatureVerified': True}


def flags(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        value = array.array('L', [0])
        fcntl.ioctl(fd, GETFLAGS, value, True)
        return value[0]
    finally:
        os.close(fd)


def observe(tree, env):
    """Observe only our fixed, small tree. Reading uses O_NOATIME, or refuses."""
    paths = [tree, *sorted(tree.rglob('*'))]
    if len(paths) > 64:
        raise ValueError('Synthetic inventory bound exceeded')
    links = {}
    for path in paths:
        info = path.lstat()
        if stat.S_ISREG(info.st_mode) and info.st_nlink > 1:
            links.setdefault((info.st_dev, info.st_ino), []).append(path.relative_to(tree).as_posix())
    entries = []
    for path in paths:
        info = path.lstat()
        kind = ('file' if stat.S_ISREG(info.st_mode) else 'directory' if stat.S_ISDIR(info.st_mode)
                else 'symlink' if stat.S_ISLNK(info.st_mode) else 'fifo' if stat.S_ISFIFO(info.st_mode)
                else 'block' if stat.S_ISBLK(info.st_mode) else 'character' if stat.S_ISCHR(info.st_mode)
                else 'unsupported')
        if kind == 'unsupported':
            raise ValueError('Unsupported fixture entry')
        xattrs = {}
        for name in sorted(os.listxattr(path, follow_symlinks=False)):
            xattrs[name] = os.getxattr(path, name, follow_symlinks=False).hex()
        content = None
        if kind == 'file':
            fd = os.open(path, os.O_RDONLY | os.O_NOATIME | os.O_NOFOLLOW)
            with os.fdopen(fd, 'rb') as stream:
                content = hashlib.file_digest(stream, 'sha256').hexdigest()
        acl = None
        if kind in ('file', 'directory'):
            # Omit absolute filenames and use numeric ACL subjects.
            acl = run(['/usr/bin/getfacl', '--omit-header', '--numeric', '--', str(path)],
                      cwd=tree, env=env).stdout.decode()
        group = links.get((info.st_dev, info.st_ino), [])
        entries.append({'path': '.' if path == tree else path.relative_to(tree).as_posix(),
                        'type': kind, 'uid': info.st_uid, 'gid': info.st_gid,
                        'mode': stat.S_IMODE(info.st_mode), 'mtimeNs': info.st_mtime_ns,
                        'atimeNs': info.st_atime_ns, 'size': info.st_size if kind == 'file' else None,
                        'contentSha256': content, 'acl': acl, 'xattrs': xattrs,
                        'linkTarget': os.readlink(path) if kind == 'symlink' else '',
                        'hardlinkGroup': sorted(group),
                        'flags': flags(path) if kind in ('file', 'directory') else None,
                        'deviceMajor': os.major(info.st_rdev) if kind in ('block', 'character') else 0,
                        'deviceMinor': os.minor(info.st_rdev) if kind in ('block', 'character') else 0,
                        'allocatedBytes': info.st_blocks * 512 if kind == 'file' else None,
                        'sparse': kind == 'file' and info.st_size > info.st_blocks * 512})
    return entries


def compare(source, restored):
    """Compare actual observations, including relational hardlink identity."""
    # Allocation amount is observational, never an exact extent-layout promise.
    def semantic(rows):
        return [{k: v for k, v in row.items() if k != 'allocatedBytes'} for row in rows]
    if semantic(source) != semantic(restored):
        left = {row['path']: row for row in source}
        right = {row['path']: row for row in restored}
        differences = []
        for name in sorted(left.keys() | right.keys()):
            if name not in left or name not in right:
                differences.append(name + ': missing entry')
            else:
                differences.extend(name + ': ' + key for key in left[name]
                                   if key != 'allocatedBytes' and left[name][key] != right[name].get(key))
        raise ValueError('Actual round-trip differs: ' + ', '.join(differences))
    files = [row for row in restored if row['type'] == 'file']
    source_allocated = sum(row.get('allocatedBytes', 0) or 0 for row in source if row['type'] == 'file')
    restored_allocated = sum(row.get('allocatedBytes', 0) or 0 for row in files)
    return {'sourceAllocatedBytes': source_allocated,
            'allocationGrowthBytes': restored_allocated - source_allocated,
            'logicalAllocationUpperBoundBytes': sum(row['size'] for row in files),
            'restoredAllocatedBytes': sum(row.get('allocatedBytes', 0) or 0 for row in files),
            'sparseCreditBytes': 0}


def make_source(tree, env):
    tree.mkdir(mode=0o700)
    nested = tree / 'directory'
    nested.mkdir(mode=0o750)
    payload = nested / 'payload'
    payload.write_bytes(b'revkit synthetic Borg fixture\x00' * 128)
    payload.chmod(0o640)
    os.link(payload, tree / 'hardlink')
    (tree / 'symlink').symlink_to('directory/payload')
    os.mkfifo(tree / 'fifo', 0o600)
    (tree / 'A').write_bytes(b'uppercase')
    (tree / 'a').write_bytes(b'lowercase')
    sparse = tree / 'sparse'
    with sparse.open('wb') as stream:
        stream.write(b'head')
        # Span multiple default maximum chunks. An 8 MiB hole can share one
        # nonzero chunk and restore allocated even with --sparse (retained pilot).
        stream.seek(32 * 1024 * 1024)
        stream.write(b'tail')
    os.setxattr(payload, 'user.revkit-fixture', b'actual-xattr\x00value')
    run(['/usr/bin/setfacl', '--modify', 'u:65534:r--', '--', str(payload)], cwd=tree, env=env)
    run(['/usr/bin/setfacl', '--modify', 'd:u:65534:r-x', '--', str(nested)], cwd=tree, env=env)
    flag_file = tree / 'flags'
    flag_file.write_bytes(b'owner-settable nodump flag')
    with flag_file.open('rb') as stream:
        fcntl.ioctl(stream.fileno(), SETFLAGS, array.array('L', [flags(flag_file) | NODUMP]))
    # Fix timestamps after all setup; no promise of identical ctime/inode numbers.
    for path in [*sorted(tree.rglob('*')), tree]:
        # Future atime prevents relatime observer walks/readlink from changing it.
        os.utime(path, ns=(1900000000123456789, 1700000100987654321), follow_symlinks=False)


def private_env(root):
    for name in ('home', 'cache', 'security', 'config', 'tmp', 'gnupg'):
        (root / name).mkdir(mode=0o700)
    return {'PATH': '/usr/bin:/bin', 'HOME': str(root / 'home'), 'LANG': 'C.UTF-8',
            'TMPDIR': str(root / 'tmp'), 'BORG_CACHE_DIR': str(root / 'cache'),
            'BORG_SECURITY_DIR': str(root / 'security'), 'BORG_CONFIG_DIR': str(root / 'config')}


def require_root_custody(path):
    path = Path(path).absolute()
    for part in (path, *path.parents):
        info = part.lstat()
        if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError('Privileged inputs require root-owned non-writable canonical custody')
    return path


def privileged_workspace(path, release_inputs, reviewed_source_sha256):
    if os.geteuid() != 0:
        raise ValueError('Explicit privileged mode requires controller root execution')
    path = Path(path).absolute()
    if path.parent != PRIVILEGED_BASE or str(uuid.UUID(path.name)) != path.name:
        raise ValueError('Privileged workspace must be a new UUID leaf under the fixed synthetic base')
    if path.exists() or path.is_symlink():
        raise ValueError('Privileged workspace must not already exist, even empty')
    base = require_root_custody(path.parent)
    if stat.S_IMODE(base.stat().st_mode) != 0o700:
        raise ValueError('Synthetic base must be private mode0700')
    bundle = Path(release_inputs).absolute()
    if (not reviewed_source_sha256 or len(reviewed_source_sha256) != 64 or
        any(ch not in '0123456789abcdef' for ch in reviewed_source_sha256) or
        bundle != PRIVILEGED_TOOLS / reviewed_source_sha256 or
        Path(__file__).absolute() != bundle / 'wsl-borg-fixture.py'):
        raise ValueError('Privileged execution requires the fixed reviewed source-addressed tool bundle')
    if not sys.flags.isolated:
        raise ValueError('Controller must invoke the system interpreter in isolated mode (-I)')
    require_root_custody(Path(sys.executable).resolve())
    for tool in ('gpg', 'gpgv', 'getfacl', 'setfacl', 'findmnt'):
        require_root_custody(Path('/usr/bin') / tool)
    source = require_root_custody(Path(__file__))
    if not reviewed_source_sha256 or digest(source) != reviewed_source_sha256:
        raise ValueError('Privileged source differs from reviewed SHA256')
    mapping = [tuple(map(int, row.split())) for row in Path('/proc/self/uid_map').read_text().splitlines()]
    if mapping != [(0, 0, 4294967295)]:
        raise ValueError('Privileged fixture requires native initial user namespace; no namespace workaround')
    bundle = require_root_custody(release_inputs)
    for name, expected in (('borg', SHA256), (ASSET + '.asc', SIGNATURE_SHA256),
                           ('release-key.asc', PUBLIC_KEY_SHA256)):
        item = require_root_custody(bundle / name)
        if not item.is_file() or item.stat().st_size > (40 * 1024 * 1024 if name == 'borg' else 1024 * 1024) or digest(item) != expected:
            raise ValueError('Privileged release bundle differs from pinned bytes')
    mounts = [line.split()[4] for line in Path('/proc/self/mountinfo').read_text().splitlines()]
    # Fixed paths contain no escapes. Reject all subordinate/bind mount ancestors.
    if any(m != '/' and (str(target) == m or str(target).startswith(m + '/'))
           for target in (path, bundle) for m in mounts):
        raise ValueError('Mounted production/source/backup paths are forbidden')
    if any((d / '.git').exists() for d in (base, *base.parents)):
        raise ValueError('Synthetic workspace must be outside Git')
    fs = subprocess.run(['/usr/bin/findmnt', '-n', '-o', 'FSTYPE', '-T', str(base)],
                        capture_output=True, check=True, text=True).stdout.strip()
    if fs != 'ext4' or shutil.disk_usage(base).free < GIB:
        raise ValueError('Privileged fixture requires existing ext4 and1GiB free reserve')
    path.mkdir(mode=0o700)  # atomic refusal on collision; never adopts a directory
    return path


def make_privileged_source(tree):
    cases = []
    def attempt(name, operation):
        try:
            operation()
            cases.append({'case': name, 'status': 'prepared'})
        except OSError as error:
            if error.errno not in (errno.EPERM, errno.EACCES, errno.EOPNOTSUPP, errno.EINVAL, errno.ENOSYS):
                raise
            cases.append({'case': name, 'status': 'unavailable', 'errno': error.errno})
    foreign = tree / 'foreign-owner'
    foreign.write_bytes(b'foreign numeric metadata only')
    foreign.chmod(0o600)
    attempt('foreign-uid-gid', lambda: os.chown(foreign, 65534, 65533))
    for name, kind in (('block-node', stat.S_IFBLK), ('char-node', stat.S_IFCHR)):
        # Major0 is not an operational host-device binding. Never open these nodes.
        attempt(name, lambda name=name, kind=kind: os.mknod(tree / name, kind | 0o600, os.makedev(0, 0)))
    capability = tree / 'capability-data'
    capability.write_bytes(b'non-executable capability metadata fixture')
    capability.chmod(0o600)
    attempt('security.capability', lambda: os.setxattr(capability, 'security.capability',
            struct.pack('<5I', 0x02000001, 1 << 10, 0, 0, 0)))
    attempt('trusted-xattr', lambda: os.setxattr(capability, 'trusted.revkit-fixture', b'synthetic'))
    for name, bit in (('immutable', 0x10), ('append-only', 0x20)):
        target = tree / name
        target.write_bytes(b'non-executable inode flag fixture')
        target.chmod(0o600)
        def set_flag(target=target, bit=bit):
            with target.open('rb') as stream:
                fcntl.ioctl(stream.fileno(), SETFLAGS, array.array('L', [flags(target) | bit]))
        attempt(name, set_flag)
    return cases


def privileged_complete(entries, cases):
    rows = {row['path']: row for row in entries}
    expected = {
        'foreign-uid-gid': lambda: (rows['foreign-owner']['uid'], rows['foreign-owner']['gid']) == (65534, 65533),
        'block-node': lambda: rows['block-node']['type'] == 'block' and rows['block-node']['deviceMajor'] == rows['block-node']['deviceMinor'] == 0,
        'char-node': lambda: rows['char-node']['type'] == 'character' and rows['char-node']['deviceMajor'] == rows['char-node']['deviceMinor'] == 0,
        'security.capability': lambda: rows['capability-data']['xattrs'].get('security.capability') == struct.pack('<5I', 0x02000001, 1 << 10, 0, 0, 0).hex(),
        'trusted-xattr': lambda: rows['capability-data']['xattrs'].get('trusted.revkit-fixture') == b'synthetic'.hex(),
        'immutable': lambda: bool(rows['immutable']['flags'] & 0x10),
        'append-only': lambda: bool(rows['append-only']['flags'] & 0x20),
    }
    if {c['case'] for c in cases} != set(expected):
        raise ValueError('Incomplete privileged case inventory')
    for case in cases:
        if case['status'] == 'prepared' and not expected[case['case']]():
            raise ValueError('Privileged source property was not actually observed: ' + case['case'])
    return all(c['status'] == 'prepared' for c in cases)


def fixture(parent=None, release_inputs=None, *, privileged=False, workspace=None, reviewed_source_sha256=None):
    if privileged:
        if platform.system() != 'Linux' or platform.machine() != 'x86_64' or not workspace or not release_inputs:
            raise ValueError('Privileged mode requires explicit Linux workspace and reviewed release bundle')
        root = privileged_workspace(workspace, release_inputs, reviewed_source_sha256)
        fs = 'ext4'
    else:
        if platform.system() != 'Linux' or platform.machine() != 'x86_64' or os.geteuid() == 0:
            raise ValueError('Fixture requires non-root Linux x86_64')
        parent = Path(parent).absolute()
        if parent.resolve() != parent or not parent.is_dir() or parent.stat().st_uid != os.getuid():
            raise ValueError('Fixture parent must be an existing canonical owner directory')
        if any((directory / '.git').exists() for directory in (parent, *parent.parents)):
            raise ValueError('Retained private fixture evidence must be outside source checkouts; explicit custody approval required')
        fs = subprocess.run(['/usr/bin/findmnt', '--noheadings', '--output', 'FSTYPE', '--target', str(parent)],
                            capture_output=True, check=True, text=True).stdout.strip()
        if fs != 'ext4':
            raise ValueError('Real metadata fixture requires ext4, no mount will be created')
        if shutil.disk_usage(parent).free < GIB:
            raise ValueError('Fixture requires1GiB reserve; fixed dataset under33MiB')
        root = Path(tempfile.mkdtemp(prefix='.revkit-borg-fixture-', dir=parent))
    env = private_env(root)
    receipt = {'schemaVersion': 1, 'scope': 'synthetic-borg-ext4-fixture', 'root': str(root),
               'observerSha256': digest(Path(__file__)), 'privilegedMode': privileged,
               'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'filesystem': fs, 'uid': os.getuid(), 'fullRestoreAccepted': False,
               'hardwareScope': 'single-filesystem developer fixture; no physical identity proof',
               'encryptedRepository': False, 'privilegedMetadataVerified': False,
               'productionExecutionAllowed': False, 'passed': False,
               'unprovedGates': ['encrypted key recovery', 'offline consistent source', 'full WSL restore', 'independent hardware recovery'],
               'unavailable': ['foreign UID/GID ownership (requires CAP_CHOWN)',
                               'block/character devices (requires CAP_MKNOD)',
                               'security/trusted xattrs and capabilities (privileged)',
                               'immutable/append-only flags (requires CAP_LINUX_IMMUTABLE)',
                               'encrypted key recovery; fixture uses no encryption key',
                               'offline WSL consistency, physical hardware failure and full restore/boot']}
    write_json(root / 'pending.json', receipt)
    try:
        binary = root / 'borg'
        signature = root / (ASSET + '.asc')
        public_key = root / 'release-key.asc'
        if release_inputs is None:
            fetch(RELEASE + ASSET, binary, 40 * 1024 * 1024, SHA256)
            fetch(RELEASE + ASSET + '.asc', signature, 8192, SIGNATURE_SHA256)
            fetch(KEY_URL, public_key, 1024 * 1024)
        else:
            # Reuse retained downloads, never execute them in place or trust a receipt.
            for target, limit in ((binary, 40 * 1024 * 1024), (signature, 8192), (public_key, 1024 * 1024)):
                source = Path(release_inputs) / target.name
                if source.is_symlink() or not source.is_file() or source.stat().st_size > limit:
                    raise ValueError('Invalid bounded release input')
                with source.open('rb') as incoming, target.open('xb') as outgoing:
                    shutil.copyfileobj(incoming, outgoing)
        receipt['tool'] = verify_tool(root, binary, signature, public_key, env)
        tree = root / 'source'
        make_source(tree, env)
        cases = make_privileged_source(tree) if privileged else []
        receipt['privilegedCases'] = cases
        before = observe(tree, env)
        write_json(root / 'source-inventory.json', before)
        privileged_ready = privileged_complete(before, cases) if privileged else False
        archive = str(root / 'repository') + '::synthetic'
        steps = []
        receipt['steps'] = steps
        def borg(*args, cwd=root):
            # No commands or source paths are supplied by the caller.
            result = run([str(binary), *args], cwd=cwd, env=env)
            if result.stderr:
                raise RuntimeError('Borg emitted unexpected diagnostics: ' + result.stderr.decode(errors='replace')[:2000])
            steps.append({'command': list(args), 'exitCode': result.returncode, 'stderrBytes': 0})
            return result
        borg('init', '--encryption=none', str(root / 'repository'))
        borg('create', '--numeric-ids', '--atime', '--files-cache=disabled', archive, 'source')
        # Rename the synthetic tree out of its original location, with no traversal
        # or argument referencing it during check/extraction. This is path absence,
        # not a production disk-offline claim or an access-control boundary.
        tree.rename(root / 'source-unavailable')
        borg('check', '--verify-data', str(root / 'repository'))
        restored = root / 'restored'
        restored.mkdir(mode=0o700)
        borg('extract', '--dry-run', '--numeric-ids', archive, cwd=restored)
        borg('extract', '--numeric-ids', '--sparse', archive, cwd=restored)
        after = observe(restored / 'source', env)
        write_json(root / 'restored-inventory.json', after)
        receipt['allocationBudget'] = compare(before, after)
        receipt['verifiedPrivilegedCases'] = [case['case'] for case in cases if case['status'] == 'prepared']
        complete = not privileged or privileged_ready
        receipt['privilegedMetadataVerified'] = privileged and complete
        if privileged:
            receipt['unavailable'] = [case['case'] for case in cases if case['status'] != 'prepared']
        receipt.update(passed=complete, steps=steps, entries=len(before), sourcePathAbsent=not tree.exists(),
                       sourceUnavailableProof='renamed synthetic source; not OS-enforced disk isolation',
                       sparseLimitation='Chunk-based sparse output does not preserve every original hole; logical allocation bounds remain required',
                       coverage=['content SHA256, case-sensitive filenames, size',
                                 'current numeric UID/GID, modes, nanosecond mtime/atime',
                                 'access/default POSIX ACLs, user xattrs',
                                 'directory/root metadata, symlinks, hardlink groups, FIFO',
                                 'NODUMP inode flag, sparse content and allocated-hole observation'])
        write_json(root / 'result.json', receipt)
        return receipt
    except Exception as exc:
        receipt['failure'] = str(exc)
        receipt['failureErrno'] = getattr(exc, 'errno', None)
        write_json(root / 'failed.json', receipt)
        raise RuntimeError(f'Fixture refused; retained evidence at {root}: {exc}') from exc


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--privileged-plan', action='store_true', help='Read-only source/release hashes and controller argv')
    parser.add_argument('--run-privileged', action='store_true', help='Controller-only synthetic root metadata mode')
    parser.add_argument('--workspace', type=Path, help='NEW UUID leaf under fixed root-owned synthetic base')
    parser.add_argument('--reviewed-source-sha256')
    parser.add_argument('--run', action='store_true', help='Download/verify tool and run fixed synthetic fixture only')
    parser.add_argument('--parent', type=Path, help='Existing private ext4 development directory, never a real disk root')
    parser.add_argument('--release-inputs', type=Path, help='Optional retained downloads; all provenance is reverified')
    args = parser.parse_args()
    if args.privileged_plan:
        sha = digest(Path(__file__))
        workspace = PRIVILEGED_BASE / '00000000-0000-4000-8000-000000000001'
        bundle = PRIVILEGED_TOOLS / sha
        print(json.dumps({'sourceSha256': sha, 'binarySha256': SHA256, 'signatureSha256': SIGNATURE_SHA256,
            'publicKeySha256': PUBLIC_KEY_SHA256, 'bundle': str(bundle), 'workspaceMustBeNew': str(workspace),
            'controllerArgv': ['/usr/bin/env', '-i', 'PATH=/usr/bin:/bin', '/usr/bin/python3', '-I', '-B',
                str(bundle / 'wsl-borg-fixture.py'), '--run-privileged', '--workspace', str(workspace),
                '--release-inputs', str(bundle), '--reviewed-source-sha256', sha],
            'productionExecutionAllowed': False}, indent=2))
        return
    if args.run and args.run_privileged:
        parser.error('Ordinary and privileged modes are mutually exclusive')
    if args.run_privileged:
        if args.parent:
            parser.error('Privileged mode does not accept an ordinary parent')
        result = fixture(release_inputs=args.release_inputs, privileged=True, workspace=args.workspace,
                         reviewed_source_sha256=args.reviewed_source_sha256)
        print(json.dumps(result, indent=2))
        if not result['passed']:
            raise SystemExit(3)
    elif args.run:
        if args.parent is None:
            parser.error('--run requires --parent')
        print(json.dumps(fixture(args.parent, args.release_inputs), indent=2))
    else:
        print(json.dumps({'canExecuteProduction': False, 'fixtureRequiresExplicitRun': True,
                          'version': VERSION, 'asset': ASSET, 'sha256': SHA256,
                          'releaseFingerprint': FINGERPRINT, 'requires': 'non-root ext4 private fixture; network approval',
                          'fullRestoreAccepted': False}, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error)) from error

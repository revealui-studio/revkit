#!/usr/bin/env python3
"""Private synthetic Borg observer; never backs up an operator-supplied source.

Extends WslBackup.ps1's evidence design with actual Linux fixture observations.
No production executor, mount, user key, retention or system installation.
"""
import argparse
import configparser
from contextlib import contextmanager
import secrets
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
    for path, expected in ((binary, SHA256), (signature, SIGNATURE_SHA256),
                           (public_key, PUBLIC_KEY_SHA256)):
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


def ordinary_workspace(parent):
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
        raise ValueError('Fixture requires1GiB free before bounded synthetic run; no savings credit')
    return Path(tempfile.mkdtemp(prefix='.revkit-borg-fixture-', dir=parent)), fs


def prepare_tool(root, release_inputs, env):
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
    return binary, verify_tool(root, binary, signature, public_key, env)


DEFAULT_PROFILE = 'legacy-default-v1'
CANDIDATE_PROFILE = 'fixed64k-input-holes-v1'
CANDIDATE_LOGICAL_LIMIT = 128 * 1024 * 1024
FIXED_CHUNK_BYTES = 65536


def fixture_profile(name):
    if name not in (DEFAULT_PROFILE, CANDIDATE_PROFILE):
        raise ValueError('Unknown reviewed synthetic profile')
    return {'id': name, 'createOptions': (['--chunker-params=fixed,65536', '--sparse']
            if name == CANDIDATE_PROFILE else []), 'extractOptions': ['--sparse'],
            'comparisonPolicy': 'exact-content-metadata-and-sparse-boolean-v1',
            'dataset': 'ordinary-plus-expanded-layouts-v1' if name == CANDIDATE_PROFILE else 'ordinary-v1',
            'productionExecutionAllowed': False}


def make_candidate_layouts(tree):
    make_sparse_matrix(tree)  # Reuse the five cases without altering the old protocol.
    (tree / 'empty').touch(mode=0o600)
    with (tree / 'all-hole').open('xb') as stream:
        stream.truncate(131073)
    with (tree / 'unaligned-hole').open('xb') as stream:
        stream.write(b'head')
        stream.seek(100003)
        stream.write(b'tail')
    with (tree / 'short-block-hole').open('xb') as stream:
        stream.write(b'A' * 4096)
        stream.seek(8192)
        stream.write(b'B' * 4096)
    with (tree / 'short-logical-gap').open('xb') as stream:
        stream.write(b'prefix' * 100)
        stream.seek(857)
        stream.write(b'tail')
    with (tree / 'trailing-hole').open('xb') as stream:
        stream.write(b'head')
        stream.truncate(262145)
    # Actual writes, not truncate/fallocate: dense-zero versus hole is intentional.
    with (tree / 'dense-zero').open('xb') as stream:
        stream.write(bytes(262144))
        stream.flush()
        os.fsync(stream.fileno())
    with (tree / 'dense-mixed').open('xb') as stream:
        stream.write(bytes(range(256)) * 256)
        stream.write(bytes(65536))
        stream.write(bytes(range(256)) * 256)
        stream.flush()
        os.fsync(stream.fileno())
    for path in [*tree.iterdir(), tree]:
        os.utime(path, ns=(1900000000123456789, 1700000100987654321))


def observed_ranges(tree, entries):
    """SEEK_DATA/HOLE observations of generated regular files only; no extent equality promise."""
    result = {}
    for row in entries:
        if row['type'] != 'file':
            continue
        path = tree / row['path']
        if path.is_symlink() or not stat.S_ISREG(path.lstat().st_mode):
            raise ValueError('Range observer refuses non-regular synthetic entries')
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NOATIME)
        ranges = []
        try:
            offset, size = 0, row['size']
            while offset < size:
                try:
                    data = min(os.lseek(fd, offset, os.SEEK_DATA), size)
                except OSError as error:
                    if error.errno != errno.ENXIO:
                        raise  # Unsupported SEEK_HOLE is an evidence gap, not a fake map.
                    data = size
                if data > offset:
                    ranges.append({'offset': offset, 'bytes': data-offset, 'data': False})
                if data < size:
                    end = min(os.lseek(fd, data, os.SEEK_HOLE), size)
                    if end <= data:
                        raise ValueError('Non-progressing synthetic range observation')
                    ranges.append({'offset': data, 'bytes': end-data, 'data': True})
                    offset = end
                else:
                    offset = size
                if len(ranges) > 256:
                    raise ValueError('Bounded synthetic range census exceeded')
        finally:
            os.close(fd)
        result[row['path']] = ranges
    return result


def candidate_cost(entries, ranges):
    """Fixture arithmetic and upstream sensitivity, NEVER a production upper bound."""
    files = [row for row in entries if row['type'] == 'file']
    if len(entries) > 64 or set(ranges) != {row['path'] for row in files}:
        raise ValueError('Complete bounded fixture file/range census required')
    logical, references, range_count = 0, 0, 0
    for row in files:
        size = row['size']
        if type(size) is not int or size < 0:
            raise ValueError('Nonnegative integer logical length required')
        logical += size
        offset = 0
        if len(ranges[row['path']]) > 256:
            raise ValueError('Bounded synthetic range census exceeded')
        for part in ranges[row['path']]:
            if (type(part['bytes']) is not int or part['bytes'] <= 0 or
                type(part['offset']) is not int or part['offset'] != offset or
                type(part['data']) is not bool):
                raise ValueError('Complete contiguous observed ranges required')
            offset += part['bytes']
            references += (part['bytes'] + FIXED_CHUNK_BYTES-1) // FIXED_CHUNK_BYTES
            range_count += 1
        if offset != size:
            raise ValueError('Range census differs from logical length')
    if logical > CANDIDATE_LOGICAL_LIMIT:
        raise ValueError('Candidate exceeds128MiB logical fixture limit; no savings credit')
    return {'logicalDataBytes': logical, 'logicalLimitBytes': CANDIDATE_LOGICAL_LIMIT,
            'regularPathsIncludingHardlinkAliases': len(files), 'observedRanges': range_count,
            'fixedDataChunkReferencesNoReuseModel': references,
            'indexAndChunksCacheBaseSensitivityBytes': references * (40+44),
            'indexAndChunksCacheGrowthSensitivityBytes': references * (40+44) * 4 * 3,
            'filesCache': 'disabled; chunk cache and repository indexes remain',
            'sparseCreditBytes': 0, 'compressionCreditBytes': 0, 'dedupCreditBytes': 0,
            'productionBudgetAccepted': False, 'fullSourceCensus': False,
            'limitations': ['Upstream index/cache factors are estimates, not RSS or disk bounds',
                'No metadata chunks, existing generations, runtime/crypto/buffers, extent-list object costs',
                'No cache transaction copies, archive indexes, segment/temp growth or filesystem metadata bound',
                'Full source file/range/metadata census and per-filesystem budgets remain missing']}


def candidate_preconditions(entries, ranges):
    rows = {row['path']: row for row in entries}
    expected = {'empty': False, 'all-hole': True, 'unaligned-hole': True,
                'short-block-hole': True, 'short-logical-gap': False,
                'trailing-hole': True, 'dense-zero': False, 'dense-mixed': False}
    for name, sparse in expected.items():
        key = 'layouts/' + name
        if key not in rows or rows[key]['sparse'] is not sparse:
            raise ValueError('Synthetic layout source property unavailable: ' + name)
        if name.startswith('dense-') and any(not part['data'] for part in ranges[key]):
            raise ValueError('Dense fixture unexpectedly has source holes: ' + name)
    if rows['layouts/empty']['size'] != 0 or any(part['data'] for part in ranges['layouts/all-hole']):
        raise ValueError('Empty/all-hole source preconditions unavailable')


def candidate_assessment(before, after, cases, privileged):
    report = sparse_assessment(before, after)
    expected_layouts = {'empty', 'all-hole', 'unaligned-hole', 'short-block-hole',
                        'short-logical-gap', 'trailing-hole', 'dense-zero', 'dense-mixed',
                        'small-8KiB', 'medium-256KiB', 'retained-shape-8MiB', 'large-32MiB', 'mixed-8MiB'}
    dataset_complete = {'layouts/' + name for name in expected_layouts}.issubset({row['path'] for row in before})
    paths = {'foreign-uid-gid': 'foreign-owner', 'block-node': 'block-node',
             'char-node': 'char-node', 'security.capability': 'capability-data',
             'trusted-xattr': 'capability-data', 'immutable': 'immutable', 'append-only': 'append-only'}
    verified = []
    for case in cases:
        if case['status'] == 'prepared':
            path = paths[case['case']]
            left = [row for row in before if row['path'] == path]
            right = [row for row in after if row['path'] == path]
            if not left or not right:
                continue
            try:
                compare(left, right)
                verified.append(case['case'])
            except ValueError:
                pass
    metadata = privileged and privileged_complete(before, cases) and len(verified) == 7
    return {'profileId': CANDIDATE_PROFILE, 'strictInventory': report, 'layoutDatasetComplete': dataset_complete,
            'verifiedPrivilegedCases': verified, 'privilegedMetadataVerified': metadata,
            'combinedCandidateAccepted': bool(metadata and report['accepted'] and dataset_complete),
            'productionReady': False}


def fixture(parent=None, release_inputs=None, *, privileged=False, workspace=None, reviewed_source_sha256=None, profile=DEFAULT_PROFILE):
    selected_profile = fixture_profile(profile)
    candidate = profile == CANDIDATE_PROFILE
    if privileged:
        if platform.system() != 'Linux' or platform.machine() != 'x86_64' or not workspace or not release_inputs:
            raise ValueError('Privileged mode requires explicit Linux workspace and reviewed release bundle')
        root = privileged_workspace(workspace, release_inputs, reviewed_source_sha256)
        fs = 'ext4'
    else:
        root, fs = ordinary_workspace(parent)
    env = private_env(root)
    receipt = {'schemaVersion': 1, 'scope': 'synthetic-borg-ext4-fixture', 'root': str(root),
               'observerSha256': digest(Path(__file__)), 'privilegedMode': privileged,
               'archiveProfile': selected_profile, 'combinedCandidateAccepted': False,
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
        binary, receipt['tool'] = prepare_tool(root, release_inputs, env)
        tree = root / 'source'
        make_source(tree, env)
        if candidate:
            make_candidate_layouts(tree / 'layouts')
        cases = make_privileged_source(tree) if privileged else []
        receipt['privilegedCases'] = cases
        before = observe(tree, env)
        write_json(root / 'source-inventory.json', before)
        if candidate:
            layout = observed_ranges(tree, before)
            write_json(root / 'source-ranges.json', layout)
            receipt['fixtureCost'] = candidate_cost(before, layout)
            candidate_preconditions(before, layout)
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
        borg('create', '--numeric-ids', '--atime', '--files-cache=disabled', *selected_profile['createOptions'], archive, 'source')
        # Rename the synthetic tree out of its original location, with no traversal
        # or argument referencing it during check/extraction. This is path absence,
        # not a production disk-offline claim or an access-control boundary.
        tree.rename(root / 'source-unavailable')
        borg('check', '--verify-data', str(root / 'repository'))
        restored = root / 'restored'
        restored.mkdir(mode=0o700)
        borg('extract', '--dry-run', '--numeric-ids', archive, cwd=restored)
        borg('extract', '--numeric-ids', *selected_profile['extractOptions'], archive, cwd=restored)
        after = observe(restored / 'source', env)
        write_json(root / 'restored-inventory.json', after)
        if candidate:
            restored_ranges = observed_ranges(restored / 'source', after)
            write_json(root / 'restored-ranges.json', restored_ranges)
            receipt['candidateAssessment'] = candidate_assessment(before, after, cases, privileged)
            assessment = receipt['candidateAssessment']
            receipt['verifiedPrivilegedCases'] = assessment['verifiedPrivilegedCases']
            receipt['privilegedMetadataVerified'] = assessment['privilegedMetadataVerified']
            receipt['combinedCandidateAccepted'] = assessment['combinedCandidateAccepted']
            complete = assessment['strictInventory']['accepted'] and assessment['layoutDatasetComplete'] and (not privileged or privileged_ready)
        else:
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


def private_secret(path, value):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(value)
        stream.flush()
        os.fsync(stream.fileno())


@contextmanager
def secret_descriptor(passphrase, env):
    if any(name in env for name in ('BORG_PASSPHRASE', 'BORG_NEW_PASSPHRASE', 'BORG_PASSCOMMAND')):
        raise ValueError('Secret environment-value fallback refused')
    info = passphrase.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise ValueError('Synthetic passphrase requires owner-only regular custody')
    fd = os.open(passphrase, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        yield fd, dict(env, BORG_PASSPHRASE_FD=str(fd), BORG_EXIT_CODES='modern')
    finally:
        os.close(fd)


def recovery_borg(binary, args, *, cwd, env, passphrase, expected_exit=0):
    """Only private synthetic secrets; never propagate command output on failure."""
    with secret_descriptor(passphrase, env) as (fd, child_env):
        result = subprocess.run([str(binary), *args], cwd=cwd, env=child_env,
                                stdin=subprocess.DEVNULL, capture_output=True, pass_fds=(fd,),
                                timeout=120, check=False)
    if result.returncode != expected_exit:
        raise RuntimeError('Synthetic Borg recovery step refused; exit=' + str(result.returncode))
    # Even successful output may contain sensitive configuration. Retain counts only.
    return {'exitCode': result.returncode, 'stdoutBytes': len(result.stdout),
            'stderrBytes': len(result.stderr), 'expectedFailure': expected_exit != 0}


def make_sparse_matrix(tree):
    """Fixed bounded ext4 cases; no source arguments, scanning or live data."""
    tree.mkdir(mode=0o700)
    for name, size, mixed in (('small-8KiB', 8192, False),
                              ('medium-256KiB', 256*1024, False),
                              ('retained-shape-8MiB', 8*1024*1024, False),
                              ('large-32MiB', 32*1024*1024, False),
                              ('mixed-8MiB', 8*1024*1024, True)):
        path = tree / name
        with path.open('xb') as stream:
            stream.write(b'head')
            if mixed:
                stream.seek(size//2)
                stream.write(bytes(range(256))*256)
            stream.seek(size)
            stream.write(b'tail')
        path.chmod(0o640)
        os.setxattr(path, 'user.revkit-matrix', b'synthetic')
    for path in [*tree.iterdir(), tree]:
        os.utime(path, ns=(1900000000123456789, 1700000100987654321))


def sparse_assessment(before, after):
    """Strict acceptance unchanged; report each rejected case without hiding others."""
    observations = []
    right = {row['path']: row for row in after}
    for row in before:
        restored = right.get(row['path'])
        try:
            budget = compare([row], [restored] if restored else [])
            observations.append({'path': row['path'], 'accepted': True, 'allocationBudget': budget})
        except ValueError as exc:
            observations.append({'path': row['path'], 'accepted': False, 'reason': str(exc)})
    # Whole-tree comparison also detects unexpected entries.
    try:
        budget = compare(before, after)
        return {'accepted': True, 'cases': observations, 'allocationBudget': budget}
    except ValueError as exc:
        return {'accepted': False, 'cases': observations, 'reason': str(exc), 'sparseCreditBytes': 0}


def remove_synthetic_key(root, repo, exported_key):
    if (repo != root / 'repository' or repo.is_symlink() or
        exported_key != root / 'recovery-artifacts/exported-key' or
        exported_key.is_symlink() or not exported_key.is_file() or
        (repo / 'lock.exclusive').exists()):
        raise ValueError('Synthetic key loss requires fresh unlocked fixture and retained export')
    config = configparser.ConfigParser()
    path = repo / 'config'
    if path.is_symlink():
        raise ValueError('Synthetic config symlink refused')
    config.read(path)
    if not config.remove_option('repository', 'key'):
        raise ValueError('Synthetic embedded key already absent')
    temporary = repo / 'config.synthetic-key-loss'
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream:
        config.write(stream)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    del config
    observed = configparser.ConfigParser()
    observed.read(path)
    if observed.has_option('repository', 'key'):
        raise ValueError('Synthetic key loss did not occur')


def recovery_fixture(parent, release_inputs):
    """New synthetic repokey only; no arbitrary repository/key/source inputs."""
    root, fs = ordinary_workspace(parent)
    env = private_env(root)
    receipt = {'schemaVersion': 1, 'scope': 'synthetic-encrypted-recovery-sparse-matrix',
               'root': str(root), 'filesystem': fs, 'observerSha256': digest(Path(__file__)),
               'productionExecutionAllowed': False, 'fullRestoreAccepted': False,
               'offLaptopKeyCustodyProved': False, 'encryptedKeyRecoveryVerified': False,
               'completed': False, 'sparseCreditBytes': 0, 'steps': []}
    write_json(root / 'pending.json', receipt)
    try:
        binary, receipt['tool'] = prepare_tool(root, release_inputs, env)
        original = root / 'original-client'
        original.mkdir(mode=0o700)
        original_env = private_env(original)
        recovery = root / 'recovery-artifacts'
        recovery.mkdir(mode=0o700)
        secret = secrets.token_hex(32).encode() + b'\n'
        private_secret(original / 'passphrase', secret)
        private_secret(recovery / 'passphrase', secret)
        del secret
        private_secret(root / 'wrong-passphrase', secrets.token_hex(32).encode() + b'\n')
        repo = root / 'repository'
        archive = str(repo) + '::'
        def borg(label, args, client_env, phrase, *, cwd=root, expected_exit=0):
            step = recovery_borg(binary, args, cwd=cwd, env=client_env,
                                 passphrase=phrase, expected_exit=expected_exit)
            receipt['steps'].append(dict(step, label=label))
        phrase = original / 'passphrase'
        borg('init-repokey-blake2', ['init', '--encryption=repokey-blake2', str(repo)], original_env, phrase)
        tree = root / 'source'
        make_sparse_matrix(tree)
        before = observe(tree, env)
        write_json(root / 'source-inventory.json', before)
        policies = [('default', []), ('fixed-64KiB', ['--chunker-params=fixed,65536', '--sparse'])]
        for name, options in policies:
            borg('create-' + name, ['create', '--numeric-ids', '--atime', '--files-cache=disabled',
                                   *options, archive+name, 'source'], original_env, phrase)
        key = recovery / 'exported-key'
        borg('export-key', ['key', 'export', str(repo), str(key)], original_env, phrase)
        key.chmod(0o600)
        # Fault injection, NOT an operational Borg configuration command. Borg's
        # config CLI intentionally does not expose key deletion. Only our fresh
        # private synthetic repository is altered, after independent key export.
        remove_synthetic_key(root, repo, key)
        receipt['steps'].append({'label': 'synthetic-embedded-key-loss-injection'})
        original.rename(root / 'original-client-unavailable')
        tree.rename(root / 'source-unavailable')
        fresh = root / 'fresh-client'
        fresh.mkdir(mode=0o700)
        fresh_env = private_env(fresh)
        recovery_phrase = recovery / 'passphrase'
        borg('missing-key-negative-control', ['list', str(repo)], fresh_env, recovery_phrase, expected_exit=44)
        borg('import-exported-key', ['key', 'import', str(repo), str(key)], fresh_env, recovery_phrase)
        borg('wrong-passphrase-negative-control', ['list', str(repo)], fresh_env,
             root / 'wrong-passphrase', expected_exit=52)
        borg('verify-data-fresh-client', ['check', '--verify-data', str(repo)], fresh_env, recovery_phrase)
        receipt['sparseMatrix'] = {}
        for name, options in policies:
            target = root / ('restored-' + name)
            target.mkdir(mode=0o700)
            borg('extract-' + name, ['extract', '--numeric-ids', '--sparse', archive+name],
                 fresh_env, recovery_phrase, cwd=target)
            after = observe(target / 'source', env)
            write_json(root / ('restored-' + name + '-inventory.json'), after)
            receipt['sparseMatrix'][name] = sparse_assessment(before, after)
        # Encryption/key acceptance requires actual restored content AND all non-allocation metadata.
        # Sparse rejection remains separately visible and cannot make full recovery green.
        after_without_sparse = [{**row, 'sparse': False} for row in after]
        before_without_sparse = [{**row, 'sparse': False} for row in before]
        compare(before_without_sparse, after_without_sparse)
        receipt.update(completed=True, encryptedKeyRecoveryVerified=True,
                       originalKeyRemovedBeforeImport=True, originalClientPathAbsent=not original.exists(),
                       sourcePathAbsent=not tree.exists(),
                       isolation='Original paths renamed; not OS-enforced inaccessible or off-laptop custody',
                       encryption='repokey-blake2', logicalSourceBytes=sum(row['size'] or 0 for row in before),
                       unprovedGates=['off-laptop independent key/passphrase custody', 'offline consistent source',
                                      'full WSL restore', 'independent hardware recovery', 'arbitrary sparse layouts'])
        write_json(root / 'result.json', receipt)
        return receipt
    except Exception as exc:
        # Never serialize backend stdout/stderr, key bytes or passphrase values.
        receipt['failure'] = type(exc).__name__ + ': synthetic recovery refused'
        write_json(root / 'failed.json', receipt)
        raise RuntimeError(f'Synthetic recovery refused; evidence retained at {root}; {type(exc).__name__}') from None


CONTAINER_PROFILE = 'cold-vhd-container-v1'
CONTAINER_CHUNK = 4 * 1024 * 1024


def binary_transaction(command, *, cwd, env, source, target, expected_input, expected_output,
                       expected_output_sha256, pass_fds=(), timeout=120):
    """Linux binary mechanics; fixed callers only, bounded pipes, no shell/text conversion."""
    import selectors
    import time
    if expected_input < 0 or expected_output < 0 or not 0 < timeout <= 86400:
        raise ValueError('Finite binary bounds required')
    child = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, pass_fds=pass_fds, start_new_session=True)
    input_count = output_count = errors = 0
    input_hash, output_hash = hashlib.sha256(), hashlib.sha256()
    pending = b''
    deadline = time.monotonic() + timeout
    try:
        with selectors.DefaultSelector() as poll:
            for pipe, event, role in ((child.stdin, selectors.EVENT_WRITE, 'input'),
                                      (child.stdout, selectors.EVENT_READ, 'output'),
                                      (child.stderr, selectors.EVENT_READ, 'error')):
                os.set_blocking(pipe.fileno(), False)
                poll.register(pipe, event, role)
            while poll.get_map():
                if time.monotonic() >= deadline:
                    raise TimeoutError('Binary transaction timeout')
                for key, events in poll.select(min(.1, max(0, deadline-time.monotonic()))):
                    pipe = key.fileobj
                    if key.data == 'input':
                        if not pending:
                            pending = source.read(65536)
                            if not pending:
                                if input_count != expected_input:
                                    raise ValueError('Binary input truncated')
                                poll.unregister(pipe)
                                pipe.close()
                                continue
                            if len(pending) > expected_input-input_count:
                                raise ValueError('Binary input exceeds bound')
                            input_hash.update(pending)
                            input_count += len(pending)
                        sent = os.write(pipe.fileno(), pending)
                        pending = pending[sent:]
                    else:
                        data = os.read(pipe.fileno(), 65536)
                        if not data:
                            poll.unregister(pipe)
                            pipe.close()
                        elif key.data == 'error':
                            errors += len(data)
                            if errors > 65536:
                                raise ValueError('Binary diagnostic limit exceeded')
                        else:
                            if len(data) > expected_output-output_count:
                                raise ValueError('Binary output exceeds bound')
                            if target.write(data) != len(data):
                                raise ValueError('Binary output short write')
                            output_hash.update(data)
                            output_count += len(data)
            code = child.wait(timeout=max(.001, deadline-time.monotonic()))
        if code != 0 or errors or output_count != expected_output or output_hash.hexdigest() != expected_output_sha256:
            raise ValueError('Binary output/diagnostics/exit rejected')
        target.flush()
        return {'inputBytes': input_count, 'inputSha256': input_hash.hexdigest(),
                'outputBytes': output_count, 'outputSha256': output_hash.hexdigest(),
                'exitCode': code, 'stderrBytes': errors}
    except Exception:
        if child.poll() is None:
            import signal
            os.killpg(child.pid, signal.SIGKILL)
        child.wait(timeout=5)
        raise RuntimeError('Binary transaction refused; retained partial output; diagnostics withheld') from None
    finally:
        for pipe in (child.stdin, child.stdout, child.stderr):
            pipe.close()


def container_fixture(parent, release_inputs):
    import io
    root, fs = ordinary_workspace(parent)
    env = private_env(root)
    receipt = {'schemaVersion': 1, 'profile': CONTAINER_PROFILE, 'scope': 'synthetic-opaque-bytes-only',
               'root': str(root), 'observerSha256': digest(Path(__file__)), 'passed': False,
               'productionExecutionAllowed': False, 'validVhdProved': False, 'fullRestoreAccepted': False,
               'windowsLeaseAccepted': False, 'crossDistroTransportAccepted': False,
               'savingsCreditBytes': 0, 'steps': []}
    write_json(root / 'pending.json', receipt)
    try:
        binary, receipt['tool'] = prepare_tool(root, release_inputs, env)
        original = root / 'original-client'
        original.mkdir(mode=0o700)
        original_env = private_env(original)
        recovery = root / 'recovery-artifacts'
        recovery.mkdir(mode=0o700)
        phrase = secrets.token_hex(32).encode() + b'\n'
        private_secret(original / 'passphrase', phrase)
        private_secret(recovery / 'passphrase', phrase)
        del phrase
        private_secret(root / 'wrong-passphrase', secrets.token_hex(32).encode() + b'\n')
        source = root / 'synthetic-container.bin'
        with source.open('xb') as stream:
            stream.write(os.urandom(4*1024*1024))
            stream.write(bytes(2*1024*1024))
            stream.write(bytes(range(256))*8192)
            stream.write(b'opaque-end\x00\xff\n')
            stream.flush()
            os.fsync(stream.fileno())
        size, sha = source.stat().st_size, digest(source)
        receipt.update(sourceBytes=size, sourceSha256=sha)
        repo = root / 'repository'
        archive = str(repo) + '::opaque'
        def control(label, args, client_env, passphrase, expected_exit=0):
            status = recovery_borg(binary, args, cwd=root, env=client_env,
                                   passphrase=passphrase, expected_exit=expected_exit)
            receipt['steps'].append(dict(status, label=label))
        def transfer(label, args, client_env, passphrase, incoming, outgoing, in_bytes, out_bytes, out_sha):
            # No secret values in argv/environment or diagnostics; only inherited FD number.
            with secret_descriptor(passphrase, client_env) as (fd, child_env):
                status = binary_transaction([str(binary), *args], cwd=root, env=child_env,
                    source=incoming, target=outgoing, expected_input=in_bytes,
                    expected_output=out_bytes, expected_output_sha256=out_sha, pass_fds=(fd,))
            receipt['steps'].append(dict(status, label=label))
            return status
        phrase = original / 'passphrase'
        control('init', ['init','--encryption=repokey-blake2',str(repo)], original_env, phrase)
        create_options = ['--chunker-params=fixed,4194304','--files-cache=disabled',
                          '--compression=none','--stdin-name=ext4.vhdx']
        receipt['createOptions'] = create_options
        empty_sha = hashlib.sha256(b'').hexdigest()
        with source.open('rb') as incoming:
            status = transfer('binary-stdin-create', ['create',*create_options,archive,'-'],
                              original_env, phrase, incoming, io.BytesIO(), size, 0, empty_sha)
        if status['inputSha256'] != sha:
            raise ValueError('Source stream differs from generated original')
        exported = recovery / 'exported-key'
        control('key-export', ['key','export',str(repo),str(exported)], original_env, phrase)
        exported.chmod(0o600)
        remove_synthetic_key(root, repo, exported)
        original.rename(root / 'original-client-unavailable')
        source.rename(root / 'source-unavailable')
        fresh = root / 'fresh-client'
        fresh.mkdir(mode=0o700)
        fresh_env = private_env(fresh)
        phrase = recovery / 'passphrase'
        control('missing-key', ['list',str(repo)], fresh_env, phrase, 44)
        control('key-import', ['key','import',str(repo),str(exported)], fresh_env, phrase)
        control('wrong-passphrase', ['list',str(repo)], fresh_env, root / 'wrong-passphrase', 52)
        control('verify-data', ['check','--verify-data',str(repo)], fresh_env, phrase)
        restored = root / 'restored-dense.bin'
        with restored.open('xb') as outgoing:
            transfer('extract-binary-stdout', ['extract','--stdout',archive,'ext4.vhdx'],
                     fresh_env, phrase, io.BytesIO(), outgoing, 0, size, sha)
            outgoing.flush()
            os.fsync(outgoing.fileno())
        if restored.stat().st_size != size or digest(restored) != sha:
            raise ValueError('Independent restored all-byte verification rejected')
        receipt.update(passed=True, restoredBytes=size, restoredSha256=digest(restored),
                       sourceOriginalPathAbsent=not source.exists(), originalClientPathAbsent=not original.exists(),
                       encryptedSyntheticKeyRecovery=True,
                       sourceUnavailableScope='renamed synthetic path; not OS isolation or real cold VHD',
                       dataChunkReferencesNoReuseModel=(size+CONTAINER_CHUNK-1)//CONTAINER_CHUNK,
                       unprovedGates=['actual Windows source lease/process transport','selected independent worker',
                           'cold VHD consistency','independent hardware and key custody','resource overhead',
                           'full image byte verification and isolated import/boot'])
        write_json(root / 'result.json', receipt)
        return receipt
    except Exception as exc:
        receipt['failure'] = type(exc).__name__ + ': synthetic container refused'
        write_json(root / 'failed.json', receipt)
        raise RuntimeError(f'Synthetic container refused; retained at {root}; {type(exc).__name__}') from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', choices=(DEFAULT_PROFILE, CANDIDATE_PROFILE), default=DEFAULT_PROFILE,
                        help='Named reviewed archive profile; default unchanged')
    parser.add_argument('--privileged-plan', action='store_true', help='Read-only source/release hashes and controller argv')
    parser.add_argument('--run-privileged', action='store_true', help='Controller-only synthetic root metadata mode')
    parser.add_argument('--workspace', type=Path, help='NEW UUID leaf under fixed root-owned synthetic base')
    parser.add_argument('--reviewed-source-sha256')
    parser.add_argument('--run-container', action='store_true', help='Fixed synthetic encrypted binary-container fixture only')
    parser.add_argument('--run-recovery', action='store_true', help='New synthetic encrypted recovery and sparse matrix only')
    parser.add_argument('--run', action='store_true', help='Download/verify tool and run fixed synthetic fixture only')
    parser.add_argument('--parent', type=Path, help='Existing private ext4 development directory, never a real disk root')
    parser.add_argument('--release-inputs', type=Path, help='Optional retained downloads; all provenance is reverified')
    args = parser.parse_args()
    if args.privileged_plan:
        sha = digest(Path(__file__))
        workspace = PRIVILEGED_BASE / str(uuid.uuid4())
        bundle = PRIVILEGED_TOOLS / sha
        print(json.dumps({'sourceSha256': sha, 'binarySha256': SHA256, 'signatureSha256': SIGNATURE_SHA256,
            'publicKeySha256': PUBLIC_KEY_SHA256, 'archiveProfile': fixture_profile(args.profile), 'bundle': str(bundle), 'workspaceMustBeNew': str(workspace),
            'controllerArgv': ['/usr/bin/env', '-i', 'PATH=/usr/bin:/bin', '/usr/bin/python3', '-I', '-B',
                str(bundle / 'wsl-borg-fixture.py'), '--run-privileged', '--workspace', str(workspace),
                '--release-inputs', str(bundle), '--reviewed-source-sha256', sha, '--profile', args.profile],
            'privilegedMode': True, 'productionExecutionAllowed': False}, indent=2))
        return
    if sum((args.run, args.run_privileged, args.run_recovery, args.run_container)) > 1:
        parser.error('Ordinary and privileged modes are mutually exclusive')
    if args.run_privileged:
        if args.parent:
            parser.error('Privileged mode does not accept an ordinary parent')
        result = fixture(release_inputs=args.release_inputs, privileged=True, workspace=args.workspace,
                         reviewed_source_sha256=args.reviewed_source_sha256, profile=args.profile)
        print(json.dumps(result, indent=2))
        if not result['passed']:
            raise SystemExit(3)
    elif args.run_container:
        if args.parent is None or args.workspace or args.reviewed_source_sha256 or args.profile != DEFAULT_PROFILE:
            parser.error('--run-container requires ordinary parent and distinct fixed container protocol')
        print(json.dumps(container_fixture(args.parent, args.release_inputs), indent=2))
    elif args.run_recovery:
        if args.parent is None or args.workspace or args.reviewed_source_sha256 or args.profile != DEFAULT_PROFILE:
            parser.error('--run-recovery requires ordinary --parent and refuses privileged inputs')
        print(json.dumps(recovery_fixture(args.parent, args.release_inputs), indent=2))
    elif args.run:
        if args.parent is None:
            parser.error('--run requires --parent')
        result = fixture(args.parent, args.release_inputs, profile=args.profile)
        print(json.dumps(result, indent=2))
        if not result['passed']:
            raise SystemExit(3)
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

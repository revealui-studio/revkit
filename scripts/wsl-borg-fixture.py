#!/usr/bin/env python3
"""Private synthetic Borg observer; never backs up an operator-supplied source.

Extends WslBackup.ps1's evidence design with actual Linux fixture observations.
No production executor, mount, secret key, retention or system installation.
"""
import argparse
import array
import datetime
import fcntl
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
                        'sparse': kind == 'file' and info.st_size > info.st_blocks * 512})
    return entries


def compare(source, restored):
    """Compare actual observations, including relational hardlink identity."""
    if source != restored:
        left = {row['path']: row for row in source}
        right = {row['path']: row for row in restored}
        differences = []
        for name in sorted(left.keys() | right.keys()):
            if name not in left or name not in right:
                differences.append(name + ': missing entry')
            else:
                differences.extend(name + ': ' + key for key in left[name]
                                   if left[name][key] != right[name].get(key))
        raise ValueError('Actual round-trip differs: ' + ', '.join(differences))


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


def fixture(parent, release_inputs=None):
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
        raise ValueError('Fixture requires 1 GiB free reserve; fixed dataset is under 33 MiB')
    root = Path(tempfile.mkdtemp(prefix='.revkit-borg-fixture-', dir=parent))
    env = private_env(root)
    receipt = {'schemaVersion': 1, 'scope': 'synthetic-borg-ext4-fixture', 'root': str(root),
               'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'filesystem': fs, 'uid': os.getuid(), 'fullRestoreAccepted': False,
               'hardwareScope': 'single-filesystem developer fixture; no physical identity proof',
               'encryptedRepository': False, 'privilegedMetadataVerified': False,
               'productionExecutionAllowed': False, 'passed': False,
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
        before = observe(tree, env)
        write_json(root / 'source-inventory.json', before)
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
        compare(before, after)
        receipt.update(passed=True, steps=steps, entries=len(before), sourcePathAbsent=not tree.exists(),
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
        write_json(root / 'failed.json', receipt)
        raise RuntimeError(f'Fixture refused; retained evidence at {root}: {exc}') from exc


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run', action='store_true', help='Download/verify tool and run fixed synthetic fixture only')
    parser.add_argument('--parent', type=Path, help='Existing private ext4 development directory, never a real disk root')
    parser.add_argument('--release-inputs', type=Path, help='Optional retained downloads; all provenance is reverified')
    args = parser.parse_args()
    if args.run:
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

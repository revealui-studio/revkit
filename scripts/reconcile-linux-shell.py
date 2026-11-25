#!/usr/bin/env python3
"""Reconcile package-owned Bash configuration and recognized Nix integration."""

import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile


NIX_SCRIPT = '/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh'
NIX_BLOCK = '\n'.join([
    '# generated-by-revkit: Nix integration start',
    f'if [ "${{_REVKIT_NIX_PID-}}" != "$$" ] && [ -r \'{NIX_SCRIPT}\' ]; then',
    f"    . '{NIX_SCRIPT}'",
    '    _REVKIT_NIX_PID=$$',
    'fi',
    '# generated-by-revkit: Nix integration end', '', ''])


def sha(data):
    return hashlib.sha256(data).hexdigest()


def strip_nix(text):
    lines = text.splitlines(keepends=True)
    result = []
    offset = 0
    while offset < len(lines):
        line = lines[offset].rstrip('\r\n')
        if line == '# generated-by-revkit: Nix integration start':
            block = ''.join(lines[offset:offset + 6])
            if block != NIX_BLOCK.rstrip('\n') + '\n':
                raise ValueError('Unrecognized managed Nix block')
            offset += 6
        elif line == '# Nix':
            block = [item.rstrip('\r\n') for item in lines[offset:offset + 5]]
            accepted = [
                ['# Nix', f"if [ -e '{NIX_SCRIPT}' ]; then", f"{indent}. '{NIX_SCRIPT}'", 'fi', '# End Nix']
                for indent in ['  ', '    ']
            ]
            if block not in accepted:
                raise ValueError('Unrecognized Nix installer block')
            offset += 5
        else:
            result.append(lines[offset])
            offset += 1
    return ''.join(result).strip() + '\n'


def package_bash_md5():
    result = subprocess.run(['/usr/bin/dpkg-query', '-W', '-f=${Conffiles}\n', 'bash'],
                            check=True, capture_output=True, text=True)
    for line in result.stdout.splitlines():
        fields = line.split()
        if fields and fields[0] == '/etc/bash.bashrc' and len(fields) == 2:
            return fields[1]
    raise ValueError('Bash package has no current /etc/bash.bashrc checksum')


def plan(etc, expected_md5):
    bashrc = etc / 'bash.bashrc'
    profile = etc / 'profile.d/nix.sh'
    current_bash = bashrc.read_bytes()
    current_profile = profile.read_bytes()
    base = strip_nix(current_bash.decode())
    if hashlib.md5(base.encode()).hexdigest() == expected_md5:
        package_base = base
        template = bashrc
    else:
        template = etc / 'bash.bashrc.dpkg-dist'
        template_bytes = template.read_bytes()
        if hashlib.md5(template_bytes).hexdigest() != expected_md5:
            raise ValueError('New Bash template differs from the package conffile checksum')
        previous = strip_nix((etc / 'bash.bashrc.backup-before-nix').read_text())
        if base != previous:
            raise ValueError('Bash configuration contains owner changes outside recognized Nix blocks')
        package_base = template_bytes.decode()
    profile_base = strip_nix(current_profile.decode())
    if profile_base.strip():
        raise ValueError('Nix profile contains owner changes outside recognized integration blocks')
    desired = [(bashrc, (NIX_BLOCK + package_base).encode()), (profile, NIX_BLOCK.encode())]
    observed = [(bashrc, current_bash), (profile, current_profile), (template, template.read_bytes())]
    if template != bashrc:
        previous = etc / 'bash.bashrc.backup-before-nix'
        observed.append((previous, previous.read_bytes()))
    return desired, observed


def root_custody(path):
    for item in [path, *path.parents]:
        if not item.exists() and not item.is_symlink():
            continue
        info = item.lstat()
        if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError(f'Unsafe root-owned configuration custody: {item}')


def atomic(path, data, metadata):
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.revkit-shell-', delete=False) as stream:
        temporary = Path(stream.name)
        try:
            os.fchmod(stream.fileno(), stat.S_IMODE(metadata.st_mode))
            os.fchown(stream.fileno(), metadata.st_uid, metadata.st_gid)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            shutil.copystat(path, temporary, follow_symlinks=False)
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def apply(desired, observed, backup_root):
    for path, original in observed:
        root_custody(path)
        if path.read_bytes() != original:
            raise ValueError(f'Configuration changed during planning: {path}')
    root_custody(backup_root)
    changes = [(path, data) for path, data in desired if path.read_bytes() != data]
    if not changes:
        return None
    backup_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root_custody(backup_root)
    backup = backup_root / datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    backup.mkdir(mode=0o700)
    receipt = {'schema': 1, 'files': []}
    originals = []
    for path, data in changes:
        original = path.read_bytes()
        metadata = path.stat()
        stored = backup / path.name
        shutil.copy2(path, stored)
        originals.append((path, original, metadata))
        receipt['files'].append({'path': str(path), 'backup': str(stored),
                                  'beforeSha256': sha(original), 'afterSha256': sha(data),
                                  'mode': stat.S_IMODE(metadata.st_mode), 'uid': metadata.st_uid,
                                  'gid': metadata.st_gid})
    (backup / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    changed = []
    try:
        for (path, data), (_, original, metadata) in zip(changes, originals):
            if path.read_bytes() != original:
                raise ValueError(f'Configuration changed before activation: {path}')
            atomic(path, data, metadata)
            changed.append((path, original, metadata))
    except BaseException:
        for path, original, metadata in reversed(changed):
            atomic(path, original, metadata)
        raise
    return backup


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    desired, observed = plan(Path('/etc'), package_bash_md5())
    result = {'schema': 1, 'mode': 'apply' if args.apply else 'plan', 'files': [
        {'path': str(path), 'action': 'preserve' if path.read_bytes() == data else 'reconcile',
         'sha256': sha(data)} for path, data in desired]}
    if args.apply:
        if os.geteuid() != 0:
            parser.error('--apply requires root')
        lock_root = Path('/var/lib/revkit')
        root_custody(lock_root)
        lock_root.mkdir(parents=True, exist_ok=True, mode=0o755)
        root_custody(lock_root)
        descriptor = os.open(lock_root / 'linux-shell.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        with os.fdopen(descriptor, 'r+') as lock:
            metadata = os.fstat(lock.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022:
                raise ValueError('Unsafe shell reconciliation lock custody')
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            desired, observed = plan(Path('/etc'), package_bash_md5())
            backup = apply(desired, observed, Path('/var/lib/revkit/linux-shell-backups'))
            result['backup'] = str(backup) if backup else None
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()

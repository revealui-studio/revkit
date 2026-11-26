#!/usr/bin/env python3
"""Publish the reviewed read-only disk identity helper under root custody."""

import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile


def digest(data):
    return hashlib.sha256(data).hexdigest()


def custody(path):
    for item in [path, *path.parents]:
        if not item.exists() and not item.is_symlink():
            continue
        metadata = item.lstat()
        if stat.S_ISLNK(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022:
            raise ValueError(f'Unsafe root-owned helper custody: {item}')


def inspect(source, destination, receipt):
    if source.is_symlink() or not source.is_file():
        raise ValueError('Helper source must be a regular maintained file')
    data = source.read_bytes()
    expected = digest(data)
    custody(destination)
    custody(receipt)
    if destination.exists() and destination.read_bytes() != data:
        if not receipt.is_file():
            raise ValueError('Existing helper has no managed receipt; refusing owner-file replacement')
        recorded = json.loads(receipt.read_text())
        if (recorded.get('schema') != 1 or recorded.get('destination') != str(destination) or
                recorded.get('sha256') != digest(destination.read_bytes())):
            raise ValueError('Existing helper differs from its deployment receipt')
    return data, expected


def publish(source, destination, receipt, approved_sha):
    data, expected = inspect(source, destination, receipt)
    if approved_sha != expected:
        raise ValueError('Explicit approved source SHA256 does not match the maintained helper')
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    receipt.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    custody(destination.parent)
    custody(receipt.parent)
    for path, content, mode in [
        (destination, data, 0o644),
        (receipt, (json.dumps({'schema': 1, 'destination': str(destination), 'sha256': expected,
                              'deployedAt': datetime.datetime.now(datetime.timezone.utc).isoformat()},
                             indent=2) + '\n').encode(), 0o600)
    ]:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.revkit-helper-', delete=False) as stream:
            temporary = Path(stream.name)
            try:
                os.fchmod(stream.fileno(), mode)
                os.fchown(stream.fileno(), 0, 0)
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
                temporary.replace(path)
            finally:
                temporary.unlink(missing_ok=True)
    custody(destination)
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--source-sha256')
    args = parser.parse_args()
    source = Path(__file__).resolve().with_name('wsl-disk-identity.py')
    destination = Path('/usr/local/lib/revealfleet/wsl-disk-identity.py')
    receipt = Path('/var/lib/revkit/disk-identity-helper.json')
    _, expected = inspect(source, destination, receipt)
    if args.apply:
        if os.geteuid() != 0:
            parser.error('--apply requires root')
        lock_root = receipt.parent
        custody(lock_root)
        lock_root.mkdir(parents=True, exist_ok=True, mode=0o755)
        custody(lock_root)
        descriptor = os.open(lock_root / 'disk-helper.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        with os.fdopen(descriptor, 'r+') as lock:
            metadata = os.fstat(lock.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022:
                raise ValueError('Unsafe disk helper deployment lock custody')
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            publish(source, destination, receipt, args.source_sha256)
    print(json.dumps({'schema': 1, 'mode': 'apply' if args.apply else 'plan',
                      'source': str(source), 'destination': str(destination),
                      'sourceSha256': expected, 'identityConfiguration': 'not-created'}, indent=2))


if __name__ == '__main__':
    main()

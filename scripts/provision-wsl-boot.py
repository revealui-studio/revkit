#!/usr/bin/env python3
"""Seed missing WSL configuration explicitly; preserve existing host policy."""

import argparse
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--windows-home', type=Path)
    parser.add_argument('--revert', action='store_true')
    args = parser.parse_args()
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

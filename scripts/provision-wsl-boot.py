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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--windows-home', type=Path)
    parser.add_argument('--revert', action='store_true')
    parser.add_argument('--boot-evidence', type=Path, help='Report from a saved native startup JSON receipt; no live commands')
    args = parser.parse_args()
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

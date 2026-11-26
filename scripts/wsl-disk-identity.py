#!/usr/bin/env python3
"""Verify an explicitly approved attached disk without mounting or changing it."""

import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import time
import uuid


class IdentityError(RuntimeError):
    pass


def load_identity(path):
    data = json.loads(Path(path).read_text(encoding='utf-8'))
    required = {'schemaVersion', 'serial', 'model', 'diskBytes', 'partitionBytes',
                'partitionStartSectors', 'partitionSectors', 'partitionUuid',
                'filesystemUuid', 'filesystemLabel', 'mountPoint'}
    if not isinstance(data, dict) or set(data) != required or type(data['schemaVersion']) is not int or data['schemaVersion'] != 1:
        raise IdentityError('Unsupported disk identity layout')
    for name in ['diskBytes', 'partitionBytes', 'partitionStartSectors', 'partitionSectors']:
        if type(data[name]) is not int or data[name] <= 0:
            raise IdentityError('Expected a positive exact disk geometry')
    for name in ['partitionUuid', 'filesystemUuid']:
        if str(uuid.UUID(data[name])) != data[name]:
            raise IdentityError('UUID must use canonical lowercase form')
    for name in ['serial', 'model', 'filesystemLabel']:
        if not isinstance(data[name], str) or not data[name].strip() or data[name] != data[name].strip():
            raise IdentityError('Expected explicit hardware and filesystem identity')
    mountpoint = Path(data['mountPoint'])
    if not mountpoint.is_absolute() or '..' in mountpoint.parts or len(mountpoint.parts) < 3:
        raise IdentityError('Expected an explicit non-root mountpoint')
    if (data['partitionSectors'] * 512 != data['partitionBytes'] or
            (data['partitionStartSectors'] + data['partitionSectors']) * 512 > data['diskBytes']):
        raise IdentityError('Partition bytes and 512-byte sector geometry disagree')
    return data


def inspect(identity, *, deadline_seconds=30, runner=None, now=time.monotonic, sleep=time.sleep,
            block_stat=os.stat, resolve=os.path.realpath):
    if not 0 < deadline_seconds <= 30:
        raise IdentityError('Readiness budget must be greater than zero and at most 30 seconds')
    deadline = now() + deadline_seconds

    def run(args, allow_absent=False):
        remaining = deadline - now()
        if remaining <= 0:
            raise IdentityError('Disk identity readiness deadline expired')
        if runner is None:
            result = subprocess.run(args, capture_output=True, text=True, timeout=remaining, check=False)
        else:
            result = runner(args, remaining)
        if result.returncode != 0 and not (allow_absent and result.returncode == 1):
            raise IdentityError('Read-only disk probe failed: ' + args[0])
        return result

    while True:
        listing = json.loads(run(['lsblk', '--json', '--bytes', '--output',
                                  'NAME,PATH,SIZE,TYPE,MOUNTPOINTS']).stdout)
        disks = [disk for disk in listing.get('blockdevices', [])
                 if disk.get('type') == 'disk' and disk.get('size') == identity['diskBytes']]
        if len(disks) > 1:
            raise IdentityError('Attached disk identity is ambiguous')
        disk = disks[0] if disks else None
        partitions = [part for part in disk.get('children', [])
                      if part.get('type') == 'part' and part.get('size') == identity['partitionBytes']] if disk else []
        if len(partitions) > 1:
            raise IdentityError('Partition identity is ambiguous')
        if disk and len(partitions) == 1:
            partition = partitions[0]
            break
        remaining = deadline - now()
        if remaining <= 0:
            raise IdentityError('Expected disk and partition did not become ready within the budget')
        sleep(min(0.25, remaining))

    for device in [disk, partition]:
        path = device.get('path', '')
        if not path.startswith('/dev/') or not stat.S_ISBLK(block_stat(path).st_mode):
            raise IdentityError('Expected an attached block device')
    table = json.loads(run(['sfdisk', '--json', disk['path']]).stdout).get('partitiontable', {})
    rows = table.get('partitions', [])
    if table.get('label') != 'gpt' or table.get('sectorsize') != 512 or len(rows) != 1:
        raise IdentityError('Unexpected GPT partition layout')
    row = rows[0]
    if (row.get('start') != identity['partitionStartSectors'] or
            row.get('size') != identity['partitionSectors'] or
            row.get('uuid', '').lower() != identity['partitionUuid'] or
            row.get('type', '').lower() != '0fc63daf-8483-4772-8e79-3d69d8477de4' or
            resolve(row.get('node', '')) != resolve(partition['path'])):
        raise IdentityError('GPT geometry or identity differs from the approved disk')
    metadata = {}
    for line in run(['blkid', '-p', '-o', 'export', partition['path']]).stdout.splitlines():
        key, separator, value = line.partition('=')
        if separator:
            metadata[key] = value
    if (metadata.get('TYPE') != 'ext4' or metadata.get('UUID') != identity['filesystemUuid'] or
            metadata.get('LABEL') != identity['filesystemLabel']):
        raise IdentityError('Filesystem UUID, type or label differs from the approved partition')
    mount = run(['findmnt', '--json', '--mountpoint', identity['mountPoint'],
                 '--output', 'SOURCE,FSTYPE,OPTIONS'], allow_absent=True)
    state = 'NOT_MOUNTED'
    if mount.returncode == 0:
        filesystems = json.loads(mount.stdout).get('filesystems', [])
        if len(filesystems) != 1:
            raise IdentityError('Mountpoint identity is ambiguous')
        current = filesystems[0]
        if (current.get('fstype') != 'ext4' or
                block_stat(current.get('source', '')).st_rdev != block_stat(partition['path']).st_rdev):
            raise IdentityError('Mountpoint belongs to another filesystem')
        state = 'MOUNTED'
    return {'schemaVersion': 1, 'identityVerified': True, 'serial': identity['serial'],
            'model': identity['model'], 'serialModelAuthority': 'configured-windows-identity-correlated-by-geometry', 'diskBytes': identity['diskBytes'],
            'partitionBytes': identity['partitionBytes'], 'partitionUuid': identity['partitionUuid'],
            'filesystemUuid': identity['filesystemUuid'], 'diskPath': disk['path'],
            'partitionPath': partition['path'], 'mountPoint': identity['mountPoint'],
            'mountState': state, 'operation': 'read-only-identity-probe'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity', required=True, type=Path)
    parser.add_argument('--deadline-seconds', type=float, default=30)
    parser.add_argument('--require-mount-point')
    parser.add_argument('--require-label')
    args = parser.parse_args()
    try:
        identity = load_identity(args.identity)
        if args.require_mount_point and identity['mountPoint'] != args.require_mount_point:
            raise IdentityError('Configured mountpoint differs from the privileged helper scope')
        if args.require_label and identity['filesystemLabel'] != args.require_label:
            raise IdentityError('Configured label differs from the privileged helper scope')
        result = inspect(identity, deadline_seconds=args.deadline_seconds)
    except (IdentityError, ValueError, OSError, subprocess.TimeoutExpired) as error:
        parser.exit(1, 'Disk identity verification refused: ' + str(error) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()

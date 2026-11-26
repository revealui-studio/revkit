#!/usr/bin/env python3
"""Package committed RevKit Windows source without platform-specific Git linkage."""

import argparse
import ctypes
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import tempfile
import tarfile


class ArtifactError(RuntimeError):
    pass


def is_selected(relative, policy):
    path = PurePosixPath(relative)
    if (not relative or path.is_absolute() or '..' in path.parts or '\\' in relative or ':' in relative or
            any(part in policy['excludedParts'] for part in path.parts) or path.name in policy['excludedLeaves']):
        return False
    return any(relative == root or relative.startswith(root + '/') for root in policy['roots'])


def publish_no_replace(staging, destination):
    library = ctypes.CDLL(None, use_errno=True)
    rename = getattr(library, 'renameat2', None)
    if rename is None:
        raise ArtifactError('Native artifact publishing requires atomic no-replace rename support')
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(-100, os.fsencode(staging), -100, os.fsencode(destination), 1) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def require_atomic_destination(parent):
    parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.revkit-publish-probe-', dir=parent) as probe:
        root = Path(probe)
        source = root / 'source'
        source.mkdir()
        try:
            publish_no_replace(source, root / 'published')
        except OSError as error:
            raise ArtifactError(
                'Destination filesystem does not support atomic no-replace directory publication '
                f'(errno {error.errno}); build on a native Linux filesystem. '
                'Deploy-WindowsArtifacts.ps1 copies the verified package into its Windows release.'
            ) from error


def package(source, destination, *, run=subprocess.run):
    source = Path(source).resolve(strict=True)
    destination = Path(destination).absolute()
    if destination.exists() or destination.is_relative_to(source) or source.is_relative_to(destination):
        raise ArtifactError('Package destination must be absent and separate from source')
    require_atomic_destination(destination.parent)
    policy = json.loads((source / 'scripts/windows-artifact-scope.json').read_text())
    if set(policy) != {'schemaVersion', 'roots', 'excludedParts', 'excludedLeaves', 'required'} or policy['schemaVersion'] != 1:
        raise ArtifactError('Unsupported Windows artifact scope policy')

    def git(args):
        result = run(['git', '-C', str(source), *args], capture_output=True, timeout=30, check=False)
        if result.returncode:
            raise ArtifactError('Reviewed committed source is required: git ' + args[0])
        return result.stdout

    git(['diff', '--quiet', 'HEAD', '--', *policy['roots']])
    commit = git(['rev-parse', 'HEAD']).decode().strip()
    if len(commit) != 40 or any(character not in '0123456789abcdef' for character in commit):
        raise ArtifactError('Unsupported source commit identity')
    paths = sorted(path.decode('utf-8') for path in git(['ls-files', '-z', '--', *policy['roots']]).split(b'\0') if path)
    selected = [path for path in paths if is_selected(path, policy)]
    if any(path not in selected for path in policy['required']):
        raise ArtifactError('Windows artifact source closure is incomplete')
    committed = {}
    with tarfile.open(fileobj=io.BytesIO(git(['archive', '--format=tar', commit, '--', *policy['roots']])), mode='r:') as archive:
        for relative in selected:
            member = archive.getmember(relative)
            if not member.isfile():
                raise ArtifactError('Committed Windows source must contain regular files only')
            committed[relative] = archive.extractfile(member).read()
    files = []
    for relative in selected:
        path = source / relative
        if (path.is_symlink() or not stat.S_ISREG(path.lstat().st_mode) or
                not path.resolve(strict=True).is_relative_to(source)):
            raise ArtifactError('Source artifact must be a regular file inside the maintained source')
        data = committed[relative]
        files.append({'path': relative, 'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)})
    manifest = {'schemaVersion': 1, 'kind': 'revealfleet-windows-artifact-source', 'sourceCommit': commit, 'files': files}
    manifest_data = (json.dumps(manifest, indent=2) + '\n').encode()
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='revealfleet-artifact-staging-', dir=destination.parent))
    try:
        for item in files:
            target = staging / item['path']
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(committed[item['path']])
            if hashlib.sha256(target.read_bytes()).hexdigest() != item['sha256']:
                raise ArtifactError('Source changed during artifact packaging')
        (staging / 'artifact-source-manifest.json').write_bytes(manifest_data)
        publish_no_replace(staging, destination)
    except Exception as error:
        raise ArtifactError('Package failed; source and existing destinations are unchanged; staging preserved at '
                            + str(staging) + '; cause: ' + str(error)) from error
    return {'package': str(destination), 'sourceCommit': commit, 'files': len(files),
            'manifestSha256': hashlib.sha256(manifest_data).hexdigest(), 'productionStateMutated': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--destination', required=True, type=Path)
    args = parser.parse_args()
    try:
        result = package(args.source, args.destination)
    except (ArtifactError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        parser.exit(1, 'Windows artifact packaging refused: ' + str(error) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()

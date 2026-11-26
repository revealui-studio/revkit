#!/usr/bin/env python3
"""Explicit Linux runtime provisioning. Routine bootstrap does not replace runtimes.

User mode installs checksum-pinned nvm and Node. System mode runs as root and
publishes a separate root-owned runtime. Existing runtimes remain recoverable.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import stat
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
ENV_START = '# generated-by-revkit: node environment start'
ENV_END = '# generated-by-revkit: node environment end'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def atomic_bytes(path, data, mode=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValueError(f'refusing symbolic destination: {path}')
    if mode is None:
        mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as out:
        staged = Path(out.name)
        out.write(data)
    staged.chmod(mode)
    staged.replace(path)


def preserve(path, backup):
    if not path.exists() and not path.is_symlink():
        return
    target = backup / path.name
    backup.mkdir(parents=True, exist_ok=True)
    if target.exists() or target.is_symlink():
        raise ValueError(f'backup collision: {target}')
    if path.is_symlink():
        target.symlink_to(os.readlink(path))
    else:
        shutil.copy2(path, target)


def reconcile_env(text):
    """Preserve owner code; replace the exact legacy exported boolean guard."""
    if ENV_START in text:
        before, tail = text.split(ENV_START, 1)
        if ENV_END not in tail:
            raise ValueError('unterminated managed Node environment')
        text = before + tail.split(ENV_END, 1)[1].lstrip('\n')
    legacy = '[ -n "$_SHELL_ENV_LOADED" ] && return 0 2>/dev/null\n_SHELL_ENV_LOADED=1\nexport _SHELL_ENV_LOADED'
    process_guard = '[ "${_REVKIT_ENV_PID:-}" = "$$" ] && return 0 2>/dev/null\n_REVKIT_ENV_PID=$$'
    if 'export _SHELL_ENV_LOADED' in text:
        if legacy not in text:
            raise ValueError('unknown exported shell guard; inspect before adoption')
        text = text.replace(legacy, process_guard, 1)
    block = '\n'.join([ENV_START,
        'if [ -r "$HOME/.config/shell/native-session-env.sh" ]; then',
        '    . "$HOME/.config/shell/native-session-env.sh"',
        '    revkit_native_session_env',
        'fi',
        'if [ -r "$HOME/.config/shell/node-env.sh" ]; then',
        '    . "$HOME/.config/shell/node-env.sh"',
        '    revkit_node_env || return',
        'fi', ENV_END, ''])
    return block + text


def require_root_custody(path):
    """No writable/symlink component may supply a privileged executable."""
    current = Path(path)
    for part in [current, *current.parents]:
        if not part.exists():
            continue
        info = part.lstat()
        if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError(f'unsafe privileged runtime custody: {part}')


def reconcile_legacy_fnm(text):
    """Retire only known selector lines, preserving unrelated owner settings."""
    lines = text.splitlines(keepends=True)
    output = []
    for line in lines:
        if line.strip() == '[ -d "$HOME/.local/share/fnm" ] && _prepend_path "$HOME/.local/share/fnm"':
            output.append('# fnm PATH retired by the maintained nvm deployment\n')
        elif line.strip() == 'if command -v fnm >/dev/null 2>&1; then':
            output.append('if [ "${REVKIT_NODE_MANAGER:-nvm}" = fnm ] && command -v fnm >/dev/null 2>&1; then\n')
        else:
            output.append(line)
    return ''.join(output)


def validate_link_replacement(path, target, known_roots, allow_windows_forwarder=False):
    if path.is_symlink():
        existing = path.resolve(strict=False)
        if existing == target.resolve():
            return
        if not any(existing.is_relative_to(root) for root in known_roots):
            raise ValueError(f'unowned executable link: {path}')
    elif path.exists():
        content = path.read_bytes()
        lines = content.decode('utf-8', errors='strict').splitlines()
        legacy_name = {'node': 'node.exe', 'npm': 'npm.cmd', 'npx': 'npx.cmd'}.get(path.name)
        expected = f'exec "/mnt/c/Program Files/nodejs/{legacy_name}" "$@"'
        known = allow_windows_forwarder and legacy_name and len(lines) == 2 and lines[0] in ['#!/bin/bash', '#!/usr/bin/env bash'] and lines[1] == expected
        if not known:
            raise ValueError(f'unowned executable: {path}')


def replace_link(path, target, backup, known_roots, allow_windows_forwarder=False):
    validate_link_replacement(path, target, known_roots, allow_windows_forwarder)
    if path.is_symlink() and path.resolve(strict=False) == target.resolve(strict=False):
        return
    preserve(path, backup)
    path.parent.mkdir(parents=True, exist_ok=True)
    staged = path.with_name(path.name + '.revkit-new')
    if staged.exists() or staged.is_symlink():
        raise ValueError(f'staging collision: {staged}')
    staged.symlink_to(target)
    staged.replace(path)


def download(url, checksum, target):
    with urllib.request.urlopen(url, timeout=60) as source, target.open('wb') as out:
        shutil.copyfileobj(source, out)
    if digest(target) != checksum:
        raise ValueError(f'checksum mismatch: {target.name}')


def extract_node(archive, destination, top):
    with tarfile.open(archive, 'r:xz') as bundle:
        for member in bundle.getmembers():
            name = Path(member.name)
            if name.is_absolute() or '..' in name.parts or name.parts[0] != top:
                raise ValueError('unsafe Node archive member')
            if member.isdev() or member.isfifo() or member.islnk():
                raise ValueError('unsupported Node archive member')
        bundle.extractall(destination, filter='data')
    return destination / top


def append_source(path, source, backup):
    text = path.read_text() if path.exists() else ''
    line = f'[ -r "{source}" ] && . "{source}"'
    invoke = 'revkit_node_env # generated-by-revkit: select default Node'
    if line not in text or invoke not in text:
        preserve(path, backup)
        if line not in text:
            text = text.rstrip() + '\n\n' + line + '\n'
        if invoke not in text:
            text = text.rstrip() + '\n' + invoke + '\n'
        atomic_bytes(path, text.encode())


def reconcile_environment_path(text, home, destination):
    output = []
    found = False
    for line in text.splitlines(keepends=True):
        if not line.startswith('PATH='):
            output.append(line)
            continue
        if found or any(char in line for char in ['"', "'", '`']):
            raise ValueError('unsupported environment.d PATH syntax')
        found = True
        entries = line[len('PATH='):].strip().split(':')
        kept = [entry for entry in entries if entry != str(destination / 'bin')
                and not entry.startswith(str(home / '.local/share/fnm') + '/')
                and entry != str(home / '.local/share/fnm')]
        output.append('PATH=' + ':'.join([str(destination / 'bin'), *kept]) + '\n')
    if not found:
        if output and not output[-1].endswith('\n'):
            output[-1] += '\n'
        output.append(f'PATH={destination}/bin:${{PATH}}\n')
    marker = '# generated-by-revkit: Node PATH selector\n'
    return ('' if marker in text else marker) + ''.join(output)


def validate_runtime(destination, expected_files, mode):
    if destination.is_symlink():
        raise ValueError('runtime destination is a symbolic link')
    if mode == 'system':
        require_root_custody(destination / 'bin/node')
    required = {'bin/node', 'lib/node_modules/npm/bin/npm-cli.js', 'bin/npm', 'bin/npx'}
    if not isinstance(expected_files, dict) or not required.issubset(expected_files):
        raise ValueError('incomplete runtime manifest')
    for relative, expected in expected_files.items():
        if Path(relative).is_absolute() or '..' in Path(relative).parts or not isinstance(expected, dict) or set(expected) not in [{'link'}, {'sha256'}]:
            raise ValueError('invalid runtime manifest entry')
        item = destination / relative
        if 'link' in expected:
            if not item.is_symlink() or os.readlink(item) != expected['link'] or not item.resolve().is_relative_to(destination):
                raise ValueError(f'runtime link mismatch: {relative}')
        elif not item.is_file() or item.is_symlink() or digest(item) != expected['sha256']:
            raise ValueError(f'runtime artifact mismatch: {relative}')
        if mode == 'system':
            require_root_custody(item.resolve())


def artifact_files(root):
    result = {}
    for item in root.rglob('*'):
        if item.is_symlink():
            result[item.relative_to(root).as_posix()] = {'link': os.readlink(item)}
        elif item.is_file():
            result[item.relative_to(root).as_posix()] = {'sha256': digest(item)}
    for required in ['bin/node', 'lib/node_modules/npm/bin/npm-cli.js', 'bin/npm', 'bin/npx']:
        if required not in result:
            raise ValueError(f'incomplete Node artifact: {required}')
    return result


def provision(mode, home, apply):
    config = json.loads((ROOT / 'shell/config/linux-node.json').read_text())
    if platform.system() != 'Linux' or platform.machine() != 'x86_64':
        raise ValueError('supported runtime profile is Linux x86_64')
    if apply and mode == 'system' and os.geteuid() != 0:
        raise ValueError('system runtime provisioning requires root')
    if apply and mode == 'user' and os.geteuid() == 0:
        raise ValueError('user nvm provisioning must run as its owning user')
    home = Path(home).resolve()
    version = config['node']['version']
    top = f'node-v{version}-linux-x64'
    destination = (home / '.nvm/versions/node' / f'v{version}') if mode == 'user' else Path('/opt/revealfleet/toolchains') / top
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    backup = (home / '.local/state/revkit/node-backups' / stamp) if mode == 'user' else Path('/var/lib/revkit/node-backups') / stamp
    result = {'schema': 1, 'mode': mode, 'version': version, 'destination': str(destination), 'backup': str(backup), 'applied': apply, 'old_runtimes_retained': True}
    if not apply:
        return result
    if mode == 'system':
        require_root_custody(destination.parent)
        preflight_bins = [Path('/usr/local/bin')]
        preflight_roots = [Path('/opt/revealfleet/toolchains')]
    else:
        preflight_bins = [home / '.local/bin', home / 'bin']
        preflight_roots = [home / '.local/share/revealfleet/toolchains', home / '.local/share/fnm', home / '.nvm']
        for file in [home / '.config/shell/env.sh', home / '.config/shell/path.sh', home / '.config/shell/aliases.sh',
                     home / '.config/environment.d/10-dev-path.conf', *[home / name for name in ['.bashrc', '.bash_profile', '.profile']]]:
            if file.is_symlink():
                raise ValueError(f'owner configuration link preserved: {file}')
        env_file = home / '.config/shell/env.sh'
        reconcile_env(env_file.read_text() if env_file.exists() else '')
        environment = home / '.config/environment.d/10-dev-path.conf'
        if environment.exists():
            old = environment.read_text()
            if '.local/share/fnm/node-versions/' not in old and '# generated-by-revkit' not in old:
                raise ValueError('unowned environment.d PATH configuration')
            reconcile_environment_path(old, home, destination)
        for name, checksum in config['nvm']['files'].items():
            existing = home / '.nvm' / name
            if existing.exists() and digest(existing) != checksum:
                raise ValueError(f'existing nvm source differs: {name}; explicit upgrade required')
    for bin_dir in preflight_bins:
        for name in ['node', 'npm', 'npx']:
            validate_link_replacement(bin_dir / name, destination / 'bin' / name, preflight_roots, mode == 'user')
    # All network bytes are verified before publishing an executable or changing PATH.
    with tempfile.TemporaryDirectory(prefix='revkit-node-') as temp:
        staging = Path(temp)
        manifest = destination / '.revkit-node.json'
        if not destination.exists() or not manifest.exists():
            archive = staging / (top + '.tar.xz')
            download(f'https://nodejs.org/dist/v{version}/{archive.name}', config['node']['sha256'], archive)
            extracted = extract_node(archive, staging, top)
            expected_files = artifact_files(extracted)
        else:
            if mode == 'system':
                require_root_custody(manifest)
            recorded = json.loads(manifest.read_text())
            if recorded['archiveSha256'] != config['node']['sha256']:
                raise ValueError('runtime manifest does not match the pinned release')
            expected_files = recorded['files']
        if not destination.exists():
            destination.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix='.revkit-node-stage-', dir=destination.parent) as local:
                local_tree = Path(local) / top
                shutil.copytree(extracted, local_tree, symlinks=True)
                if mode == 'system':
                    for p in [local_tree, *local_tree.rglob('*')]:
                        if not p.is_symlink():
                            p.chmod(p.stat().st_mode & ~0o022)
                validate_runtime(local_tree, expected_files, mode)
                local_tree.rename(destination)
        validate_runtime(destination, expected_files, mode)
        atomic_bytes(manifest, (json.dumps({'archiveSha256': config['node']['sha256'], 'files': expected_files}, sort_keys=True) + '\n').encode())
        if subprocess.check_output([str(destination / 'bin/node'), '--version'], text=True).strip() != f'v{version}':
            raise ValueError('existing runtime destination is incompatible')
        old_base = home / '.local/share/revealfleet/toolchains' if mode == 'user' else Path('/opt/revealfleet/toolchains')
        old_node = old_base / 'node-v24.21.0-linux-x64'
        old_modules = old_node / 'lib/node_modules'
        if old_modules.is_dir():
            unknown = set(p.name for p in old_modules.iterdir()) - {'npm', 'corepack'}
            if unknown:
                raise ValueError('global packages need explicit migration: ' + ', '.join(sorted(unknown)))
            corepack = old_modules / 'corepack'
            target = destination / 'lib/node_modules/corepack'
            if corepack.is_dir() and not target.exists():
                if mode == 'system':
                    for p in [corepack, *corepack.rglob('*')]:
                        if not p.resolve().is_relative_to(corepack):
                            raise ValueError('Corepack link leaves its package')
                        require_root_custody(p.resolve())
                shutil.copytree(corepack, target, symlinks=True)
                (destination / 'bin/corepack').symlink_to('../lib/node_modules/corepack/dist/corepack.js')
            if mode == 'system' and target.exists():
                for p in [target, *target.rglob('*')]:
                    if not p.resolve().is_relative_to(target):
                        raise ValueError('installed Corepack link leaves its package')
                    require_root_custody(p.resolve())
        if mode == 'user':
            nvm = home / '.nvm'
            for name, checksum in config['nvm']['files'].items():
                staged = staging / name
                download(f'https://raw.githubusercontent.com/nvm-sh/nvm/v{config["nvm"]["version"]}/{name}', checksum, staged)
                existing = nvm / name
                if existing.exists() and digest(existing) != checksum:
                    raise ValueError(f'existing nvm source differs: {name}; explicit upgrade required')
                atomic_bytes(existing, staged.read_bytes(), 0o755 if name == 'nvm-exec' else 0o644)
            if (nvm / 'alias/default').exists() and (nvm / 'alias/default').read_text().strip() != version:
                preserve(nvm / 'alias/default', backup / 'nvm')
            atomic_bytes(nvm / 'alias/default', (version + '\n').encode())
            shell = home / '.config/shell'
            env_file = shell / 'env.sh'
            text = env_file.read_text() if env_file.exists() else ''
            reconciled = reconcile_env(text)
            preserve(env_file, backup)
            atomic_bytes(shell / 'node-env.sh', (ROOT / 'shell/lib/node-env.sh').read_bytes())
            atomic_bytes(shell / 'native-session-env.sh', (ROOT / 'shell/lib/native-session-env.sh').read_bytes())
            atomic_bytes(env_file, reconciled.encode())
            for name in ['path.sh', 'aliases.sh']:
                legacy = shell / name
                if legacy.exists():
                    text = legacy.read_text()
                    converted = reconcile_legacy_fnm(text)
                    if converted != text:
                        preserve(legacy, backup)
                        atomic_bytes(legacy, converted.encode())
            for profile in ['.bashrc', '.bash_profile', '.profile']:
                append_source(home / profile, '$HOME/.config/shell/node-env.sh', backup)
            # systemd environment.d accepts literals rather than shell nvm initialization.
            environment = home / '.config/environment.d/10-dev-path.conf'
            if environment.exists():
                old = environment.read_text()
                if '.local/share/fnm/node-versions/' not in old and '# generated-by-revkit' not in old:
                    raise ValueError('unowned environment.d PATH configuration')
                preserve(environment, backup)
            old = environment.read_text() if environment.exists() else '# generated-by-revkit\n'
            atomic_bytes(environment, reconcile_environment_path(old, home, destination).encode())
            roots = [home / '.local/share/revealfleet/toolchains', home / '.local/share/fnm', home / '.nvm']
            bins = [home / '.local/bin', home / 'bin']
        else:
            roots = [Path('/opt/revealfleet/toolchains')]
            bins = [Path('/usr/local/bin')]
        for bin_dir in bins:
            for name in ['node', 'npm', 'npx']:
                link = bin_dir / name
                # Optional user ~/bin aliases only need repair when already present.
                if mode == 'user' and bin_dir == home / 'bin' and not link.exists() and not link.is_symlink():
                    continue
                label = 'local-bin' if mode == 'user' and bin_dir == home / '.local/bin' else 'bin'
                replace_link(link, destination / 'bin' / name, backup / label, roots, mode == 'user')
        if (destination / 'bin/corepack').exists():
            corepack_bin = home / '.local/bin/corepack' if mode == 'user' else Path('/usr/local/bin/corepack')
            replace_link(corepack_bin, destination / 'bin/corepack', backup / 'corepack-bin', roots)
        atomic_bytes(backup / 'receipt.json', (json.dumps(result, indent=2) + '\n').encode(), 0o600)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=['user', 'system'], required=True)
    parser.add_argument('--home', default=str(Path.home()))
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    print(json.dumps(provision(args.mode, args.home, args.apply), indent=2))


if __name__ == '__main__':
    main()

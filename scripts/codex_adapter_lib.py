"""Parsing and path boundaries shared by explicit Codex state adapters."""

import json
import os
from pathlib import Path, PurePosixPath, PureWindowsPath
import subprocess
import tempfile
import tomllib


class Refused(ValueError):
    pass


TOML_DELETE = object()


def require(condition, reason):
    if not condition:
        raise Refused(reason)


def encode(value):
    return json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def atomic_write(path, text):
    path = Path(path)
    require(not path.is_symlink(), "refusing a linked destination")
    fd, name = tempfile.mkstemp(prefix=".revkit-config-", dir=path.parent)
    os.close(fd)
    try:
        if path.exists():
            os.chmod(name, path.stat().st_mode & 0o777)
            if os.name == "nt":
                windows_access(name, reference=path, preserve_inheritance=True)
        elif os.name == "nt":
            windows_access(name, private=True)
        with open(name, "w", encoding="utf-8", newline="") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def path_flavor(value):
    if len(value) >= 3 and value[1] == ":" and value[2] in "\\/":
        return "windows"
    if value.startswith("\\\\?\\"):
        return "windows"
    return "posix"


def parsed_path(value, flavor=None):
    require(isinstance(value, str) and not any(c in value for c in "\x00\r\n"),
            "invalid path value")
    flavor = flavor or path_flavor(value)
    if flavor == "windows":
        value = value[4:] if value.startswith("\\\\?\\") else value
        require(not value.startswith("\\\\"), "network paths are not supported")
        path = PureWindowsPath(value)
        require(path.is_absolute() and len(path.drive) == 2 and path.drive[1] == ":",
                "expected a local absolute Windows path")
    else:
        path = PurePosixPath(value)
        require(path.is_absolute() and "\\" not in value, "expected an absolute native path")
    require(".." not in path.parts, "path traversal is not supported")
    return path


def is_storage_container(parts, flavor):
    return bool(parts) and (parts[0].casefold() if flavor == "windows" else parts[0]) in {"sessions", "archived_sessions"}


def storage_relative(value, old_home):
    flavor = path_flavor(old_home)
    old = parsed_path(old_home, flavor)
    value_path = parsed_path(value, flavor)
    try:
        relative = value_path.relative_to(old)
    except ValueError:
        raise Refused("storage path is outside the source home") from None
    require(is_storage_container(relative.parts, flavor),
            "indexed rollout is not in a supported storage directory")
    suffix = relative.suffix.casefold() if flavor == "windows" else relative.suffix
    require(suffix == ".jsonl", "indexed rollout has an unsupported extension")
    return relative.parts


def rebase_storage(value, old_home, new_home):
    parts = storage_relative(value, old_home)
    flavor = path_flavor(old_home)
    require(path_flavor(new_home) == flavor, "cross-platform state merging is unsupported")
    rebased = str(parsed_path(new_home, flavor).joinpath(*parts))
    if flavor == "windows" and value.startswith("\\\\?\\"):
        rebased = "\\\\?\\" + rebased
    return rebased


def contains_home(value, old_home):
    if not isinstance(value, str):
        return False
    old = old_home[4:] if old_home.startswith("\\\\?\\") else old_home
    value = value[4:] if value.startswith("\\\\?\\") else value
    old = old.replace("\\", "/").rstrip("/")
    text = value.replace("\\", "/")
    if path_flavor(old_home) == "windows":
        old, text = old.casefold(), text.casefold()
        while "//" in old:
            old = old.replace("//", "/")
        while "//" in text:
            text = text.replace("//", "/")
    start = 0
    while True:
        index = text.find(old, start)
        if index < 0:
            return False
        end = index + len(old)
        if end == len(text) or text[end] in "/\"' ;,}]":
            return True
        start = end


def references(value, old_home):
    if isinstance(value, dict):
        return sum(int(contains_home(k, old_home)) + references(v, old_home)
                   for k, v in value.items())
    if isinstance(value, list):
        return sum(references(v, old_home) for v in value)
    if isinstance(value, str) and value.lstrip().startswith(("{", "[")):
        try:
            return references(json.loads(value), old_home)
        except (ValueError, RecursionError):
            pass
    return int(contains_home(value, old_home))


def windows_acl(path, create=False):
    if create:
        windows_access(path, private=True)
    access = windows_access_inventory([path])[0]
    require(access["private"], "Windows private ownership or ACL verification failed")


def windows_access_tasks(tasks):
    program = r'''
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
function Access-Signature($descriptor, [bool]$includeInherited = $false) {
  $rules = @{}
  foreach ($entry in $descriptor.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
    $key = $entry.IdentityReference.Value + '|' + $entry.AccessControlType + '|' + $entry.InheritanceFlags + '|' + $entry.PropagationFlags
    if ($includeInherited) { $key += '|' + $entry.IsInherited }
    $rules[$key] = [long]$rules[$key] -bor [long]$entry.FileSystemRights
  }
  return (@($rules.Keys | Sort-Object | ForEach-Object { $_ + '=' + $rules[$_] }) -join ';')
}
function Hash-Value([string]$value) {
  return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($value))).ToLowerInvariant()
}
$pairs = ConvertFrom-Json -InputObject ([Console]::In.ReadToEnd())
$results = [Collections.Generic.List[object]]::new()
foreach ($pair in @($pairs)) {
$p = [string]$pair.target
$reference = [string]$pair.reference
$directory = [IO.Directory]::Exists($p)
$uid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$current = Get-Acl -LiteralPath $p
if ($pair.action -eq 'inspect') {
  $section = [Security.AccessControl.AccessControlSections]::Access
  $allowed = @($uid.Value, 'S-1-5-18', 'S-1-5-32-544')
  $owned = $current.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq $uid.Value
  $unexpected = @($current.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object {
    $_.AccessControlType -eq 'Allow' -and $_.IdentityReference.Value -notin $allowed
  })
  $results.Add([PSCustomObject]@{
    effective = (Hash-Value (Access-Signature $current))
    inheritance = (Hash-Value (Access-Signature $current $true))
    access = (Hash-Value ($current.GetSecurityDescriptorSddlForm($section)))
    owner = (Hash-Value ($current.GetOwner([Security.Principal.SecurityIdentifier]).Value))
    protected = $current.AreAccessRulesProtected
    private = ($owned -and $current.AreAccessRulesProtected -and $unexpected.Count -eq 0)
  })
  continue
}
if ($current.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $uid.Value) { exit 2 }
$fresh = if ($directory) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
if ($pair.action -ne 'preserve') { $fresh.SetAccessRuleProtection($true, $false) }
if ($reference) {
  $source = Get-Acl -LiteralPath $reference
  if ($source.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $uid.Value) { exit 3 }
  if (-not $source.AreAccessRulesCanonical) { exit 6 }
  if ($pair.action -eq 'preserve') {
    $section = [Security.AccessControl.AccessControlSections]::Access
    $fresh.SetSecurityDescriptorSddlForm($source.GetSecurityDescriptorSddlForm($section), $section)
  } else {
    foreach ($entry in $source.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
      $rule = [Security.AccessControl.FileSystemAccessRule]::new($entry.IdentityReference, $entry.FileSystemRights, $entry.InheritanceFlags, $entry.PropagationFlags, $entry.AccessControlType)
      $fresh.AddAccessRule($rule)
    }
  }
} else {
  foreach ($sid in @($uid.Value, 'S-1-5-18', 'S-1-5-32-544')) {
    $identity = [Security.Principal.SecurityIdentifier]::new($sid)
    $rule = if ($directory) {
      [Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    } else {
      [Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'Allow')
    }
    $fresh.AddAccessRule($rule)
  }
}
if ($directory) { [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($p), $fresh) }
else { [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($p), $fresh) }
$after = Get-Acl -LiteralPath $p
if ($after.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $uid.Value) { exit 4 }
if ($pair.action -eq 'preserve') {
  if ($after.AreAccessRulesProtected -ne $source.AreAccessRulesProtected -or
      (Access-Signature $after $true) -ne (Access-Signature $source $true)) { exit 8 }
} elseif (-not $after.AreAccessRulesProtected) { exit 7 }
if ($reference -and (Access-Signature $after) -ne (Access-Signature $source)) { exit 5 }
$results.Add([PSCustomObject]@{copied = $true})
}
ConvertTo-Json -InputObject ($results.ToArray()) -Compress -Depth 4
'''
    require(tasks, "an access-rule task is required")
    env = {k: v for k, v in os.environ.items()
           if k.upper() in {"PATH", "SYSTEMROOT", "WINDIR", "COMSPEC", "TEMP", "TMP", "PROGRAMFILES"}}
    result = subprocess.run(["pwsh.exe", "-NoProfile", "-NonInteractive", "-Command", program],
                            env=env, input=json.dumps(tasks), text=True, encoding="utf-8",
                            capture_output=True, timeout=min(600, max(30, len(tasks) // 10 + 30)))
    require(result.returncode == 0, "Windows file ownership or preserved access rules verification failed")
    values = json.loads(result.stdout)
    require(isinstance(values, list) and len(values) == len(tasks), "incomplete Windows access-rule result")
    return values


def windows_access(path, private=False, reference=None, preserve_inheritance=False):
    require(private != (reference is not None), "choose private or preserved file access rules")
    if preserve_inheritance:
        require(reference is not None and Path(path).resolve().parent == Path(reference).resolve().parent,
                "inherited access preservation requires a same-parent replacement")
    windows_access_tasks([{"target": str(Path(path).resolve()),
                           "reference": str(Path(reference).resolve()) if reference is not None else "",
                           "action": "preserve" if preserve_inheritance else "copy"}])


def windows_access_batch(pairs):
    if pairs:
        windows_access_tasks([{"target": str(Path(target).resolve()), "reference": str(Path(source).resolve())}
                              for target, source in pairs])


def windows_access_inventory(paths):
    if not paths:
        return []
    return windows_access_tasks([{"target": str(Path(path).resolve()), "action": "inspect", "reference": ""}
                                 for path in paths])


def private_directory(path, create=False):
    path = Path(path)
    if create:
        path.mkdir(mode=0o700)
    require(path.is_dir(), "private directory is missing")
    require(not is_link(path), "private directory cannot be a link or reparse point")
    if os.name == "nt":
        windows_acl(path, create=create)
    else:
        info = path.stat()
        require(info.st_uid == os.getuid() and info.st_mode & 0o077 == 0,
                "directory is not private to the current user")


def is_link(path):
    path = Path(path)
    info = path.lstat()
    return path.is_symlink() or bool(getattr(info, "st_file_attributes", 0) & 0x400)


def toml_literal(value):
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, dict):
        require(all(isinstance(k, str) and isinstance(v, str) for k, v in value.items()),
                "only string-valued environment maps are supported")
        return "{ " + ", ".join(toml_literal(k) + " = " + toml_literal(v)
                                 for k, v in value.items()) + " }"
    raise Refused("unsupported TOML edit type")


def toml_statements(text):
    start = 0
    index = 0
    quote = None
    triple = False
    depth = 0
    comment = False
    while index < len(text):
        char = text[index]
        if comment:
            if char == "\n":
                comment = False
            else:
                index += 1
                continue
        if quote:
            if char == "\\" and quote == '"':
                index += 2
                continue
            delimiter = quote * (3 if triple else 1)
            if text.startswith(delimiter, index):
                index += len(delimiter)
                quote = None
                continue
        elif char in "\"'":
            quote = char
            triple = text.startswith(char * 3, index)
            index += 3 if triple else 1
            continue
        elif char == "#":
            comment = True
        elif char in "[{":
            depth += 1
        elif char in "]}":
            depth -= 1
        if char == "\n" and quote is None and depth == 0:
            yield start, index + 1, text[start:index + 1]
            start = index + 1
        index += 1
    if start < len(text):
        yield start, len(text), text[start:]


def key_path(text):
    value = tomllib.loads(text + " = 0")
    result = []
    while isinstance(value, dict) and len(value) == 1:
        key, value = next(iter(value.items()))
        result.append(key)
    require(value == 0, "unsupported TOML key syntax")
    return tuple(result)


def toml_edit(text, edits):
    original = tomllib.loads(text)
    changes = dict(edits)
    replacements = []
    headers = []
    table = ()
    for start, end, statement in toml_statements(text):
        stripped = statement.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("[["):
            table = None
            headers.append((start, None))
            continue
        if stripped.startswith("["):
            closing = stripped.rfind("]")
            require(closing > 0, "unsupported TOML table syntax")
            table = key_path(stripped[1:closing])
            headers.append((start, table))
            continue
        if table is None:
            continue
        quoted = None
        escaped = False
        split = None
        for index, char in enumerate(statement):
            if escaped:
                escaped = False
            elif quoted and char == "\\" and quoted == '"':
                escaped = True
            elif char == quoted:
                quoted = None
            elif quoted is None and char in "\"'":
                quoted = char
            elif quoted is None and char == "=":
                split = index
                break
        require(split is not None, "unsupported TOML assignment")
        path = table + key_path(statement[:split].strip())
        matches = [p for p in changes if p[:len(path)] == path]
        if not matches:
            continue
        parsed = tomllib.loads(statement)
        value = parsed
        for key in key_path(statement[:split].strip()):
            value = value[key]
        for edit in matches:
            if edit == path:
                value = changes.pop(edit)
            else:
                require(isinstance(value, dict), "unsupported nested TOML edit")
                cursor = value
                for key in edit[len(path):-1]:
                    require(isinstance(cursor.get(key), dict), "unsupported nested TOML edit")
                    cursor = cursor[key]
                requested = changes.pop(edit)
                if requested is TOML_DELETE:
                    require(edit[-1] in cursor, "TOML deletion target is missing")
                    del cursor[edit[-1]]
                else:
                    cursor[edit[-1]] = requested
        replacement = "" if value is TOML_DELETE else statement[:split + 1] + " " + toml_literal(value) + "\n"
        replacements.append((start, end, replacement))
    if changes:
        grouped = {}
        for path, value in changes.items():
            require(value is not TOML_DELETE, "TOML deletion target was not located")
            grouped.setdefault(path[:-1], []).append((path[-1], value))
        for table, entries in grouped.items():
            header = ".".join(toml_literal(p) for p in table)
            locations = [i for i, item in enumerate(headers) if item[1] == table]
            addition = "\n"
            if locations:
                index = locations[0]
                position = headers[index + 1][0] if index + 1 < len(headers) else len(text)
            else:
                position = len(text)
                addition += "[" + header + "]\n"
            for key, value in entries:
                addition += toml_literal(key) + " = " + toml_literal(value) + "\n"
            replacements.append((position, position, addition))
    for start, end, replacement in sorted(replacements, key=lambda item: item[0], reverse=True):
        text = text[:start] + replacement + text[end:]
    expected = original
    for path, value in edits.items():
        cursor = expected
        for key in path[:-1]:
            cursor = cursor.setdefault(key, {})
        if value is TOML_DELETE:
            require(path[-1] in cursor, "TOML deletion target is missing")
            del cursor[path[-1]]
        else:
            cursor[path[-1]] = value
    actual = tomllib.loads(text)
    for path, value in edits.items():
        if value is not TOML_DELETE:
            continue
        for length in range(len(path) - 1, 0, -1):
            parent = expected
            observed = actual
            for key in path[:length - 1]:
                parent = parent[key]
                observed = observed.get(key, {})
            key = path[length - 1]
            if parent.get(key) == {} and key not in observed:
                del parent[key]
    require(actual == expected, "TOML edit did not preserve unrelated settings")
    return text


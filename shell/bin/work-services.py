#!/usr/bin/env python3
"""Project-scoped Docker services with process leases and graceful idle cleanup."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

IDLE = 300
HOME = Path.home()
STATE = HOME / ".local/share/revealfleet/work-services"
CONFIG = HOME / ".config/revealfleet/work-services.json"


def run(args, timeout=15):
    if args[0] == "docker":
        args = ["docker", "--host", "unix:///run/docker.sock", *args[1:]]
    return subprocess.run(
        args, capture_output=True, text=True, timeout=timeout, check=True
    ).stdout


def birth(pid):
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        if fields[0] in ("Z", "X"):
            return None
        boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        return f"{boot}:{fields[19]}" if boot else None
    except (OSError, IndexError):
        return None


def contains(root, workdir):
    root, workdir = Path(root).resolve(), Path(workdir).resolve()
    return workdir == root or root in workdir.parents


def plan(projects, leases, running, blocked, now, previous):
    """Return desired starts, eligible stops, and updated idle timestamps."""
    starts, stops, seen = [], [], dict(previous)
    for project in projects:
        name = project["container"]
        wanted = any(contains(project["root"], lease["workdir"]) for lease in leases)
        if wanted or blocked:
            seen[name] = now
        else:
            seen.setdefault(name, now)
        if wanted and name not in running:
            starts.append(name)
        if not wanted and not blocked and name in running and now - seen[name] >= IDLE:
            stops.append(name)
    return starts, stops, seen


def atomic_json(path, value):
    temporary = path.with_suffix(".new")
    temporary.write_text(json.dumps(value))
    temporary.chmod(0o600)
    temporary.replace(path)


def docker_active():
    result = subprocess.run(
        ["systemctl", "is-active", "--quiet", "docker.service"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    return result.returncode == 0


def clients_busy():
    # Preserve builds and other Docker commands, including plugin processes.
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            name = Path(os.readlink(entry / "exe")).name
            if name in {"docker", "docker-buildx", "docker-compose", "buildctl", "buildkitd"}:
                return True
        except OSError:
            continue
    # Also preserve direct Unix-socket API clients.
    try:
        sockets = run(["ss", "-xHnp"])
        return any("ESTAB" in line and "docker.sock" in line for line in sockets.splitlines())
    except (OSError, subprocess.SubprocessError):
        return True  # Incomplete workload visibility must not permit shutdown.


def live_leases():
    leases = []
    for path in STATE.glob("lease-*.json"):
        try:
            lease = json.loads(path.read_text())
            if isinstance(lease["birth"], str) and birth(int(lease["pid"])) == lease["birth"]:
                leases.append(lease)
            else:
                path.unlink()
        except (OSError, ValueError, KeyError, TypeError):
            # A damaged lease blocks cleanup rather than pretending work ended.
            raise RuntimeError("unreadable work lease; cleanup withheld")
    return leases


def database_clients_busy(projects):
    ports, direct = set(), set()
    for project in projects:
        details = json.loads(run(["docker", "inspect", project["container"]]))[0]
        network = details["NetworkSettings"]
        bindings = network.get("Ports") or {}
        for binding in bindings.get("5432/tcp") or []:
            ports.add(binding["HostPort"])
        for attachment in (network.get("Networks") or {}).values():
            for key in ("IPAddress", "GlobalIPv6Address"):
                if attachment.get(key):
                    direct.add((attachment[key], "5432"))
        if network.get("IPAddress"):
            direct.add((network["IPAddress"], "5432"))
    connections = run(["ss", "-Htn", "state", "established"])
    for line in connections.splitlines():
        for endpoint in line.split():
            if ":" not in endpoint:
                continue
            address, port = endpoint.rsplit(":", 1)
            if port in ports or (address.strip("[]"), port) in direct:
                return True
    return False


@contextmanager
def lease_lock():
    with (STATE / "manager.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def inspect_owned(project):
    details = json.loads(run(["docker", "inspect", project["container"]]))[0]
    labels = details["Config"].get("Labels") or {}
    if labels.get("com.docker.compose.project") != project["compose_project"]:
        raise RuntimeError("managed container ownership changed")
    if labels.get("com.docker.compose.service") != "postgres":
        raise RuntimeError("managed container service changed")
    return details


def snapshot(projects):
    names = run(["docker", "ps", "--format", "{{.Names}}"]).splitlines()
    existing = set(run(["docker", "ps", "--all", "--format", "{{.Names}}"]).splitlines())
    managed = {p["container"] for p in projects}
    available = [p for p in projects if p["container"] in existing]
    for project in available:
        inspect_owned(project)
    return set(names), bool(set(names) - managed), available


def tick(projects, dry_run=False):
    with lease_lock():
        leases = live_leases()
    state_file = STATE / "idle.json"
    previous = json.loads(state_file.read_text()) if state_file.exists() else {}
    now = time.time()
    if not docker_active():
        # Do not contact the socket and wake Docker during idle timer checks.
        if leases and not dry_run:
            for project in projects:
                if any(contains(project["root"], lease["workdir"]) for lease in leases):
                    inspect_owned(project)
                    run(["docker", "start", project["container"]], timeout=90)
        return
    running, foreign, available = snapshot(projects)
    blocked = foreign or clients_busy() or database_clients_busy(available)
    starts, stops, seen = plan(projects, leases, running, blocked, now, previous)
    if dry_run:
        print(json.dumps({"start": starts, "stop": stops, "other_work": blocked}))
        return
    with lease_lock():
        atomic_json(state_file, seen)
    for name in starts:
        # Absence is harmless only for unrelated projects. Recheck ownership
        # immediately before starting each requested database.
        inspect_owned(next(p for p in projects if p["container"] == name))
        run(["docker", "start", name], timeout=90)
    # Pin every target before the first potentially slow shutdown.
    targets = []
    for name in stops:
        project = next(p for p in projects if p["container"] == name)
        targets.append((project, inspect_owned(project)["Id"]))
    for project, container_id in targets:
        # External inspection can take minutes; it must not block lease writes.
        current = inspect_owned(project)
        if current["Id"] != container_id:
            raise RuntimeError("managed container identity changed")
        _, foreign, available = snapshot(projects)
        blocked = foreign or clients_busy() or database_clients_busy(available)
        # Revalidate incoming leases only after external checks finish.
        with lease_lock():
            fresh_leases = live_leases()
            if (blocked or any(contains(project["root"], lease["workdir"])
                               for lease in fresh_leases)):
                seen[project["container"]] = time.time()
                atomic_json(state_file, seen)
                continue
        # Names may be reused; Docker IDs cannot refer to a replacement.
        run(["docker", "stop", "--time", "-1", container_id], timeout=75)
    # Recheck after database shutdown; another workload may have arrived.
    running, foreign, _ = snapshot(projects)
    quiet = all(now - seen[p["container"]] >= IDLE for p in projects)
    with lease_lock():
        leases = live_leases()
    if not leases and quiet and not running and not foreign and not clients_busy():
        run(["sudo", "-n", "systemctl", "stop", "docker.service"], timeout=100)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["enter", "leave", "tick"])
    parser.add_argument("--session")
    parser.add_argument("--pid", type=int)
    parser.add_argument("--work-dir")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    STATE.chmod(0o700)
    projects = json.loads(CONFIG.read_text())["projects"]
    if args.action == "tick":
        # Cleanup/startup runs serialize separately from incoming lease writes.
        with (STATE / "tick.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return  # Existing tick or the timer will see persistent leases.
            tick(projects, args.dry_run)
        return
    with lease_lock():
        if not args.session:
            parser.error("--session is required")
        key = hashlib.sha256(args.session.encode()).hexdigest()
        lease = STATE / f"lease-{key}.json"
        if args.action == "leave":
            lease.unlink(missing_ok=True)
            return
        if not args.pid or not args.work_dir:
            parser.error("enter requires --pid and --work-dir")
        identity = birth(args.pid)
        if identity is None:
            raise RuntimeError("work process is not alive")
        if not any(contains(p["root"], args.work_dir) for p in projects):
            return
        atomic_json(lease, {
            "pid": args.pid, "birth": identity,
            "workdir": str(Path(args.work_dir).resolve())
        })
    # Startup runs outside the short lease-write critical section.
    # The persistent lease also allows the timer to retry startup.
    with (STATE / "startup.log").open("a") as log:
        subprocess.Popen(
            ["/usr/bin/python3", str(Path(__file__).resolve()), "tick"],
            stdin=subprocess.DEVNULL, stdout=log, stderr=log,
            start_new_session=True, close_fds=True
        )


if __name__ == "__main__":
    main()

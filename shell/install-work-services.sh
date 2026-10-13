#!/usr/bin/env bash
# Install project-scoped Docker work services without interrupting current work.
set -euo pipefail

work_services_source="$(cd "$(dirname "$0")" && pwd)/bin/work-services.py"
work_services_fleet="${REVEALFLEET_ROOT:-$HOME/revealfleet}"
work_services_demo="${DEMO_FLEET_ROOT:-$HOME/demo-fleet}"

test -f "$work_services_source"
test -d "$work_services_fleet"
test -d "$work_services_demo"
command -v docker >/dev/null
command -v ss >/dev/null
sudo -n true

python3 - "$work_services_source" "$work_services_fleet" "$work_services_demo" <<'PY'
from pathlib import Path
import datetime
import json
import shutil
import sys

source, fleet, demo = map(Path, sys.argv[1:])
home = Path.home()
units = home / ".config/systemd/user"
config = home / ".config/revealfleet"
binary = home / ".local/bin/revealfleet-work-services"
state = home / ".local/share/revealfleet/work-services"

for directory in [units, config, binary.parent, state]:
    directory.mkdir(parents=True, exist_ok=True)
config.chmod(0o700)
state.chmod(0o700)

# Preserve operator mappings, including renamed PostgreSQL containers/projects.
# Validate before constructing or publishing any replacement lifecycle files.
project_config = config / "work-services.json"
if project_config.exists():
    project_contents = project_config.read_text()
    existing = json.loads(project_contents)
    projects = existing.get("projects")
    if not isinstance(projects, list) or not projects:
        raise ValueError("existing work-services projects must be a non-empty list")
    for project in projects:
        if not isinstance(project, dict) or any(
            not isinstance(project.get(key), str) or not project[key].strip()
            for key in ("root", "container", "compose_project")
        ):
            raise ValueError("invalid existing work-services project mapping")
        if not Path(project["root"]).is_absolute():
            raise ValueError("existing project roots must be absolute")
else:
    project_contents = json.dumps({
        "projects": [
            {"root": str(demo.resolve()), "container": "docker-postgres-1",
             "compose_project": "docker"},
            {"root": str(fleet.resolve()), "container": "revfleet-pg-dev",
             "compose_project": "pg-dev"}
        ]
    }, indent=2) + "\n"

files = {
    binary: source.read_text(),
    config / "work-services.json": project_contents,
    units / "revealfleet-work-services.service": """[Unit]
Description=RevealFleet work service idle cleanup

[Service]
Type=oneshot
ExecStart=%h/.local/bin/revealfleet-work-services tick
TimeoutStartSec=300
UMask=0077
""",
    units / "revealfleet-work-services.timer": """[Unit]
Description=Check RevealFleet work services for idle shutdown

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=5
Unit=revealfleet-work-services.service

[Install]
WantedBy=timers.target
""",
    units / "revdev-daemon.service.d/work-services.conf": """[Service]
Environment=REVDEV_WORK_SERVICES_COMMAND=%h/.local/bin/revealfleet-work-services
"""
}

backup = home / ".local/share/revealfleet" / (
    "work-services-backup-" +
    datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
)
backup.mkdir(parents=True, mode=0o700)

for index, (destination, contents) in enumerate(files.items()):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        shutil.copy2(destination, backup / f"{index}-{destination.name}")
    temporary = destination.with_name(destination.name + ".install-new")
    temporary.write_text(contents)
    temporary.chmod(0o755 if destination == binary else 0o600)
    temporary.replace(destination)

print(f"Previous lifecycle configuration preserved in {backup}")
PY

sudo -n systemctl disable docker.service
sudo -n systemctl enable --now docker.socket
systemctl --user daemon-reload
systemctl --user enable --now revealfleet-work-services.timer
echo "Installed. Running RevDev processes load the drop-in on their next start."

import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1] / "shell/bin/work-services.py"
spec = importlib.util.spec_from_file_location("work_services", path)
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)

PROJECTS = [
    {"root": "/projects/demo", "container": "demo"},
    {"root": "/projects/fleet", "container": "fleet"},
]

class LifecycleTests(unittest.TestCase):
    def test_starts_only_the_matching_project(self):
        starts, stops, _ = manager.plan(
            PROJECTS, [{"workdir": "/projects/fleet/app"}],
            set(), False, 1000, {}
        )
        self.assertEqual(starts, ["fleet"])
        self.assertEqual(stops, [])

    def test_waits_five_minutes_and_stops_both_idle_databases(self):
        _, stops, _ = manager.plan(
            PROJECTS, [], {"demo", "fleet"}, False, 299,
            {"demo": 0, "fleet": 0}
        )
        self.assertEqual(stops, [])
        _, stops, _ = manager.plan(
            PROJECTS, [], {"demo", "fleet"}, False, 300,
            {"demo": 0, "fleet": 0}
        )
        self.assertEqual(stops, ["demo", "fleet"])

    def test_other_work_blocks_shutdown_and_resets_idle(self):
        _, stops, seen = manager.plan(
            PROJECTS, [], {"demo", "fleet"}, True, 1000,
            {"demo": 0, "fleet": 0}
        )
        self.assertEqual(stops, [])
        self.assertEqual(seen, {"demo": 1000, "fleet": 1000})

    def test_last_session_keeps_its_database_running(self):
        _, stops, _ = manager.plan(
            PROJECTS, [{"workdir": "/projects/fleet"}],
            {"demo", "fleet"}, False, 1000,
            {"demo": 0, "fleet": 0}
        )
        self.assertEqual(stops, ["demo"])

    def test_similar_directory_name_does_not_match(self):
        self.assertFalse(manager.contains("/projects/fleet", "/projects/fleet-other"))

    def test_real_process_birth_is_available(self):
        self.assertIsNotNone(manager.birth(__import__("os").getpid()))

    def test_same_pid_and_start_time_from_another_boot_do_not_match(self):
        import os
        from unittest.mock import patch
        stat = Path(f"/proc/{os.getpid()}/stat").read_text()
        identities = []
        for boot in ("previous-boot", "current-boot"):
            def read(path, boot=boot):
                return boot if str(path) == "/proc/sys/kernel/random/boot_id" else stat
            with patch.object(Path, "read_text", read):
                identities.append(manager.birth(os.getpid()))
        self.assertNotEqual(*identities)

    def test_legacy_lease_without_boot_identity_is_not_adopted(self):
        import json
        import os
        import tempfile
        from unittest.mock import patch
        pid = os.getpid()
        start = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
        with tempfile.TemporaryDirectory() as directory:
            lease = Path(directory) / "lease-legacy.json"
            lease.write_text(json.dumps({"pid": pid, "birth": start, "workdir": "/projects/fleet"}))
            with patch.object(manager, "STATE", Path(directory)):
                self.assertEqual(manager.live_leases(), [])
            self.assertFalse(lease.exists())


class OwnershipTests(unittest.TestCase):
    def test_cold_start_rejects_foreign_container_before_start(self):
        import json
        import tempfile
        from unittest.mock import patch
        project = {
            "root": "/projects/fleet", "container": "fleet",
            "compose_project": "expected"
        }
        foreign = [{"Config": {"Labels": {
            "com.docker.compose.project": "foreign",
            "com.docker.compose.service": "postgres"
        }}}]
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(manager, "STATE", Path(directory)), \
                 patch.object(manager, "live_leases", return_value=[
                     {"workdir": "/projects/fleet"}
                 ]), \
                 patch.object(manager, "docker_active", return_value=False), \
                 patch.object(manager, "run", return_value=json.dumps(foreign)) as run:
                with self.assertRaisesRegex(RuntimeError, "ownership changed"):
                    manager.tick([project])
                self.assertEqual(
                    run.call_args_list[0].args[0],
                    ["docker", "inspect", "fleet"]
                )
                self.assertEqual(run.call_count, 1)

class ActiveDockerStartupTests(unittest.TestCase):
    def test_absent_unrelated_container_does_not_block_requested_start(self):
        import json
        import subprocess
        import tempfile
        from unittest.mock import patch
        projects = [
            {"root": "/projects/demo", "container": "demo", "compose_project": "demo"},
            {"root": "/projects/fleet", "container": "fleet", "compose_project": "fleet"},
        ]
        running = set()
        calls = []
        def docker(args, timeout=15):
            calls.append(args)
            if args[1] == "ps":
                return "fleet\n" if "--all" in args else "\n".join(running)
            if args[1] == "inspect":
                if args[2] == "demo":
                    raise subprocess.CalledProcessError(1, args)
                return json.dumps([{"Config": {"Labels": {
                    "com.docker.compose.project": "fleet",
                    "com.docker.compose.service": "postgres",
                }}}])
            if args[1] == "start":
                running.add(args[2])
                return ""
            raise AssertionError(args)
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(manager, "STATE", Path(directory)), \
                 patch.object(manager, "live_leases", return_value=[{"workdir": "/projects/fleet"}]), \
                 patch.object(manager, "docker_active", return_value=True), \
                 patch.object(manager, "clients_busy", return_value=False), \
                 patch.object(manager, "database_clients_busy", return_value=False) as clients, \
                 patch.object(manager, "run", side_effect=docker):
                manager.tick(projects)
                self.assertEqual(clients.call_args.args[0], [projects[1]])
        self.assertEqual(running, {"fleet"})
        self.assertFalse(any(args[1:] == ["inspect", "demo"] for args in calls))


class InventorySafetyTests(unittest.TestCase):
    def test_existing_unrelated_container_still_requires_ownership(self):
        import json
        from unittest.mock import patch
        project = {"root": "/projects/demo", "container": "demo", "compose_project": "demo"}
        def docker(args, timeout=15):
            if args[1] == "ps": return "demo\n"
            return json.dumps([{"Config": {"Labels": {
                "com.docker.compose.project": "foreign",
                "com.docker.compose.service": "postgres",
            }}}])
        with patch.object(manager, "run", side_effect=docker):
            with self.assertRaisesRegex(RuntimeError, "ownership changed"):
                manager.snapshot([project])

    def test_incomplete_inventory_does_not_authorize_start_or_cleanup(self):
        import subprocess
        from unittest.mock import patch
        with patch.object(manager, "run", side_effect=["", subprocess.CalledProcessError(1, ["docker", "ps", "--all"])]):
            with self.assertRaises(subprocess.CalledProcessError):
                manager.snapshot([])

    def test_missing_requested_database_still_fails_before_start(self):
        import subprocess
        import tempfile
        from unittest.mock import patch
        project = {"root": "/projects/fleet", "container": "fleet", "compose_project": "fleet"}
        calls = []
        def docker(args, timeout=15):
            calls.append(args)
            if args[1] == "ps": return ""
            raise subprocess.CalledProcessError(1, args)
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(manager, "STATE", Path(directory)), \
                 patch.object(manager, "live_leases", return_value=[{"workdir": "/projects/fleet"}]), \
                 patch.object(manager, "docker_active", return_value=True), \
                 patch.object(manager, "clients_busy", return_value=False), \
                 patch.object(manager, "database_clients_busy", return_value=False), \
                 patch.object(manager, "run", side_effect=docker):
                with self.assertRaises(subprocess.CalledProcessError):
                    manager.tick([project])
        self.assertFalse(any(args[1] in ("start", "stop") for args in calls))

    def test_foreign_running_container_still_blocks_cleanup(self):
        from unittest.mock import patch
        with patch.object(manager, "run", side_effect=["unrelated-work\n", "unrelated-work\n"]):
            running, foreign, available = manager.snapshot([])
        self.assertEqual(running, {"unrelated-work"})
        self.assertTrue(foreign)
        self.assertEqual(available, [])


if __name__ == "__main__":
    unittest.main()

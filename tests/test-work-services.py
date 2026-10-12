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

if __name__ == "__main__":
    unittest.main()

"""Opt-in native Windows/WSL LX reparse integration; synthetic state only.

Run on Windows with the existing Ubuntu distribution:
  $env:REVKIT_RUN_WSL_INTEGRATION = '1'
  python -B -m unittest discover -s tests -p test_codex_wsl_integration.py -v

The writer guard is mocked only for the isolated synthetic fixture. This test
does not establish production writer detection or application adoption.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid

from test_codex_home_migrate import ADAPTER, fixture


@unittest.skipUnless(
    os.name == "nt" and os.environ.get("REVKIT_RUN_WSL_INTEGRATION") == "1",
    "requires opt-in native Windows with the existing Ubuntu WSL distribution",
)
class WslLxReparseIntegrationTests(unittest.TestCase):
    def test_actual_lx_link_is_retained_in_source_and_regenerated_in_copy(self):
        executable = shutil.which("wsl.exe")
        self.assertIsNotNone(executable, "WSL executable must already be installed")
        with tempfile.TemporaryDirectory(prefix="revealfleet-lx-integration-") as name:
            base = Path(name)
            source, target = base / "source", base / "target"
            fixture(source)
            self.assertEqual((source / "auth.json").read_bytes(), b'{"synthetic":true}\r\n')
            relative = Path("tmp") / "arg0-linux" / ("codex-arg0" + uuid.uuid4().hex) / "apply_patch"
            link = source / relative
            link.parent.mkdir(parents=True)
            conversion = subprocess.run(
                [executable, "--distribution", "Ubuntu", "--exec", "wslpath", "-u", str(link)],
                capture_output=True,
                timeout=30,
            )
            self.assertEqual(conversion.returncode, 0, "WSL path conversion failed")
            linux_path = conversion.stdout.decode("utf-8-sig").strip()
            self.assertTrue(linux_path.startswith("/mnt/"), "fixture must reside on an automounted Windows volume")
            self.assertNotIn("\n", linux_path)
            try:
                creation = subprocess.run(
                    [executable, "--distribution", "Ubuntu", "--exec", "/usr/bin/ln", "-s", "--",
                     "/nonexistent/revealfleet-synthetic-link-target", linux_path],
                    capture_output=True,
                    timeout=30,
                )
                self.assertEqual(creation.returncode, 0, "WSL synthetic link creation failed")
                self.assertEqual(link.lstat().st_reparse_tag, 0xA000001D)
                before = ADAPTER.inventory(source)
                self.assertEqual(before[relative.as_posix()]["kind"], "regenerate")
                with patch.object(ADAPTER, "writers"):
                    result = ADAPTER.prepare(source, target)
                self.assertEqual(ADAPTER.inventory(source), before)
                self.assertEqual(link.lstat().st_reparse_tag, 0xA000001D)
                self.assertFalse(os.path.lexists(target / relative))
                self.assertTrue(result["storage_copy_verified"])
                self.assertFalse(result["ready_for_activation"])
                self.assertTrue(any(item["field"] == "app-command-links" for item in result["pending"]))
            finally:
                link.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()

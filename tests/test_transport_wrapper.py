"""Synthetic transport and actual shell/process deadline tests; no network credentials."""
import contextlib
import email.message
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
import urllib.request
import urllib.response

from test_probe import probe, ROOT, TOKEN, NEGOTIATION, PROBE_SOURCE


class SyntheticHTTPS(urllib.request.HTTPSHandler):
    def __init__(self, redirect=False):
        super().__init__()
        self.requests = []
        self.redirect = redirect

    def https_open(self, request):
        self.requests.append(request)
        headers = email.message.Message()
        headers["Content-Type"] = "application/json"
        if self.redirect:
            headers["Location"] = "https://foreign.invalid/api/mcp"
            response = urllib.response.addinfourl(io.BytesIO(b""), headers, request.full_url, 302)
        else:
            body = json.loads(request.data)
            if body["method"] == "initialize":
                data = {"jsonrpc": "2.0", "id": 1, "result": NEGOTIATION}
                code = 200
            elif body["method"] == "tools/list":
                data = {"jsonrpc": "2.0", "id": 2,
                        "result": {"tools": [{"name": "synthetic-read", "inputSchema": {}}]}}
                code = 200
            else:
                data, code = {}, 202
            response = urllib.response.addinfourl(io.BytesIO(json.dumps(data).encode()), headers,
                                                 request.full_url, code)
        response.msg = "synthetic"
        return response


class TransportWrapperTests(unittest.TestCase):
    def test_actual_opener_protocol_and_redirect(self):
        original_build = urllib.request.build_opener
        for redirect in (False, True):
            transport = SyntheticHTTPS(redirect)
            def build(*handlers):
                return original_build(urllib.request.ProxyHandler({}), transport, *handlers)
            with self.subTest(redirect=redirect), \
                    patch.dict(os.environ, {"REVEALUI_MCP_TOKEN": TOKEN,
                                            "REVEALUI_MCP_URL": "https://synthetic.invalid/api/mcp"}), \
                    patch.object(probe.urllib.request, "build_opener", side_effect=build), \
                    contextlib.redirect_stdout(io.StringIO()):
                if redirect:
                    with self.assertRaises(probe.ProbeFailure):
                        probe.run()
                    self.assertEqual(len(transport.requests), 1)
                else:
                    probe.run()
                    self.assertEqual(len(transport.requests), 3)
                self.assertEqual(transport.requests[0].get_header("Authorization"), "Bearer " + TOKEN)

    def test_embedded_bytes_match(self):
        shell = (ROOT / "shell/bin/revealui-mcp-smoke.sh").read_bytes()
        embedded = shell.split(b"exec python3 - <<'PY_MCP'\n", 1)[1].split(b"PY_MCP\nSH_MCP\n", 1)[0]
        self.assertEqual(embedded, PROBE_SOURCE.read_bytes())

    def test_whole_wrapper_kills_sigterm_resistant_children(self):
        real_timeout = shutil.which("timeout")
        self.assertIsNotNone(real_timeout)
        for phase in ("vault", "http"):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                (root / "bin").mkdir()
                (root / "lib").mkdir()
                helper = root / "bin/revealui-mcp-smoke.sh"
                shutil.copyfile(ROOT / "shell/bin/revealui-mcp-smoke.sh", helper)
                # Test acceleration only. Check exact production deadline arguments.
                timer = root / "bin/timeout"
                timer.write_text('#!/bin/bash\nset -eu\n'
                                 'test "$1" = --kill-after=5s\ntest "$2" = 60s\nshift 2\n'
                                 f'exec {real_timeout} --kill-after=0.2s 0.2s "$@"\n')
                timer.chmod(0o755)
                hang = root / "bin/hang"
                hang.write_text('#!/usr/bin/python3\nimport signal,time,os\n'
                                'signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
                                'open(os.environ["TEST_CHILD_PID"], "w").write(str(os.getpid()))\n'
                                'while True: time.sleep(0.1)\n')
                hang.chmod(0o755)
                loader = root / "lib/revealui-mcp-env.sh"
                if phase == "vault":
                    loader.write_text('_revealui_mcp_env_load() { hang; }\n')
                else:
                    loader.write_text('_revealui_mcp_env_load() { export REVEALUI_MCP_TOKEN=synthetic; }\n')
                    shutil.copyfile(hang, root / "bin/python3")
                    (root / "bin/python3").chmod(0o755)
                started = time.monotonic()
                pid_file = root / "child.pid"
                process = subprocess.Popen(["bash", str(helper)],
                                           env={**os.environ, "PATH": str(root / "bin") + ":/usr/bin:/bin",
                                                "TEST_CHILD_PID": str(pid_file)},
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           start_new_session=True)
                try:
                    process.communicate(timeout=5)
                finally:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=2)
                self.assertIn(process.returncode, (137, -9))
                self.assertLess(time.monotonic() - started, 3)
                self.assertTrue(pid_file.exists(), "resistant child must actually start")
                child_stat = Path("/proc") / pid_file.read_text() / "stat"
                if child_stat.exists():
                    self.assertIn(child_stat.read_text().split()[2], ("Z", "X"))

    def test_macos_coreutils_timeout_name(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "dirname").symlink_to(shutil.which("dirname"))
            timer = root / "gtimeout"
            timer.write_text('#!/bin/bash\nset -eu\n'
                             'test "$1" = --kill-after=5s\ntest "$2" = 60s\n'
                             'test "$3" = bash\nprintf "gtimeout admitted\\n"\n')
            timer.chmod(0o755)
            result = subprocess.run(
                [shutil.which("bash"), str(ROOT / "shell/bin/revealui-mcp-smoke.sh")],
                env={"PATH": str(root)}, text=True, capture_output=True, timeout=5,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("gtimeout admitted", result.stdout)


if __name__ == "__main__":
    unittest.main()

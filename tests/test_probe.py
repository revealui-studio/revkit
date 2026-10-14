import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
PROBE_SOURCE = ROOT / "probe.py"
if not PROBE_SOURCE.exists():
    PROBE_SOURCE = ROOT / "tests/mcp-smoke/probe.py"
spec = importlib.util.spec_from_file_location("probe", PROBE_SOURCE)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
TOKEN = "rvui_dev_" + "a" * 64
NEGOTIATION = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
               "serverInfo": {"name": "synthetic", "version": "1"}}


class Response(io.BytesIO):
    def __init__(self, body, status=200, headers=None):
        super().__init__(body)
        self.status = status
        self.headers = headers or {"Content-Type": "application/json"}


def result(id, data, headers=None):
    return Response(json.dumps({"jsonrpc": "2.0", "id": id, "result": data}).encode(), headers=headers)


class ProbeTests(unittest.TestCase):
    def test_json_rpc_error_rejected(self):
        with self.assertRaises(probe.ProbeFailure):
            probe.rpc_result(Response(b'{"jsonrpc":"2.0","id":1,"error":{"message":"secret"}}'), 1)

    def test_wrong_id_rejected(self):
        with self.assertRaises(probe.ProbeFailure):
            probe.rpc_result(result(3, {}), 1)

    def test_html_rejected(self):
        with self.assertRaises(probe.ProbeFailure):
            probe.rpc_result(Response(b"html", headers={"Content-Type": "text/html"}), 1)

    def test_sse_result(self):
        response = Response(b': keepalive\n\ndata: {"jsonrpc":"2.0","id":1,"result":{"ok":true}}\n\n',
                            headers={"Content-Type": "text/event-stream"})
        self.assertEqual(probe.rpc_result(response, 1), {"ok": True})

    def test_large_response_rejected(self):
        with self.assertRaises(probe.ProbeFailure):
            probe.rpc_result(Response(b" " * 1048577), 1)

    def test_redirect_refused(self):
        with self.assertRaises(probe.ProbeFailure):
            probe.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.test")

    def exercise(self, responses, url="https://api.revealui.com/api/mcp"):
        requests = []
        class Opener:
            def open(self, request, timeout):
                requests.append(request)
                item = responses.pop(0)
                if isinstance(item, Exception):
                    raise item
                return item
        with patch.dict(os.environ, {"REVEALUI_MCP_TOKEN": TOKEN, "REVEALUI_MCP_URL": url}), \
                patch.object(probe.urllib.request, "build_opener", return_value=Opener()), \
                contextlib.redirect_stdout(io.StringIO()):
            probe.run()
        return requests

    def test_successful_protocol_sequence_and_cleanup(self):
        requests = self.exercise([
            result(1, NEGOTIATION,
                   {"Content-Type": "application/json", "Mcp-Session-Id": "our-session"}),
            Response(b"", 202),
            result(2, {"tools": [{"name": "read", "inputSchema": {}}]}),
            Response(b"", 204)])
        self.assertEqual([r.method for r in requests], ["POST", "POST", "POST", "DELETE"])
        self.assertEqual(requests[2].get_header("Mcp-session-id"), "our-session")
        self.assertNotIn(TOKEN, requests[2].data.decode())

    def test_http_500_fails(self):
        with self.assertRaises(urllib.error.HTTPError):
            self.exercise([urllib.error.HTTPError("https://api.revealui.com/api/mcp", 500, "", {}, None)])

    def test_empty_tools_fails(self):
        with self.assertRaises(probe.ProbeFailure):
            self.exercise([result(1, NEGOTIATION),
                           Response(b"", 202), result(2, {"tools": []})])

    def test_http_endpoint_fails_before_network(self):
        with self.assertRaises(probe.ProbeFailure):
            self.exercise([], url="http://api.revealui.com/api/mcp")

    def test_boolean_and_float_rpc_ids_rejected(self):
        for id in (True, 1.0):
            with self.subTest(id=id), self.assertRaises(probe.ProbeFailure):
                probe.rpc_result(result(id, {}), 1)

    def test_boolean_sse_id_rejected(self):
        with self.assertRaises(probe.ProbeFailure):
            probe.rpc_result(Response(b'data: {"jsonrpc":"2.0","id":true,"result":{}}\n\n',
                                     headers={"Content-Type": "text/event-stream"}), 1)

    def test_incomplete_negotiation_rejected(self):
        for invalid in ({**NEGOTIATION, "serverInfo": None},
                        {**NEGOTIATION, "serverInfo": {"name": "", "version": "1"}},
                        {**NEGOTIATION, "capabilities": {}},
                        {**NEGOTIATION, "capabilities": {"tools": True}}):
            with self.subTest(invalid=invalid), self.assertRaises(probe.ProbeFailure):
                self.exercise([result(1, invalid)])

    def test_stateless_version_headers(self):
        requests = self.exercise([result(1, NEGOTIATION), Response(b"", 202),
                                 result(2, {"tools": [{"name": "read", "inputSchema": {}}]})])
        self.assertIsNone(requests[0].get_header("Mcp-protocol-version"))
        for request in requests[1:]:
            self.assertEqual(request.get_header("Mcp-protocol-version"), "2025-06-18")
            self.assertIsNone(request.get_header("Mcp-session-id"))


if __name__ == "__main__":
    unittest.main()

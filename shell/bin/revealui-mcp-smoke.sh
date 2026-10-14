#!/usr/bin/env bash
# revealui-mcp-smoke — fleet-owned; never prints secrets.
# MCP initialization and discovery only; no tool execution or permission proof.
# Exit: 0 discovery passed, 1 protocol/auth failure, 2 network/config error.
# GNU timeout exits 124 or 137 on deadline. Cleanup may be skipped on termination;
# abandoned sessions rely on the server TTL. Tokens remain private process data.
set -euo pipefail
command -v timeout >/dev/null || { echo "FAIL  timeout required" >&2; exit 2; }
# Bound loader/vault lookup as well as HTTP, with forced group termination.
exec timeout --kill-after=5s 60s bash -s -- "$(dirname "${BASH_SOURCE[0]}")" <<'SH_MCP'
set -euo pipefail
# Keep the supervised shell alive through TERM so timeout kills its entire group
# after the grace period, including any vault child that ignores TERM.
trap '' TERM
# Load MCP env in-process (never print the token). Same lib rfg sources.
_load_mcp_lib() {
  local here candidates f
  here="$1"
  candidates=(
    "$here/../lib/revealui-mcp-env.sh"
    "$(dirname "$here")/lib/revkit/revealui-mcp-env.sh"
    "${REVEALUI_ROOT:-}/shell/lib/revealui-mcp-env.sh"
  )
  for f in "${candidates[@]}"; do
    if [ -n "$f" ] && [ -f "$f" ]; then
      # shellcheck disable=SC1090
      . "$f"
      return 0
    fi
  done
  return 1
}

_load_mcp_lib "$1" || {
  echo "revealui-mcp-smoke: revealui-mcp-env.sh not found (re-run revkit bootstrap)" >&2
  exit 2
}
REVEALUI_MCP_ENV_STRICT=1
export REVEALUI_MCP_ENV_STRICT
_revealui_mcp_env_load || exit 1

exec python3 - <<'PY_MCP'
"""Embedded by the maintained shell helper; never print response bodies or tokens."""
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request


class ProbeFailure(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ProbeFailure("redirect refused")


def rpc_result(response, expected_id):
    content_type = response.headers.get("Content-Type", "").split(";")[0].strip()
    if content_type == "application/json":
        data = response.read(1048577)
        if len(data) > 1048576:
            raise ProbeFailure("response too large")
        messages = [json.loads(data)]
    elif content_type == "text/event-stream":
        total, event = 0, []
        messages = []
        while True:
            line = response.readline(1048577)
            total += len(line)
            if total > 1048576:
                raise ProbeFailure("response too large")
            if not line:
                break
            if line.startswith(b"data:"):
                event.append(line[5:].strip())
            elif not line.strip() and event:
                message = json.loads(b"\n".join(event))
                event = []
                if (isinstance(message, dict) and type(message.get("id")) is int
                        and message["id"] == expected_id):
                    messages = [message]
                    break
    else:
        raise ProbeFailure("unexpected response type")
    for message in messages:
        if (isinstance(message, dict) and type(message.get("id")) is int
                and message["id"] == expected_id):
            if message.get("jsonrpc") != "2.0" or "error" in message:
                raise ProbeFailure("MCP RPC failed")
            result = message.get("result")
            if not isinstance(result, dict):
                raise ProbeFailure("invalid MCP result")
            return result
    raise ProbeFailure("missing MCP response")


def run():
    token = os.environ.pop("REVEALUI_MCP_TOKEN", "")
    if not re.fullmatch(r"rvui_dev_[0-9a-f]{64}", token):
        raise ProbeFailure("invalid token shape")
    url = os.environ.get("REVEALUI_MCP_URL", "https://api.revealui.com/api/mcp")
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username
            or parsed.password or parsed.query or parsed.fragment
            or parsed.path != "/api/mcp"):
        raise ProbeFailure("expected HTTPS /api/mcp endpoint")
    opener = urllib.request.build_opener(NoRedirect())
    session = None
    protocol = "2025-06-18"
    negotiated = False

    def request(method, body=None):
        headers = {"Authorization": "Bearer " + token,
                   "Accept": "application/json, text/event-stream"}
        if session:
            headers["Mcp-Session-Id"] = session
        if negotiated:
            headers["MCP-Protocol-Version"] = protocol
        if body is not None:
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(),
                                     headers=headers, method=method)
        return opener.open(req, timeout=10)

    try:
        with request("POST", {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                              "params": {"protocolVersion": protocol, "capabilities": {},
                                         "clientInfo": {"name": "revealfleet-smoke", "version": "1"}}}) as response:
            if response.status != 200:
                raise ProbeFailure("initialize HTTP failure")
            session = response.headers.get("Mcp-Session-Id")
            if session and (len(session) > 1024 or "\r" in session or "\n" in session):
                raise ProbeFailure("invalid session header")
            result = rpc_result(response, 1)
            capabilities = result.get("capabilities")
            server = result.get("serverInfo")
            if (result.get("protocolVersion") != protocol or not isinstance(capabilities, dict)
                    or not isinstance(capabilities.get("tools"), dict)
                    or not isinstance(server, dict)
                    or any(not isinstance(server.get(key), str) or not server[key]
                           for key in ("name", "version"))):
                raise ProbeFailure("unsupported MCP negotiation")
            negotiated = True
        with request("POST", {"jsonrpc": "2.0", "method": "notifications/initialized"}) as response:
            if response.status != 202:
                raise ProbeFailure("initialization notification HTTP failure")
        with request("POST", {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}) as response:
            if response.status != 200:
                raise ProbeFailure("tool discovery HTTP failure")
            result = rpc_result(response, 2)
            tools = result.get("tools")
            if not isinstance(tools, list) or not tools or any(
                    not isinstance(tool, dict) or not isinstance(tool.get("name"), str)
                    or not tool["name"] or not isinstance(tool.get("inputSchema"), dict) for tool in tools):
                raise ProbeFailure("invalid or empty tool discovery")
        print("PASS  authenticated MCP initialization and tool discovery")
        print("Scope: discovery only; tool permissions and vendor model execution remain unverified")
    finally:
        if session:
            try:
                with request("DELETE") as response:
                    if response.status not in (200, 204):
                        print("WARN  MCP session cleanup failed", file=sys.stderr)
            except Exception:
                print("WARN  MCP session cleanup failed", file=sys.stderr)


if __name__ == "__main__":
    try:
        run()
    except urllib.error.HTTPError as error:
        print("FAIL  MCP HTTP " + str(error.code), file=sys.stderr)
        sys.exit(1)
    except ProbeFailure as error:
        print("FAIL  " + str(error), file=sys.stderr)
        sys.exit(1)
    except Exception:
        print("FAIL  MCP network or response validation", file=sys.stderr)
        sys.exit(2)
PY_MCP
SH_MCP

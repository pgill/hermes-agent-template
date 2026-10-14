import json
import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]


def _probe(enabled: str | None) -> dict:
    env = os.environ.copy()
    env["ADMIN_PASSWORD"] = "test-admin-password"
    if enabled is None:
        env.pop("HERMES_PUBLIC_WEBHOOK_PROXY_ENABLED", None)
    else:
        env["HERMES_PUBLIC_WEBHOOK_PROXY_ENABLED"] = enabled

    code = r'''
import json
from starlette.requests import Request
import server


def request(method, path):
    return Request({
        "type": "http",
        "http_version": "1.1",
        "method": method,
        "scheme": "https",
        "path": path,
        "raw_path": path.encode(),
        "query_string": b"",
        "headers": [(b"accept", b"application/json")],
        "client": ("127.0.0.1", 12345),
        "server": ("example.test", 443),
    })

route_specs = {
    route.path: sorted(route.methods)
    for route in server.routes
    if hasattr(route, "methods")
}
post_guard = server.guard(request("POST", "/p/trader/webhooks/trader-alerts"))
get_guard = server.guard(request("GET", "/p/trader/webhooks/trader-alerts"))
print(json.dumps({
    "enabled": getattr(server, "PUBLIC_WEBHOOK_PROXY_ENABLED", False),
    "route_specs": route_specs,
    "post_guard": None if post_guard is None else post_guard.status_code,
    "get_guard": None if get_guard is None else get_guard.status_code,
}))
'''
    result = subprocess.run(
        [sys.executable, "-c", code],
        cwd=REPO_ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout.splitlines()[-1])


def test_public_webhook_proxy_is_disabled_by_default() -> None:
    result = _probe(None)

    assert result["enabled"] is False
    assert "/webhooks/{route_name}" not in result["route_specs"]
    assert "/p/{profile}/webhooks/{route_name}" not in result["route_specs"]
    assert result["post_guard"] == 401


def test_public_webhook_proxy_is_enabled_only_by_opt_in() -> None:
    result = _probe("true")

    assert result["enabled"] is True
    assert result["route_specs"]["/webhooks/{route_name}"] == ["POST"]
    assert result["route_specs"]["/p/{profile}/webhooks/{route_name}"] == ["POST"]
    assert result["post_guard"] is None
    assert result["get_guard"] == 401


def test_proxy_preserves_raw_body_and_signature_headers() -> None:
    env = os.environ.copy()
    env["ADMIN_PASSWORD"] = "test-admin-password"
    env["HERMES_PUBLIC_WEBHOOK_PROXY_ENABLED"] = "true"
    code = r'''
import asyncio
import json
from starlette.requests import Request
import server

raw = b'{"body":"spacing stays exact", "n":1}'
captured = {}

class Upstream:
    status_code = 401
    content = b'{"error":"Invalid signature"}'
    headers = {"content-type": "application/json"}

class Client:
    async def request(self, method, target, headers, content):
        captured.update(method=method, target=target, headers=headers, content=content)
        return Upstream()

sent = False
async def receive():
    global sent
    if sent:
        return {"type": "http.disconnect"}
    sent = True
    return {"type": "http.request", "body": raw, "more_body": False}

request = Request({
    "type": "http", "http_version": "1.1", "method": "POST",
    "scheme": "https", "path": "/p/trader/webhooks/trader-alerts",
    "raw_path": b"/p/trader/webhooks/trader-alerts", "query_string": b"",
    "headers": [
        (b"host", b"example.test"),
        (b"x-webhook-signature-v2", b"deadbeef"),
        (b"x-webhook-timestamp", b"123"),
        (b"x-request-id", b"request-1"),
    ],
    "client": ("127.0.0.1", 12345), "server": ("example.test", 443),
}, receive)
server.get_http_client = lambda: Client()
response = asyncio.run(server._proxy_to_webhook(request))
print(json.dumps({
    "status": response.status_code,
    "body_hex": captured["content"].hex(),
    "headers": captured["headers"],
    "target": captured["target"],
}))
'''
    result = subprocess.run(
        [sys.executable, "-c", code], cwd=REPO_ROOT, env=env,
        check=True, capture_output=True, text=True,
    )
    data = json.loads(result.stdout.splitlines()[-1])

    assert data["status"] == 401
    assert bytes.fromhex(data["body_hex"]) == b'{"body":"spacing stays exact", "n":1}'
    assert data["headers"]["x-webhook-signature-v2"] == "deadbeef"
    assert data["headers"]["x-webhook-timestamp"] == "123"
    assert data["headers"]["x-request-id"] == "request-1"
    assert "host" not in data["headers"]
    assert data["target"] == "http://127.0.0.1:8644/p/trader/webhooks/trader-alerts"

import os

os.environ.setdefault("ADMIN_PASSWORD", "test-admin-password")

from starlette.requests import Request

import server


def _request(method: str, path: str, *, accept: str = "application/json") -> Request:
    scope = {
        "type": "http",
        "http_version": "1.1",
        "method": method,
        "scheme": "https",
        "path": path,
        "raw_path": path.encode(),
        "query_string": b"",
        "headers": [(b"accept", accept.encode())],
        "client": ("127.0.0.1", 12345),
        "server": ("example.test", 443),
    }
    return Request(scope)


def test_profile_webhook_post_bypasses_admin_login() -> None:
    request = _request("POST", "/p/trader/webhooks/trader-alerts")

    assert server.guard(request) is None


def test_unprofiled_webhook_post_bypasses_admin_login() -> None:
    request = _request("POST", "/webhooks/trader-alerts")

    assert server.guard(request) is None


def test_non_post_webhook_request_does_not_bypass_admin_login() -> None:
    request = _request("GET", "/p/trader/webhooks/trader-alerts")

    response = server.guard(request)

    assert response is not None
    assert response.status_code == 401


def test_webhook_route_patterns_are_post_only_and_before_catch_all() -> None:
    route_specs = [(route.path, route.methods) for route in server.routes if hasattr(route, "methods")]
    catch_all_index = next(i for i, (path, _) in enumerate(route_specs) if path == "/{path:path}")

    for path in ("/webhooks/{route_name}", "/p/{profile}/webhooks/{route_name}"):
        index = next(i for i, (candidate, _) in enumerate(route_specs) if candidate == path)
        assert index < catch_all_index
        assert route_specs[index][1] == {"POST"}

"""Opt-in: validate generated graphs against the REAL Rust backend (graph.rs + routing.rs).

    INVIEW_BACKEND_E2E=1 CARGO_TARGET_DIR=/tmp/inview-target .venv/bin/python -m pytest tests/test_nav_graph_backend.py

Builds `inview-backend`, runs it on a free loopback port with a throwaway scan directory, uploads a
graph with `PUT /graphs/{id}` and asks `POST /graphs/{id}/routes` for routes. Never touches :3000.
"""
import json
import os
import socket
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

from test_nav_graph import build, suite

pytestmark = pytest.mark.skipif(os.environ.get("INVIEW_BACKEND_E2E") != "1",
                                reason="set INVIEW_BACKEND_E2E=1 to run against the real backend")
BACKEND = Path(__file__).resolve().parents[2]


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="module")
def backend(tmp_path_factory):
    target = os.environ.get("CARGO_TARGET_DIR", "/tmp/inview-nav-graph-target")
    env = {key: value for key, value in os.environ.items() if key != "INVIEW_API_TOKEN"}
    env["CARGO_TARGET_DIR"] = target
    subprocess.run(["cargo", "build", "--quiet", "--manifest-path", str(BACKEND / "Cargo.toml")], check=True, env=env)
    port = _free_port()
    scans = tmp_path_factory.mktemp("scans")
    process = subprocess.Popen([f"{target}/debug/inview-backend"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               env={**env, "INVIEW_BIND": f"127.0.0.1:{port}", "INVIEW_SCAN_DIR": str(scans)})
    url = f"http://127.0.0.1:{port}"
    try:
        for _ in range(100):
            try:
                urllib.request.urlopen(f"{url}/health", timeout=1)
                break
            except OSError:
                time.sleep(0.1)
        yield url
    finally:
        process.terminate()
        process.wait(timeout=10)


def _call(method: str, url: str, body: dict) -> tuple[int, dict]:
    request = urllib.request.Request(url, json.dumps(body, allow_nan=False).encode(), method=method,
                                     headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read() or b"{}")


def _ends(graph):
    west = min(graph["nodes"], key=lambda n: n["x"])["id"]
    east = max(graph["nodes"], key=lambda n: n["x"])["id"]
    return west, east


PLACES = [{"id": "a", "category": "information", "name": "Desk A", "position_m": [-3.0, 0.0, -1.2]},
          {"id": "b", "category": "seating", "name": "Bench B", "position_m": [6.0, 0.0, 1.0]}]


def test_backend_accepts_graph_and_routes_across_rooms(backend):
    _, result = build(suite(door_a=1.0, door_b=1.0), places=PLACES)
    graph = result.graph
    status, body = _call("PUT", f"{backend}/graphs/{graph['id']}", graph)
    assert status == 200, body
    west, east = "place-a", "place-b"
    status, route = _call("POST", f"{backend}/graphs/{graph['id']}/routes", {"from": west, "to": east})
    assert status == 200, route
    assert route["node_ids"][0] == west and route["node_ids"][-1] == east
    assert "door-door-a" in route["node_ids"] and "door-door-b" in route["node_ids"]
    status, strict = _call("POST", f"{backend}/graphs/{graph['id']}/routes",
                           {"from": west, "to": east,
                            "requirements": {"requires_step_free": True, "minimum_clear_width_m": 0.9}})
    assert status == 200, strict


def test_backend_refuses_wide_route_through_narrow_door(backend):
    _, result = build(suite(door_b=0.7))
    graph = result.graph
    assert _call("PUT", f"{backend}/graphs/{graph['id']}", graph)[0] == 200
    west, east = _ends(graph)
    assert _call("POST", f"{backend}/graphs/{graph['id']}/routes", {"from": west, "to": east})[0] == 200
    status, body = _call("POST", f"{backend}/graphs/{graph['id']}/routes",
                         {"from": west, "to": east, "requirements": {"minimum_clear_width_m": 0.9}})
    assert status == 422 and body["error"]["code"] == "no_verified_route"

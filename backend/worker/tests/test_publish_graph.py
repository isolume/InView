import logging

import pytest

from inview_worker.client import BackendError
from inview_worker.core import registry
from inview_worker.core.stage import Product
from inview_worker.publishers.graph import publish_nav_graph


class FakeBackend:
    def __init__(self, error: BackendError | None = None):
        self.calls: list[tuple[str, object]] = []
        self.error = error

    def put_json(self, path, value):
        self.calls.append((path, value))
        if self.error:
            raise self.error
        return {"id": value["id"], "schema_version": 1, "node_count": len(value["nodes"]),
                "edge_count": len(value["edges"])}


def graph(graph_id="scan/1-nav"):
    return {"schema_version": 1, "id": graph_id, "metadata": {},
            "nodes": [{"id": "a", "map_id": "m", "floor_id": "f", "x": 0, "y": 0, "z": 0},
                      {"id": "b", "map_id": "m", "floor_id": "f", "x": 1, "y": 0, "z": 0}],
            "edges": []}


def test_publisher_is_discovered():
    assert publish_nav_graph in registry.publishers()


def test_puts_the_product_graph_under_its_escaped_id():
    backend = FakeBackend()
    summary = publish_nav_graph(backend, "scan/1", {}, {"nav_graph": Product(json=graph())})
    assert backend.calls == [("/graphs/scan%2F1-nav", graph())]
    assert summary["node_count"] == 2


def test_falls_back_to_the_analysis_document():
    backend = FakeBackend()
    publish_nav_graph(backend, "s", {"nav_graph": graph("s-nav")}, {})
    assert backend.calls[0][0] == "/graphs/s-nav"


@pytest.mark.parametrize("analysis", [{}, {"nav_graph": None}, {"nav_graph": []},
                                      {"nav_graph": {"nodes": []}}, {"nav_graph": {"id": " "}}])
def test_missing_or_unusable_graph_is_skipped(analysis):
    backend = FakeBackend()
    assert publish_nav_graph(backend, "s", analysis, {}) is None
    assert backend.calls == []


def test_validation_errors_are_logged_not_raised(caplog):
    backend = FakeBackend(BackendError(422, "invalid_input", "Duplicate node id: a."))
    with caplog.at_level(logging.WARNING):
        assert publish_nav_graph(backend, "s", {"nav_graph": graph("s-nav")}, {}) is None
    assert "Duplicate node id" in caplog.text


def test_other_backend_failures_propagate():
    backend = FakeBackend(BackendError(503, "graph_storage_error", "disk full"))
    with pytest.raises(BackendError):
        publish_nav_graph(backend, "s", {"nav_graph": graph("s-nav")}, {})

"""Publish the `nav_graph` product to the backend graph store so routes can be requested.

Runs after the analysis has been stored. Scans without a navigation graph are skipped silently;
graphs the backend rejects (422 validation) are logged and never fail the run, because the analysis
itself is already saved. Other backend failures propagate to the pipeline, which logs them.
"""
from __future__ import annotations

import logging
from typing import Any

from ..client import Backend, BackendError
from ..contracts import ProductName
from ..core.registry import publisher

log = logging.getLogger(__name__)


def _nav_graph(analysis: dict, products: dict) -> Any:
    product = (products or {}).get(ProductName.NAV_GRAPH)
    if product is not None and getattr(product, "json", None) is not None:
        return product.json
    return (analysis or {}).get(ProductName.NAV_GRAPH)


@publisher
def publish_nav_graph(backend: Backend, scan_id: str, analysis: dict, products: dict) -> dict | None:
    """PUT /graphs/<nav_graph.id>; returns the backend's graph summary, or None when skipped."""
    graph = _nav_graph(analysis, products)
    if not isinstance(graph, dict):
        return None
    graph_id = graph.get("id")
    if not isinstance(graph_id, str) or not graph_id.strip():
        log.warning("scan %s: nav_graph has no id; not published", scan_id)
        return None
    try:
        summary = backend.put_json(f"/graphs/{Backend.segment(graph_id)}", graph)
    except BackendError as error:
        if error.status == 422:
            log.warning("scan %s: backend rejected nav_graph %s: %s", scan_id, graph_id, error)
            return None
        raise
    log.info("scan %s: published nav_graph %s (%s nodes, %s edges)", scan_id, graph_id,
             (summary or {}).get("node_count"), (summary or {}).get("edge_count"))
    return summary

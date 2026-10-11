"""Regression cases where incomplete captures must remain incomplete navigation evidence."""
import numpy as np
import pytest

from inview_worker.contracts import ProductName
from inview_worker.core import Product, ScanContext, runner
from inview_worker.geometry import Grid
from inview_worker.guidance import NavGraph, WHEELCHAIR, find_route
from inview_worker.navgraph import attributes, export
from inview_worker.navgraph.topology import PixelGraph
from inview_worker.stages.nav_graph import NavGraphStage
from inview_worker.stages.routes import RoutesStage
from test_nav_graph import floor_map, suite


def corridor_graph(evidence):
    """A ten-metre, two-metre-wide corridor with independent surface-height evidence."""
    graph = PixelGraph()
    a, b = graph.add_node([2, 10], "endpoint"), graph.add_node([102, 10], "endpoint")
    graph.add_edge(a, b, [[2, 10], [102, 10]])
    shape = (21, 105)
    grid = Grid(0, 0, 0.1, 105, 21)
    walkable = np.full(shape, 255, np.uint8)
    attr = attributes.compute(
        graph, dt=np.full(shape, 10.0), walkable=walkable, walked=None, grid=grid,
        elevation=attributes.elevation_raster(evidence, shape), hazards=[], level=True,
        slope_baseline_m=0.5, step_rise_m=0.02, hazard_radius_m=0.3, cross_section_max_m=3.0)
    result, _, _ = export.build_graph_json(
        graph, attr, graph_id="test", map_id="m", floor_id="f", grid=grid, floor_y=0,
        walkable=walkable, epsilon_px=1, metadata={"review_status": "draft"})
    return result


@pytest.mark.parametrize("case", ["endpoint_samples", "one_missing_cell", "inpainted", "floor_planes", "no_provenance"])
def test_partial_or_unmeasured_evidence_cannot_approve_a_wheelchair_route(case):
    elevation = np.zeros((21, 105))
    evidence = {"elevation": elevation, "measured": True}
    if case == "endpoint_samples":
        elevation[:] = np.nan
        elevation[10, 2] = elevation[10, 102] = 0
    elif case == "one_missing_cell":
        elevation[:, 50] = np.nan
    elif case == "inpainted":
        evidence["measured_mask"] = np.ones(elevation.shape, bool)
        evidence["measured_mask"][:, 50] = False
    elif case == "floor_planes":
        evidence["measured"] = False
    else:
        evidence.pop("measured")
    document = corridor_graph(evidence)
    assert all(e["step_free"] is None and "maximum_slope" not in e for e in document["edges"])
    graph = NavGraph.from_json(document)
    assert find_route(graph, WHEELCHAIR, graph.nodes[0].id, graph.nodes[1].id) is None


def test_complete_evidence_routes_and_a_measured_step_still_blocks_partial_evidence():
    elevation = np.zeros((21, 105))
    document = corridor_graph({"elevation": elevation, "measured": True})
    graph = NavGraph.from_json(document)
    assert find_route(graph, WHEELCHAIR, graph.nodes[0].id, graph.nodes[1].id) is not None
    elevation[:, 51:] = 0.15
    elevation[:, 80] = np.nan
    document = corridor_graph({"elevation": elevation, "measured": True})
    assert all(e["step_free"] is False for e in document["edges"])


@pytest.mark.parametrize("kind", ["stories", "floor_ids", "barometric_hint", "separated_floor_heights"])
def test_multilevel_capture_produces_a_notice_instead_of_flattened_routes(kind):
    inputs = suite()
    fm = floor_map.build(inputs)
    ctx = ScanContext("multi", inputs, config={"nav_graph": {"floor_id": "override"}})
    ctx.products[ProductName.FLOOR_MAP] = Product(fm.result, fm)
    if kind == "barometric_hint":
        ctx.products[ProductName.GEOREF] = Product({"level_hint": {"multi_level": True}})
    else:
        records = {"stories": [{"story": 0}, {"story": 1}],
                   "floor_ids": [{"floor_id": "first"}, {"floor_id": "second"}],
                   "separated_floor_heights": [{"floor_y_m": 0}, {"floor_y_m": 3}]}[kind]
        ctx.products[ProductName.ROOMPLAN] = Product({"rooms": records})
    result = runner.run(ctx, [NavGraphStage(), RoutesStage()])
    assert "nav_graph" not in result and "routes" not in result
    assert result["summary"]["nav_graph"]["reason"] == "multiple_levels"
    assert result["stages"]["routes"]["status"] == "skipped"
    assert any("Process each floor separately" in message for message in result["notices"])

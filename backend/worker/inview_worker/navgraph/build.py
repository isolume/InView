"""Orchestrates floor map -> skeleton -> topology -> anchors -> attributes -> backend Graph v1."""
from __future__ import annotations

from dataclasses import dataclass, field

import cv2
import numpy as np

from .. import __version__
from ..contracts import FRAME, Thresholds
from . import anchors, attributes, refine, skeleton
from .config import NavGraphConfig
from .export import NavGraph, build_graph_json
from .validate import validate_graph

NOTICE = ("Navigation graph derived automatically from the walkable raster (OpenCV medial axis). Clear "
          "widths, slopes and step-free flags are screening measurements, not verified accessible routes.")
STEP_FREE_RULE = ("false if a step/stairs hazard, barrier level_change/drop_off, or measured step crosses "
                  "the edge; true only with contiguous measured elevation over the entire edge; "
                  "floor-plane estimates, inpainted cells and missing samples remain unknown.")


@dataclass
class NavGraphResult:
    graph: dict
    adjacency: NavGraph
    summary: dict
    notices: list[str] = field(default_factory=list)


def build(floor_map, *, scan_id: str, map_id: str, floor_id: str, doors: list[dict] | None = None,
          regions: list[dict] | None = None, places: list[dict] | None = None, height_map=None,
          hazards: list[dict] | None = None, level: bool | None = None,
          config: NavGraphConfig | None = None) -> NavGraphResult:
    cfg = config or NavGraphConfig()
    grid = floor_map.grid
    res = grid.resolution
    walkable = (floor_map.walkable > 0).astype(np.uint8) * 255
    dt = skeleton.clearance(walkable)
    free = skeleton.free_space(dt, cfg.clearance_radius_m / res, int(round(cfg.smooth_radius_m / res)))
    thin = skeleton.thin(free, cfg.thinning)
    graph = skeleton.to_graph(thin, dt)
    raw = {"skeleton_px": int((thin > 0).sum()), "raw_nodes": len(graph.nodes), "raw_edges": len(graph.edges)}
    stats = refine.refine(graph, dt, free, res, cfg.spur_min_m, cfg.spur_ratio, cfg.merge_junction_m,
                          cfg.min_component_m2)

    actx = anchors.AnchorContext(graph, grid, walkable, free, cfg.max_snap_m / res, cfg.max_access_m / res,
                                 cfg.door_approach_m / res)
    door_details = anchors.attach_doors(actx, doors or [])
    door_positions = [graph.nodes[d["node"]].pos for d in door_details.values()]
    region_nodes = anchors.attach_regions(actx, regions or [], door_positions)
    place_nodes = anchors.attach_places(actx, places or [])

    elevation = attributes.elevation_raster(height_map, walkable.shape) if height_map is not None else None
    geometry_elevation = attributes.elevation_raster(height_map, walkable.shape, require_measured=False)
    attrs = attributes.compute(graph, dt=dt, walkable=walkable, walked=getattr(floor_map, "walked", None), grid=grid,
                               elevation=elevation, hazards=hazards, level=level,
                               slope_baseline_m=cfg.slope_baseline_m, step_rise_m=cfg.step_rise_m,
                               hazard_radius_m=cfg.hazard_radius_m, cross_section_max_m=cfg.cross_section_max_m)

    metadata = {
        "generator": {"name": "inview_worker.navgraph", "version": __version__, "opencv": cv2.__version__,
                      "method": "distance-transform clearance, ximgproc thinning, filter2D node detection",
                      "params": cfg.describe()},
        "scan_id": scan_id,
        "map_id": map_id,
        "floor_id": floor_id,
        "review_status": "draft",
        "frame": FRAME,
        "notice": NOTICE,
        "floor_height_m": round(float(floor_map.floor_height), 3),
        "step_free_rule": STEP_FREE_RULE,
        "inputs": {"doors": len(doors or []), "regions": len(regions or []), "places": len(places or []),
                   "height_map": elevation is not None, "hazards": len(hazards or []), "single_level": level},
        "geometry_height": "surface estimate where known, floor estimate elsewhere",
        "skeleton": {**raw, **stats},
    }
    graph_json, nav, ids = build_graph_json(
        graph, attrs, graph_id=f"{scan_id}-nav", map_id=map_id, floor_id=floor_id, grid=grid,
        floor_y=floor_map.floor_height, walkable=walkable, elevation=geometry_elevation,
        epsilon_px=cfg.simplify_epsilon_m / res,
        metadata=metadata)
    graph_json["metadata"].update({
        "door_nodes": {k: ids[v["node"]] for k, v in sorted(door_details.items())},
        "doors": {k: {key: v.get(key) for key in ("connection", "clear_width_m", "meets_clear_width", "issues", "notes")
                      if v.get(key) is not None}
                  for k, v in sorted(door_details.items())},
        "region_nodes": {k: ids[v] for k, v in sorted(region_nodes.items())},
        "place_nodes": {k: ids[v] for k, v in sorted(place_nodes.items())},
        "anchors": {ids[n]: graph.nodes[n].meta for n in sorted(graph.nodes, key=lambda n: ids[n])
                    if graph.nodes[n].kind in ("region", "place")},
        "unattached": actx.unattached,
    })
    validate_graph(graph_json)

    components = graph_json["metadata"]["components"]
    node_count = len(graph_json["nodes"])
    summary = {
        "nodes": node_count,
        "edges": len(graph_json["edges"]),
        "components": len(components),
        "largest_component_fraction": round(components[0]["node_count"] / node_count, 3) if node_count else 0.0,
        "length_m": round(sum(c["length_m"] for c in components), 2),
        "doors_connected": len(door_details),
        "regions_connected": len(region_nodes),
        "places_connected": len(place_nodes),
        "unattached": len(actx.unattached),
        "step_free_edges": sum(e["step_free"] is True for e in graph_json["edges"]),
        "edges_below_route_width": sum(e["minimum_clear_width_m"] < Thresholds.ROUTE_MIN_CLEAR_M for e in graph_json["edges"]),
    }
    notices = []
    if elevation is None:
        notices.append("No measured surface elevations; step-free status and slope remain unknown.")
    if not node_count:
        notices.append("Navigation graph is empty: no walkable space wider than the body clearance.")
    elif len(components) > 1:
        notices.append(f"Navigation graph has {len(components)} disconnected parts; some areas are not "
                       "reachable from each other in the captured evidence.")
    if actx.unattached:
        notices.append(f"{len(actx.unattached)} door(s)/region(s)/place(s) could not be connected to the "
                       "navigation graph.")
    return NavGraphResult(graph_json, nav, summary, notices)

"""Evaluation harness: run the whole pipeline offline on synthetic buildings and score its products.

`run(seed, scenarios)` generates `scenarios` buildings (`synthetic.building`, seeds `seed`,
`seed + 1`, ...), decodes each package exactly as the worker would (`synthetic.offline`), runs every
registered stage (`pipeline.analyze`) and compares each product that is present with the ground truth:

| Product | Metrics |
|---|---|
| floor_map | footprint IoU, relative area error, floor height error |
| doors | recall/precision, nominal and clear width MAE, pass/fail accuracy, recall of doors below minimum |
| signs | recall, 3D localization error, precision near any true sign, category accuracy, OCR CER, read rate |
| text | line recall (CER ≤ 0.25 within 0.75 m), mean CER, localization error, position-free string recall |
| regions | matched recall/precision (IoU ≥ 0.3), mean IoU, count error, label and kind accuracy |
| places | recall/precision by compatible category within 2.5 m (or inside the true room) |
| hazards | recall/precision on stairs/ramp families, measure errors (slope, rise) |
| nav_graph | space coverage, room-adjacency F1, reachability agreement and route length ratio per profile |
| routes | routes resolved to true spaces, length ratio, wheelchair routes the truth says are impossible |
| georef | horizontal distance, heading error |

Products that are missing are listed, never scored as zero, so the harness works at every stage of the
pipeline's development. All metrics are screening diagnostics on synthetic data.
"""
from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any, Callable, Iterable

import cv2
import numpy as np

from .contracts import RESERVED_KEYS, Thresholds
from .guidance.graph import NavGraph, eligible
from .guidance.planner import extract, shortest_tree
from .guidance.profiles import DEFAULT_PROFILES
from .navgraph.validate import validate_graph
from .synthetic import building, offline

REPORT_SCHEMA_VERSION = 1
SIGN_MATCH_M = 1.0
TEXT_MATCH_M = 0.75
DOOR_MATCH_M = 0.6
PLACE_MATCH_M = 2.5
HAZARD_MATCH_M = 1.5
REGION_MIN_IOU = 0.3
TEXT_RECALL_CER = 0.25


# --- Generic metric helpers ---------------------------------------------------------------------

def mean(values: Iterable[float]) -> float | None:
    values = [float(v) for v in values if v is not None]
    return round(sum(values) / len(values), 4) if values else None


def median(values: Iterable[float]) -> float | None:
    values = [float(v) for v in values if v is not None]
    return round(float(np.median(values)), 4) if values else None


def ratio(numerator: float, denominator: float) -> float | None:
    return round(numerator / denominator, 4) if denominator else None


def levenshtein(a: str, b: str) -> int:
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def normalize_text(text: str | None) -> str:
    """Uppercase alphanumerics separated by single spaces (OCR punctuation is not scored)."""
    cleaned = "".join(c if c.isalnum() else " " for c in (text or "").upper())
    return " ".join(cleaned.split())


def cer(predicted: str | None, truth: str) -> float:
    """Character error rate of `predicted` against `truth` (capped at 1)."""
    truth_n, predicted_n = normalize_text(truth), normalize_text(predicted)
    if not truth_n:
        return 0.0 if not predicted_n else 1.0
    return min(1.0, levenshtein(predicted_n, truth_n) / len(truth_n))


def polygon_area(polygon) -> float:
    p = np.asarray(polygon, float).reshape(-1, 2)
    if len(p) < 3:
        return 0.0
    x, z = p[:, 0], p[:, 1]
    return float(abs(np.dot(x, np.roll(z, -1)) - np.dot(z, np.roll(x, -1))) / 2)


def point_in_polygon(point, polygon) -> bool:
    contour = np.asarray(polygon, np.float32).reshape(-1, 1, 2)
    return len(contour) >= 3 and cv2.pointPolygonTest(contour, (float(point[0]), float(point[1])), False) >= 0


def rasterize(polygons_a: list, polygons_b: list, resolution: float = 0.05) -> tuple[np.ndarray, np.ndarray]:
    """Two masks of polygon unions on one shared X/Z grid."""
    points = [np.asarray(p, float).reshape(-1, 2) for p in [*polygons_a, *polygons_b] if len(p) >= 3]
    if not points:
        return np.zeros((1, 1), np.uint8), np.zeros((1, 1), np.uint8)
    stacked = np.concatenate(points)
    low = stacked.min(axis=0) - 2 * resolution
    size = np.ceil((stacked.max(axis=0) - low) / resolution).astype(int) + 3
    masks = []
    for polygons in (polygons_a, polygons_b):
        mask = np.zeros((size[1], size[0]), np.uint8)
        contours = [np.round((np.asarray(p, float).reshape(-1, 2) - low) / resolution).astype(np.int32)
                    for p in polygons if len(p) >= 3]
        if contours:
            cv2.fillPoly(mask, contours, 1)
        masks.append(mask)
    return masks[0], masks[1]


def iou(polygons_a: list, polygons_b: list, resolution: float = 0.05) -> float:
    a, b = rasterize(polygons_a, polygons_b, resolution)
    union = int(np.count_nonzero(a | b))
    return round(int(np.count_nonzero(a & b)) / union, 4) if union else 0.0


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * 6_371_008.8 * math.asin(math.sqrt(min(1.0, a)))


def angle_difference_deg(a: float, b: float) -> float:
    return abs((a - b + 180) % 360 - 180)


def greedy_match(predicted: list, truth: list, max_distance: float,
                 distance: Callable[[Any, Any], float] | None = None) -> list[tuple[int, int, float]]:
    """One-to-one matches (pred index, truth index, distance), closest pairs first."""
    distance = distance or (lambda p, t: float(np.linalg.norm(np.subtract(p, t))))
    pairs = sorted((distance(p, t), i, j) for i, p in enumerate(predicted) for j, t in enumerate(truth))
    used_p, used_t, matches = set(), set(), []
    for d, i, j in pairs:
        if d > max_distance or i in used_p or j in used_t:
            continue
        used_p.add(i), used_t.add(j)
        matches.append((i, j, round(d, 4)))
    return matches


def _position(item: dict, key: str = "position_m") -> list[float] | None:
    value = item.get(key) if isinstance(item, dict) else None
    if isinstance(value, (list, tuple)) and len(value) >= 3 and all(isinstance(v, (int, float)) for v in value[:3]):
        return [float(v) for v in value[:3]]
    return None


def _xz(item: dict) -> list[float] | None:
    position = _position(item)
    if position:
        return [position[0], position[2]]
    centre = item.get("center_xz_m") or item.get("centroid_xz_m")
    return [float(centre[0]), float(centre[1])] if centre else None


def _dijkstra(adjacency: dict, source) -> dict:
    import heapq
    distance, queue = {source: 0.0}, [(0.0, source)]
    while queue:
        d, node = heapq.heappop(queue)
        if d > distance.get(node, math.inf):
            continue
        for other, length in adjacency.get(node, ()):
            if d + length < distance.get(other, math.inf):
                distance[other] = d + length
                heapq.heappush(queue, (d + length, other))
    return distance


def _space_of(xz, truth: dict, kinds: set[str] | None = None) -> str | None:
    for space in truth["spaces"]:
        if (kinds is None or space["kind"] in kinds) and point_in_polygon(xz, space["polygon_xz_m"]):
            return space["id"]
    return None


# --- Category compatibility ---------------------------------------------------------------------

_GROUPS = [{"restroom", "accessible_restroom", "toilet", "bathroom"}, {"exit", "emergency_exit"},
           {"room", "office", "destination"}, {"elevator", "lift"}, {"stairs", "staircase"}, {"ramp"}]


def category_matches(predicted: str | None, truth: str) -> bool:
    predicted = (predicted or "").lower().replace("_sign_candidate", "").replace(" ", "_")
    if predicted == truth:
        return True
    if truth == "directional" and predicted in {"exit", "emergency_exit", "directional"}:
        return True
    return any(predicted in group and truth in group for group in _GROUPS)


HAZARD_FAMILIES = {"stairs": {"stairs", "step", "steps", "level_change", "drop_off", "curb"},
                   "ramp": {"ramp", "slope", "running_slope", "steep_slope", "cross_slope"}}


# --- Product scorers ------------------------------------------------------------------------------

def score_floor_map(product: dict, truth: dict) -> dict:
    outlines = [o.get("polygon_xz_m", []) for o in product.get("outlines", [])]
    footprint = truth["floor"]["footprint_polygons_xz_m"]
    area = sum(float(o.get("area_m2") or polygon_area(o.get("polygon_xz_m", []))) for o in product.get("outlines", []))
    true_area = truth["floor"]["footprint_area_m2"]
    height = product.get("floor_height_m")
    return {
        "outline_iou": iou(outlines, footprint),
        "area_rel_error": round(abs(area - true_area) / true_area, 4) if true_area else None,
        "floor_height_error_m": round(abs(float(height) - truth["floor"]["floor_height_m"]), 4) if height is not None else None,
        "outlines": len(outlines),
        "narrow_passages": len(product.get("narrow_passages", [])),
    }


def score_doors(product: list, truth: dict) -> dict:
    gt = truth["doors"]
    by_id = {d["id"]: j for j, d in enumerate(gt)}
    matches, used = [], set()
    for i, door in enumerate(product):
        j = by_id.get(door.get("id"))
        if j is not None and j not in used:
            matches.append((i, j)), used.add(j)
    rest_p = [i for i in range(len(product)) if i not in {m[0] for m in matches}]
    rest_t = [j for j in range(len(gt)) if j not in used]
    for i, j, _ in greedy_match([_xz(product[i]) or [1e9, 1e9] for i in rest_p], [gt[j]["center_xz_m"] for j in rest_t], DOOR_MATCH_M):
        matches.append((rest_p[i], rest_t[j]))
    nominal, clear, agree, measured = [], [], [], 0
    narrow_truth, narrow_found = 0, 0
    for i, j in matches:
        p, t = product[i], gt[j]
        if p.get("nominal_width_m") is not None:
            nominal.append(abs(float(p["nominal_width_m"]) - t["nominal_width_m"]))
        governing = p.get("measured_clear_width_m")
        measured += governing is not None
        governing = governing if governing is not None else p.get("nominal_width_m")
        if governing is not None:
            clear.append(abs(float(governing) - t["clear_width_m"]))
        if "meets_clear_width" in p:
            agree.append(bool(p["meets_clear_width"]) == t["meets_clear_width"])
            if not t["meets_clear_width"]:
                narrow_truth += 1
                narrow_found += not p["meets_clear_width"]
    return {
        "recall": ratio(len(matches), len(gt)), "precision": ratio(len(matches), len(product)),
        "nominal_width_mae_m": mean(nominal), "clear_width_mae_m": mean(clear),
        "measured_fraction": ratio(measured, len(matches)),
        "pass_fail_accuracy": ratio(sum(agree), len(agree)),
        "below_min_recall": ratio(narrow_found, narrow_truth),
        "truth": len(gt), "predicted": len(product),
    }


def _best_cer(texts: list[str], truth_lines: list[str]) -> float:
    candidates = [t for t in texts if t]
    targets = [*truth_lines, " ".join(truth_lines)]
    return min((cer(c, line) for c in candidates for line in targets), default=1.0)


def score_signs(product: list, truth: dict) -> dict:
    gt = truth["signs"]
    located = [s for s in product if _position(s)]
    matches = greedy_match([_position(s) for s in located], [s["position_m"] for s in gt], SIGN_MATCH_M)
    near_any = sum(any(np.linalg.norm(np.subtract(_position(p), t["position_m"])) <= SIGN_MATCH_M for t in gt) for p in located)
    categories, cers, read = [], [], 0
    unmatched = set(range(len(located))) - {i for i, _, _ in matches}
    nearest = {k: int(np.argmin([np.linalg.norm(np.subtract(_position(located[k]), t["position_m"])) for t in gt]))
               for k in unmatched} if gt else {}
    for i, j, _ in matches:
        p, t = located[i], gt[j]
        if p.get("category"):
            categories.append(category_matches(p["category"], t["category"]))
        # The matched detection's own reading, plus unmatched detections (e.g. a text line found
        # separately from its plate) within range whose closest true sign is this one.
        nearby = [p.get("text")] + [located[k].get("text") for k in unmatched if nearest[k] == j
                                    and np.linalg.norm(np.subtract(_position(located[k]), t["position_m"])) <= SIGN_MATCH_M]
        read += any(nearby)
        cers.append(_best_cer(nearby, [line["text"] for line in t["lines"]]))
    errors = [d for _, _, d in matches]
    return {
        "recall": ratio(len(matches), len(gt)), "precision_near_any": ratio(near_any, len(located)),
        "localization_error_m": mean(errors), "localization_error_median_m": median(errors),
        "category_accuracy": ratio(sum(categories), len(categories)),
        "ocr_cer": mean(cers), "read_rate": ratio(read, len(matches)),
        "truth": len(gt), "predicted": len(product), "located": len(located),
    }


def score_text(product: list, truth: dict) -> dict:
    gt = truth["text"]
    located = [t for t in product if _position(t)]
    cers, errors, found = [], [], 0
    for line in gt:
        nearby = [(cer(t.get("text"), line["text"]), float(np.linalg.norm(np.subtract(_position(t), line["position_m"]))))
                  for t in located if np.linalg.norm(np.subtract(_position(t), line["position_m"])) <= TEXT_MATCH_M]
        best = min(nearby, default=(1.0, None))
        cers.append(best[0])
        if best[1] is not None:
            errors.append(best[1])
        found += best[0] <= TEXT_RECALL_CER
    strings = [t.get("text") for t in product]
    anywhere = sum(any(cer(s, line["text"]) <= TEXT_RECALL_CER for s in strings) for line in gt)
    correct = sum(any(cer(s, line["text"]) <= TEXT_RECALL_CER for line in gt) for s in strings)
    return {
        "line_recall": ratio(found, len(gt)), "mean_cer": mean(cers),
        "localization_error_m": mean(errors), "string_recall_anywhere": ratio(anywhere, len(gt)),
        "string_precision": ratio(correct, len(strings)), "truth": len(gt), "predicted": len(product),
        "located": len(located),
    }


def label_matches(label: str | None, aliases: list[str]) -> bool:
    words = normalize_text(label).lower()
    if not words or words == "unidentified":
        return False
    tokens = set(words.split())
    return any(a.lower() == words or a.lower() in tokens or normalize_text(a).lower() in words for a in aliases if a)


def score_regions(product: list, truth: dict) -> dict:
    regions = [r for r in product if r.get("kind") != "doorway" and len(r.get("polygon_xz_m") or []) >= 3]
    gt = truth["spaces"]
    pairs = sorted(((iou([r["polygon_xz_m"]], [s["polygon_xz_m"]], 0.1), i, j) for i, r in enumerate(regions)
                    for j, s in enumerate(gt)), reverse=True)
    used_r, used_s, matches = set(), set(), []
    for value, i, j in pairs:
        if value < REGION_MIN_IOU or i in used_r or j in used_s:
            continue
        used_r.add(i), used_s.add(j)
        matches.append((i, j, value))
    labelled = [(regions[i], gt[j]) for i, j, _ in matches if regions[i].get("label")]
    kinds = {"room": {"room"}, "corridor": {"corridor", "hallway"}, "lobby": {"room", "open_area", "lobby"}}
    return {
        "recall": ratio(len(matches), len(gt)), "precision": ratio(len(matches), len(regions)),
        "mean_iou": mean(v for _, _, v in matches), "count_error": len(regions) - len(gt),
        "label_accuracy": ratio(sum(label_matches(r["label"], s["aliases"] + [s["name"]]) for r, s in labelled), len(labelled)),
        "kind_accuracy": ratio(sum(regions[i].get("kind") in kinds[gt[j]["kind"]] for i, j, _ in matches), len(matches)),
        "truth": len(gt), "predicted": len(regions),
    }


def score_places(product: list, truth: dict) -> dict:
    gt = truth["places"]
    spaces = {s["id"]: s for s in truth["spaces"]}
    located = [p for p in product if _position(p)]

    def hit(p: dict, t: dict) -> bool:
        if not category_matches(p.get("category"), t["category"]):
            return False
        xz = [_position(p)[0], _position(p)[2]]
        if t["category"] in ("room", "restroom", "accessible_restroom") and point_in_polygon(xz, spaces[t["space"]]["polygon_xz_m"]):
            return True
        return float(np.linalg.norm(np.subtract(xz, [t["position_m"][0], t["position_m"][2]]))) <= PLACE_MATCH_M

    matched = [any(hit(p, t) for p in located) for t in gt]
    by_category: dict[str, list[bool]] = {}
    for t, m in zip(gt, matched):
        by_category.setdefault(t["category"], []).append(m)
    named = [t for t in gt if t.get("number") and t["category"] == "room"]
    named_hits = sum(any(hit(p, t) and t["number"] in normalize_text(p.get("name")) for p in located) for t in named)
    result = {"recall": ratio(sum(matched), len(gt)),
              "precision": ratio(sum(any(hit(p, t) for t in gt) for p in located), len(located)),
              "room_number_recall": ratio(named_hits, len(named)), "truth": len(gt), "predicted": len(product)}
    result.update({f"recall_{c}": ratio(sum(v), len(v)) for c, v in sorted(by_category.items())})
    return result


_SLOPE_KEYS = ("slope", "running_slope", "max_slope", "maximum_slope")
_RISE_KEYS = ("rise_m", "total_rise_m", "level_change_m", "height_change_m")
_RISER_KEYS = ("riser_height_m", "step_height_m", "riser_m")


def _first(measure: dict, keys: tuple[str, ...]) -> float | None:
    return next((float(measure[k]) for k in keys if isinstance(measure.get(k), (int, float))), None)


def score_hazards(product: list, truth: dict) -> dict:
    gt = truth["hazards"]
    scored = [h for h in product if any(h.get("kind") in kinds for kinds in HAZARD_FAMILIES.values()) and _xz(h)]

    def hit(p: dict, t: dict) -> bool:
        if p.get("kind") not in HAZARD_FAMILIES[t["kind"]]:
            return False
        xz = _xz(p)
        near = float(np.linalg.norm(np.subtract(xz, [t["position_m"][0], t["position_m"][2]]))) <= HAZARD_MATCH_M
        return near or point_in_polygon(xz, t["polygon_xz_m"])

    matched = [[p for p in scored if hit(p, t)] for t in gt]
    slope_err, rise_err = [], []
    for t, found in zip(gt, matched):
        for p in found[:1]:
            m = p.get("measure") or {}
            if t["kind"] == "ramp" and _first(m, _SLOPE_KEYS) is not None:
                slope_err.append(abs(_first(m, _SLOPE_KEYS) - t["measure"]["slope"]))
            if t["kind"] == "stairs":
                if _first(m, _RISE_KEYS) is not None:
                    rise_err.append(abs(_first(m, _RISE_KEYS) - t["measure"]["rise_m"]))
                elif _first(m, _RISER_KEYS) is not None:
                    rise_err.append(abs(_first(m, _RISER_KEYS) - t["measure"]["riser_height_m"]))
    return {
        "recall": ratio(sum(bool(m) for m in matched), len(gt)),
        "precision": ratio(sum(any(hit(p, t) for t in gt) for p in scored), len(scored)),
        "recall_stairs": ratio(sum(bool(m) for t, m in zip(gt, matched) if t["kind"] == "stairs"), sum(t["kind"] == "stairs" for t in gt)),
        "recall_ramp": ratio(sum(bool(m) for t, m in zip(gt, matched) if t["kind"] == "ramp"), sum(t["kind"] == "ramp" for t in gt)),
        "ramp_slope_error": mean(slope_err), "stairs_rise_error_m": mean(rise_err),
        "unscored": len(product) - len(scored), "truth": len(gt), "predicted": len(product),
    }


ROUTING_PROFILES = {p.name: p for p in DEFAULT_PROFILES}


def _graph(product: dict, profile: str) -> tuple[dict, dict]:
    validate_graph(product)
    graph = NavGraph.from_json(product)
    nodes = {n.id: np.asarray(n.position) for n in graph.nodes}
    adjacency: dict[str, list[tuple[str, float]]] = {}
    for edge in graph.edges:
        if eligible(edge, ROUTING_PROFILES[profile].requirements):
            a, b = graph.nodes[edge.source].id, graph.nodes[edge.target].id
            adjacency.setdefault(a, []).append((b, edge.length_m))
    return nodes, adjacency


def _truth_route(truth: dict, a: str, b: str, profile: str) -> dict | None:
    return next((r for r in truth["routes"] if r["profile"] == profile and {r["from_space"], r["to_space"]} == {a, b}), None)


def score_nav_graph(product: dict, truth: dict) -> dict:
    nodes, adjacency = _graph(product, "ambulatory")
    space_of = {n: _space_of(p[[0, 2]], truth) for n, p in nodes.items()}
    spaces = {s["id"]: s for s in truth["spaces"]}
    representative = {}
    for sid, space in spaces.items():
        inside = [n for n, s in space_of.items() if s == sid]
        if inside:
            centre = np.asarray(space["center_m"])[[0, 2]]
            representative[sid] = min(inside, key=lambda n: (float(np.linalg.norm(nodes[n][[0, 2]] - centre)), n))
    # Space adjacency: graph edges between spaces, contracting nodes that lie outside every space.
    found = set()
    for start in nodes:
        if space_of[start] is None:
            continue
        stack, seen = [start], {start}
        while stack:
            node = stack.pop()
            for other, _ in adjacency.get(node, ()):
                if other in seen:
                    continue
                seen.add(other)
                if space_of[other] is None:
                    stack.append(other)
                elif space_of[other] != space_of[start]:
                    found.add(tuple(sorted((space_of[start], space_of[other]))))
    expected = {tuple(p) for p in truth["graph"]["room_adjacency"]}
    tp = len(found & expected)
    precision, recall = ratio(tp, len(found)), ratio(tp, len(expected))
    result = {
        "nodes": len(nodes), "edges": len(product.get("edges", [])),
        "space_coverage": ratio(len(representative), len(spaces)),
        "adjacency_precision": precision, "adjacency_recall": recall,
        "adjacency_f1": round(2 * precision * recall / (precision + recall), 4) if precision and recall else 0.0,
    }
    targets = sorted(s for s in representative if spaces[s]["kind"] != "corridor")
    graph = NavGraph.from_json(product)
    for profile in ("ambulatory", "wheelchair"):
        agree, total, ratios = 0, 0, []
        for a in targets:
            tree = shortest_tree(graph, ROUTING_PROFILES[profile], graph.index[representative[a]])
            for b in targets:
                if a == b:
                    continue
                route = _truth_route(truth, a, b, profile)
                if route is None:
                    continue
                path = extract(graph, tree, graph.index[representative[b]])
                reachable = path is not None
                total += 1
                agree += reachable == route["reachable"]
                if reachable and route["reachable"] and route["length_m"]:
                    ratios.append(path.length_m / route["length_m"])
        result[f"{profile}_reachability_agreement"] = ratio(agree, total)
        result[f"{profile}_route_length_ratio"] = median(ratios)
    return result


def score_routes(product: dict, truth: dict, places: list | None, nav_graph: dict | None) -> dict:
    routes = product.get("routes", []) if isinstance(product, dict) else list(product or [])
    place_xz = {p.get("id"): [_position(p)[0], _position(p)[2]] for p in (places or []) if _position(p)}
    node_xz = {n["id"]: [n.get("x", 0.0), n.get("z", 0.0)] for n in (nav_graph or {}).get("nodes", []) if "id" in n}
    resolved, ratios, impossible, unreachable_truth = 0, [], 0, 0
    for route in routes:
        ids = route.get("node_ids") or []
        start = place_xz.get(route.get("from_place")) or (node_xz.get(ids[0]) if ids else None)
        end = place_xz.get(route.get("to_place")) or (node_xz.get(ids[-1]) if ids else None)
        a = _space_of(start, truth) if start else None
        b = _space_of(end, truth) if end else None
        if not a or not b or a == b:
            continue
        gt = _truth_route(truth, a, b, route.get("profile") or "ambulatory")
        if gt is None:
            continue
        resolved += 1
        if not gt["reachable"]:
            unreachable_truth += 1
            impossible += route.get("profile") == "wheelchair"
        elif route.get("length_m"):
            ratios.append(float(route["length_m"]) / gt["length_m"])
    return {"routes": len(routes), "resolved": resolved, "length_ratio_median": median(ratios),
            "length_ratio_mean_abs_error": mean(abs(r - 1) for r in ratios),
            "routes_truth_unreachable": unreachable_truth, "wheelchair_impossible_routes": impossible}


def score_georef(product: dict, truth: dict) -> dict:
    gt = truth["georef"]
    result = {}
    if isinstance(product.get("latitude"), (int, float)) and isinstance(product.get("longitude"), (int, float)):
        result["distance_m"] = round(haversine_m(product["latitude"], product["longitude"], gt["latitude"], gt["longitude"]), 3)
    if isinstance(product.get("heading_degrees"), (int, float)):
        result["heading_error_deg"] = round(angle_difference_deg(product["heading_degrees"], gt["heading_degrees"]), 3)
    return result


SCORERS: dict[str, Callable[[Any, dict], dict]] = {
    "floor_map": score_floor_map, "doors": score_doors, "signs": score_signs, "text": score_text,
    "regions": score_regions, "places": score_places, "hazards": score_hazards, "nav_graph": score_nav_graph,
    "georef": score_georef,
}


def score(analysis: dict, truth: dict) -> dict:
    """Metrics for every scorable product in `analysis`; scorer failures are reported, not raised."""
    products, errors = {}, {}
    for name, scorer in SCORERS.items():
        if analysis.get(name) is None:
            continue
        try:
            products[name] = scorer(analysis[name], truth)
        except Exception as error:  # noqa: BLE001 - an unexpected product shape must not hide the others
            errors[name] = f"{type(error).__name__}: {error}"
    if analysis.get("routes") is not None:
        try:
            products["routes"] = score_routes(analysis["routes"], truth, analysis.get("places"), analysis.get("nav_graph"))
        except Exception as error:  # noqa: BLE001
            errors["routes"] = f"{type(error).__name__}: {error}"
    present = {k for k in analysis if k not in RESERVED_KEYS}
    return {"products": products, "errors": errors,
            "missing": sorted((set(SCORERS) | {"routes"}) - present),
            "unscored": sorted(present - set(SCORERS) - {"routes"})}


# --- Runs and reports -----------------------------------------------------------------------------

def evaluate_scenario(seed: int, max_observations: int = 32, keep: str | Path | None = None) -> dict:
    archive, truth = building.build(seed, max_observations)
    ctx = offline.context_from_archive(archive)
    from .pipeline import analyze  # deferred: importing the pipeline pulls in the HTTP client
    analysis = analyze(ctx)
    if keep:
        directory = Path(keep)
        directory.mkdir(parents=True, exist_ok=True)
        (directory / f"{truth['scan_id']}.inviewscan.tar").write_bytes(archive)
        (directory / f"{truth['scan_id']}.truth.json").write_text(json.dumps(truth, indent=2))
        (directory / f"{truth['scan_id']}.analysis.json").write_text(json.dumps(analysis, indent=2))
    return {"seed": seed, "scan_id": truth["scan_id"],
            "stages": {name: s.get("status") for name, s in sorted(analysis.get("stages", {}).items())},
            **score(analysis, truth)}


def aggregate(scenarios: list[dict]) -> dict:
    """Mean of every numeric metric over the scenarios where it was measured."""
    values: dict[str, dict[str, list[float]]] = {}
    for scenario in scenarios:
        for product, metrics in scenario["products"].items():
            for key, value in metrics.items():
                if isinstance(value, (int, float)) and not isinstance(value, bool):
                    values.setdefault(product, {}).setdefault(key, []).append(float(value))
    return {product: {key: mean(v) for key, v in sorted(metrics.items())} for product, metrics in sorted(values.items())}


def run(seed: int = 0, scenarios: int = 3, max_observations: int = 32, keep: str | Path | None = None) -> dict:
    results = [evaluate_scenario(seed + i, max_observations, keep) for i in range(scenarios)]
    return {"schema_version": REPORT_SCHEMA_VERSION, "generator": building.GENERATOR, "seed": seed,
            "scenarios": results, "aggregate": aggregate(results),
            "notice": "Synthetic-data screening diagnostics; not a certification of accessibility."}


def table(report: dict) -> str:
    """Human-readable metric table: one row per product metric, one column per scenario."""
    scenarios = report["scenarios"]
    rows = sorted({(p, k) for s in scenarios for p, m in s["products"].items() for k in m})
    header = ["metric"] + [f"seed {s['seed']}" for s in scenarios] + ["mean"]

    def cell(value) -> str:
        if value is None:
            return "-"
        if isinstance(value, bool):
            return str(value).lower()
        if isinstance(value, float):
            return f"{value:.3f}"
        return str(value)

    lines = [[f"{p}.{k}"] + [cell(s["products"].get(p, {}).get(k)) for s in scenarios]
             + [cell(report["aggregate"].get(p, {}).get(k))] for p, k in rows]
    widths = [max(len(r[i]) for r in [header] + lines) for i in range(len(header))]
    out = ["  ".join(h.ljust(w) for h, w in zip(header, widths)), "  ".join("-" * w for w in widths)]
    out += ["  ".join(c.ljust(w) for c, w in zip(row, widths)) for row in lines]
    for s in scenarios:
        stages = ", ".join(f"{k}={v}" for k, v in s["stages"].items())
        out.append(f"seed {s['seed']} ({s['scan_id']}): stages {stages}")
        if s["missing"]:
            out.append(f"  missing products: {', '.join(s['missing'])}")
        for name, error in s["errors"].items():
            out.append(f"  scorer error {name}: {error}")
    return "\n".join(out)

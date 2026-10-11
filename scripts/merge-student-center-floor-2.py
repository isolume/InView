#!/usr/bin/env python3
"""Reproduce the registered Floor 2 scan candidate without changing app resources.

Run with the bundled Python (Pillow is needed only for PNG review plans). The first
run accepts --import-downloads to archive the four user files and baseline exactly.
Raw observations establish registration and remain evidence, never routing geometry.
The default preserves the original measured floor coverage; new floor outlines are
archived separately because the scan does not establish support over their full area.
"""
from __future__ import annotations

import argparse
from collections import Counter
import copy
import hashlib
import json
import math
from pathlib import Path
import plistlib
import shutil

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "models/walkthrough-building/floor-2-evidence"
CAPTURE_ID = "E3CF408C-680C-4ECF-B9EB-F09117308BD3"
ORIGINALS = EVIDENCE / CAPTURE_ID
BASELINE = EVIDENCE / "original-floor-2.json"
SOURCE_NAMES = ("capture.json", "raw-snapshot.json", "roomplan.json",
                "F6CE8D2C-6101-4B12-A7AA-9AC6F1BF584F.plist")
WALL_THICKNESS_M = 0.15
OVERHEAD_CLEARANCE_M = 0.7
SAME_LINE_DISTANCE_M = 0.15
SAME_LINE_ANGLE_DEGREES = 1.0
SAME_ENDPOINT_SLACK_M = 0.15
# The shared elbow is independently observed by both walls, so each occurrence
# carries half weight; each distinct free endpoint carries weight one.
FIT = (("16629B4E-9437-40C7-8494-575BAF475E46", 3, False, (1, 0.5)),
       ("892983CB-F859-4BF1-A78D-D2EF6D13B4AF", 36, True, (0.5, 1)))
HELD_OUT = (("2B270E3F-2523-417A-A9D6-71142C67DAE0", 8),
            ("4EB2CCB7-107B-4360-A28C-7EE560F19F9F", 6))


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def add(a, b): return [a[0] + b[0], a[1] + b[1]]
def sub(a, b): return [a[0] - b[0], a[1] - b[1]]
def mul(a, s): return [a[0] * s, a[1] * s]
def dot(a, b): return a[0] * b[0] + a[1] * b[1]
def cross(a, b): return a[0] * b[1] - a[1] * b[0]
def norm(a): return math.hypot(*a)

def rotate(p, angle):
    c, s = math.cos(angle), math.sin(angle)
    return [c * p[0] - s * p[1], s * p[0] + c * p[1]]


def endpoints(footprint):
    along = mul([math.cos(footprint["yaw"]), math.sin(footprint["yaw"])], footprint["size"][0] / 2)
    return [sub(footprint["center"], along), add(footprint["center"], along)]


def outline(footprint):
    if len(footprint.get("polygon", [])) >= 3:
        return footprint["polygon"]
    x, z = [v / 2 for v in footprint["size"]]
    return [add(footprint["center"], rotate(v, footprint["yaw"]))
            for v in ([x, z], [-x, z], [-x, -z], [x, -z])]


def area(polygon):
    return abs(sum(cross(a, b) for a, b in zip(polygon, polygon[1:] + polygon[:1]))) / 2


def estimate_registration(baseline, raw, native_floor_y):
    observations = {p.get("id"): p for p in raw["observedFootprints"] if p.get("id")}
    source, target, weights, features = [], [], [], []
    for source_id, target_index, reverse, pair_weights in FIT:
        p, q = observations[source_id], baseline["footprints"][target_index]
        a, b = endpoints(p), endpoints(q)
        if reverse: b.reverse()
        source.extend(a); target.extend(b); weights.extend(pair_weights)
        features.append({"source_id": source_id, "existing_footprint_index": target_index,
                         "source_length_m": p["size"][0], "existing_length_m": q["size"][0]})
    total = sum(weights)
    source_mean = [sum(p[i] * w for p, w in zip(source, weights)) / total for i in range(2)]
    target_mean = [sum(p[i] * w for p, w in zip(target, weights)) / total for i in range(2)]
    pairs = [(sub(a, source_mean), sub(b, target_mean), w) for a, b, w in zip(source, target, weights)]
    angle = math.atan2(sum(w * cross(a, b) for a, b, w in pairs),
                       sum(w * dot(a, b) for a, b, w in pairs))
    translation = sub(target_mean, rotate(source_mean, angle))
    transform = lambda p: add(rotate(p, angle), translation)
    residuals = [norm(sub(transform(a), b)) for a, b in zip(source, target)]
    checks = []
    for source_id, target_index in HELD_OUT:
        p, q = observations[source_id], baseline["footprints"][target_index]
        a, b = [transform(x) for x in endpoints(p)], endpoints(q)
        target_axis = mul(sub(b[1], b[0]), 1 / norm(sub(b[1], b[0])))
        source_axis = sub(a[1], a[0])
        difference = math.atan2(cross(target_axis, source_axis), dot(target_axis, source_axis))
        difference = (difference + math.pi / 2) % math.pi - math.pi / 2
        lo, hi = sorted(dot(x, target_axis) for x in a)
        old_lo, old_hi = sorted(dot(x, target_axis) for x in b)
        checks.append({"source_id": source_id, "existing_footprint_index": target_index,
                       "normal_endpoint_residuals_m": [abs(cross(target_axis, sub(x, b[0]))) for x in a],
                       "orientation_residual_degrees": math.degrees(difference),
                       "overlap_m": max(0, min(hi, old_hi) - max(lo, old_lo)),
                       "source_length_m": p["size"][0], "existing_length_m": q["size"][0]})
    return {"schema_version": 1, "source_capture_id": CAPTURE_ID,
            "horizontal_rotation_radians": angle, "horizontal_rotation_degrees": math.degrees(angle),
            "translation_xz_m": translation, "vertical_translation_m": baseline["floorY"] - native_floor_y,
            "source_native_floor_y_m": native_floor_y, "target_floor_y_m": baseline["floorY"],
            "uniform_scale": 1, "transform_convention": "target xz = rotate(source xz, yaw) + translation; target y = source y + vertical_translation",
            "fit_method": "Weighted rigid 2D least squares; the two shared-elbow observations have total weight one",
            "endpoint_weights": weights, "endpoint_residuals_m": residuals,
            "endpoint_rms_m": math.sqrt(sum(x * x for x in residuals) / len(residuals)),
            "endpoint_max_residual_m": max(residuals), "fitted_features": features,
            "held_out_features": checks,
            "area_confirmation": "Outside main lounge; start far end of balcony opposite elevators, finish near restrooms",
            "localization_status": "Geometric registration for saved-map import; no new live AR localization is established"}


def transformed_pose_point(pose, local, registration):
    world = [sum(pose[col * 4 + row] * local[col] for col in range(3)) + pose[12 + row] for row in range(3)]
    xz = add(rotate([world[0], world[2]], registration["horizontal_rotation_radians"]), registration["translation_xz_m"])
    return [xz[0], world[1] + registration["vertical_translation_m"], xz[1]]


def project_surface(surface, registration):
    pose, size, kind = surface["map_from_surface"], surface["dimensions_m"], surface["kind"]
    if kind == "floor":
        local = surface.get("polygon_corners") or [[-size[0] / 2, -size[1] / 2, 0], [size[0] / 2, -size[1] / 2, 0],
                                                   [size[0] / 2, size[1] / 2, 0], [-size[0] / 2, size[1] / 2, 0]]
        # RoomPlan floor-local X/Y span the horizontal plane. Observed coverage uses
        # its archived pose as supplied; do not replace either with a guessed X/Z box.
        world = [transformed_pose_point(pose, point, registration) for point in local]
        polygon = [[point[0], point[2]] for point in world]
        lo = [min(p[i] for p in polygon) for i in range(2)]
        hi = [max(p[i] for p in polygon) for i in range(2)]
        return {"id": surface["id"], "kind": "floor", "center": mul(add(lo, hi), 0.5),
                "size": sub(hi, lo), "yaw": 0, "bottom": sum(p[1] for p in world) / len(world),
                "height": 0, "polygon": polygon}
    center = transformed_pose_point(pose, [0, 0, 0], registration)
    angle = math.atan2(pose[2], pose[0]) if math.hypot(pose[0], pose[2]) > 1e-4 else 0
    return {"id": surface["id"], "kind": kind, "center": [center[0], center[2]],
            "size": [size[0], WALL_THICKNESS_M], "yaw": angle + registration["horizontal_rotation_radians"],
            "bottom": center[1] - size[1] / 2, "height": size[1]}


def project_object(obj, registration):
    pose, size = obj["map_from_object"], obj["dimensions_m"]
    center = transformed_pose_point(pose, [0, 0, 0], registration)
    angle = math.atan2(pose[2], pose[0]) if math.hypot(pose[0], pose[2]) > 1e-4 else 0
    furniture = {"refrigerator": "appliance", "stove": "appliance", "oven": "appliance",
                 "dishwasher": "appliance", "washerDryer": "appliance"}.get(obj["category"], obj["category"])
    return {"id": obj["id"], "kind": "stairs" if obj["category"] == "stairs" else "obstacle",
            "center": [center[0], center[2]], "size": [size[0], size[2]],
            "yaw": angle + registration["horizontal_rotation_radians"],
            "bottom": center[1] - size[1] / 2, "height": size[1], "furniture": furniture}


def register_pose(pose, registration):
    """Premultiply a column-major pose by the rigid source-to-baseline transform."""
    result = list(pose)
    for column in range(4):
        xz = rotate([pose[column * 4], pose[column * 4 + 2]], registration["horizontal_rotation_radians"])
        result[column * 4], result[column * 4 + 2] = xz
    result[12] += registration["translation_xz_m"][0]
    result[13] += registration["vertical_translation_m"]
    result[14] += registration["translation_xz_m"][1]
    return result


def registered_capture(capture, registration, native_ids):
    result = copy.deepcopy(capture)
    result["map_id"] = "student-center-east-merged-floor-2"
    result["floor_id"] = "student-center-east-floor-2"
    for surface in result["surfaces"]:
        surface["map_from_surface"] = register_pose(surface["map_from_surface"], registration)
    for obj in result["objects"]:
        obj["map_from_object"] = register_pose(obj["map_from_object"], registration)
    # Original sensor frames remain exact in the source archive. This derived
    # structural capture has no copied frames in the old source coordinate frame.
    result["frames"] = []
    result["meshes"] = []
    result["metadata"].update({
        "coordinate_space": "registered_original_floor_2_map",
        "source_capture_id": capture["id"], "source_floor_id": capture["floor_id"],
        "source_capture_sha256": digest(ORIGINALS / "capture.json"),
        "source_sensor_frames": "exact bytes remain in original archive; omitted from registered structural copy",
        "registration": registration,
        "completed_native_surface_ids": [s["id"] for s in capture["surfaces"] if s["id"] in native_ids],
        "native_floor_display_only_ids": [s["id"] for s in capture["surfaces"] if s["kind"] == "floor" and s["id"] in native_ids],
        "evidence_only_observed_floor_ids": [s["id"] for s in capture["surfaces"] if s["kind"] == "floor" and s["id"] not in native_ids],
        "new_floor_routing_coverage": "withheld pending support review; retain original 12 measured floor regions",
        "native_floor_display_status": "measured RoomPlan outline; display only and not reviewed as complete walkable support",
    })
    return result


def overlapping_segments(new, old):
    """Return old interval on new's long axis when same-kind centerlines coincide."""
    if new["kind"] != old["kind"] or new["kind"] not in {"wall", "door", "opening", "window"}: return None
    a, b = endpoints(new), endpoints(old)
    axis = [math.cos(new["yaw"]), math.sin(new["yaw"])]
    old_axis = [math.cos(old["yaw"]), math.sin(old["yaw"])]
    angle = math.degrees(math.acos(min(1, max(0, abs(dot(axis, old_axis))))))
    if angle > SAME_LINE_ANGLE_DEGREES: return None
    distance = max(abs(cross(axis, sub(point, a[0]))) for point in b)
    if distance > SAME_LINE_DISTANCE_M: return None
    interval = sorted(dot(sub(point, a[0]), axis) for point in b)
    if interval[1] < -SAME_ENDPOINT_SLACK_M or interval[0] > new["size"][0] + SAME_ENDPOINT_SLACK_M: return None
    return interval, distance, angle


def subtract_existing(new, existing):
    intervals, matches = [], []
    for index, old in enumerate(existing):
        match = overlapping_segments(new, old)
        if match is None: continue
        interval, distance, angle = match
        intervals.append(interval)
        matches.append({"existing_footprint_index": index, "source_interval_m": interval,
                        "normal_distance_m": distance, "orientation_difference_degrees": angle})
    if not intervals: return [new], {"decision": "added", "source_id": new["id"], "kind": new["kind"]}
    # Existing structure has precedence. Small endpoint differences are measurement
    # residuals; do not turn them into a tiny extra wall or duplicate doorway.
    lo, hi = 0.0, new["size"][0]
    remaining = [(lo, hi)]
    for a, b in sorted(intervals):
        a, b = a - SAME_ENDPOINT_SLACK_M, b + SAME_ENDPOINT_SLACK_M
        replacement = []
        for start, end in remaining:
            if b <= start or a >= end: replacement.append((start, end)); continue
            if a > start: replacement.append((start, a))
            if b < end: replacement.append((b, end))
        remaining = replacement
    if not remaining:
        return [], {"decision": "deduplicated_keep_existing", "source_id": new["id"], "kind": new["kind"], "matches": matches}
    if new["kind"] != "wall":
        # An aperture is indivisible. Retain the original nearby aperture if they
        # overlap substantially; otherwise keep the measured source aperture whole.
        covered = new["size"][0] - sum(b - a for a, b in remaining)
        if covered / new["size"][0] >= 0.8:
            return [], {"decision": "deduplicated_keep_existing", "source_id": new["id"], "kind": new["kind"], "matches": matches}
        return [new], {"decision": "added_partial_overlap_aperture", "source_id": new["id"], "kind": new["kind"], "matches": matches}
    start = endpoints(new)[0]; axis = [math.cos(new["yaw"]), math.sin(new["yaw"])]
    fragments = []
    for index, (a, b) in enumerate(remaining):
        if b - a <= 0.05: continue
        piece = copy.deepcopy(new); piece["center"] = add(start, mul(axis, (a + b) / 2)); piece["size"][0] = b - a
        if len(remaining) > 1: piece.pop("id", None)  # source ID remains in manifest; avoid repeated feature IDs
        fragments.append(piece)
    return fragments, {"decision": "added_nonoverlapping_wall_parts", "source_id": new["id"], "kind": new["kind"],
                       "retained_intervals_m": remaining, "matches": matches}


def validate(candidate, baseline):
    assert candidate["points"] == baseline["points"], "Existing elevator/access points changed"
    assert candidate["floorY"] == baseline["floorY"], "Existing floor plane changed"
    assert candidate["createdAt"] == baseline["createdAt"], "Baseline date changed"
    assert candidate["footprints"][:len(baseline["footprints"])] == baseline["footprints"], "Baseline footprints changed"
    assert [p for p in candidate["footprints"] if p["kind"] == "stairs"] == [p for p in baseline["footprints"] if p["kind"] == "stairs"], "Existing stairs changed"
    assert len([p for p in candidate["footprints"] if p["kind"] == "floor"]) == len([p for p in baseline["footprints"] if p["kind"] == "floor"]), "Withheld floor outline entered routing"
    def finite(value):
        if isinstance(value, float): assert math.isfinite(value), "Nonfinite geometry"
        elif isinstance(value, dict):
            for item in value.values(): finite(item)
        elif isinstance(value, list):
            for item in value: finite(item)
    finite(candidate)
    ids = [p["id"] for p in candidate["footprints"] if p.get("id")]
    assert len(ids) == len(set(ids)), "Duplicate footprint IDs"
    for p in candidate["footprints"]:
        assert len(p["center"]) == len(p["size"]) == 2
        assert all(x > 0 for x in p["size"]), "Nonpositive footprint dimension"
        assert p.get("height", 0) >= 0
        if p["kind"] == "floor": assert len(p.get("polygon", [])) >= 3 and area(p["polygon"]) > 0
    return {"finite_geometry": True, "positive_footprint_dimensions": True,
            "baseline_footprints_unchanged": True, "points_unchanged": True,
            "stairs_unchanged": True, "floor_count_unchanged": True, "unique_feature_ids": True}


def render_plans(baseline, candidate, raw, registration):
    from PIL import Image, ImageDraw
    # Normalize only the review view to the first old long wall; exported JSON uses
    # the original map frame. Both panels use the same meter scale and bounds.
    angle = baseline["footprints"][3]["yaw"]
    view = lambda p: rotate(p, -angle)
    polygons = [outline(p) for p in candidate["footprints"]]
    points = [view(p) for polygon in polygons for p in polygon]
    lower = [min(p[i] for p in points) - 2 for i in range(2)]
    upper = [max(p[i] for p in points) + 2 for i in range(2)]
    width, height, margin = 1050, 1150, 65
    scale = min((width - 2 * margin) / (upper[0] - lower[0]), (height - 2 * margin) / (upper[1] - lower[1]))
    screen = lambda p: (margin + (view(p)[0] - lower[0]) * scale, height - margin - (view(p)[1] - lower[1]) * scale)
    images = []
    for name, current in (("before", baseline), ("after", candidate)):
        image = Image.new("RGB", (width, height), "#FAFAF8"); draw = ImageDraw.Draw(image)
        draw.text((margin, 20), "Floor 2 - prior scan" if name == "before" else "Floor 2 - registered balcony and restroom scan", fill="#202D28")
        draw.text((margin, 40), "Gray: existing measurements    Green: additional completed measurements", fill="#52605A")
        for p in current["footprints"]:
            if p["kind"] == "floor": draw.polygon([screen(q) for q in outline(p)], fill="#E7EBE5", outline="#D1DAD2")
        for index, p in enumerate(current["footprints"]):
            if p["kind"] == "floor": continue
            added = index >= len(baseline["footprints"])
            color = "#257B58" if added else {"wall": "#55635D", "door": "#C99032", "opening": "#5589AD", "stairs": "#9E7559"}.get(p["kind"], "#ADBDB2")
            pix = [screen(q) for q in outline(p)]
            if p["kind"] in {"wall", "window"}: draw.polygon(pix, fill=color)
            elif p["kind"] in {"door", "opening"}: draw.line([screen(q) for q in endpoints(p)], fill=color, width=4)
            else: draw.polygon(pix, fill=color)
        for point in current["points"]:
            x, y = screen([point["position"][0], point["position"][2]])
            draw.ellipse((x - 5, y - 5, x + 5, y + 5), fill="#3957A0")
        a = [margin, height - 30]; draw.line([tuple(a), (a[0] + scale * 5, a[1])], fill="#52605A", width=2)
        draw.text((a[0], a[1] - 15), "5 meters", fill="#52605A")
        if name == "after":
            draw.text((margin, height - 55), "Existing 12 floor regions retained; new broad floor outlines remain review evidence.", fill="#52605A")
        image.save(EVIDENCE / f"{name}-plan.png"); images.append(image)
    combined = Image.new("RGB", (width * 2, height), "white")
    for index, image in enumerate(images): combined.paste(image, (index * width, 0))
    combined.save(EVIDENCE / "before-after-plan.png")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--import-downloads", action="store_true", help="Archive the supplied Downloads files once; exact existing copies are verified")
    parser.add_argument("--no-render", action="store_true", help="Skip Pillow PNG review plans")
    args = parser.parse_args()
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    if args.import_downloads:
        ORIGINALS.mkdir(exist_ok=True)
        for name in SOURCE_NAMES:
            source, destination = Path.home() / "Downloads" / name, ORIGINALS / name
            if destination.exists(): assert digest(source) == digest(destination), f"Archived input differs: {name}"
            else: shutil.copyfile(source, destination)
        if not BASELINE.exists(): shutil.copyfile(ROOT / "InView/Resources/StudentCenter/student-center-east-floor-2.json", BASELINE)
    assert BASELINE.exists() and all((ORIGINALS / name).exists() for name in SOURCE_NAMES), "Import originals first with --import-downloads"
    baseline = json.loads(BASELINE.read_text()); capture = json.loads((ORIGINALS / "capture.json").read_text())
    raw = json.loads((ORIGINALS / "raw-snapshot.json").read_text())
    native = plistlib.loads((ORIGINALS / SOURCE_NAMES[-1]).read_bytes())
    assert capture["id"] == CAPTURE_ID and capture["metadata"]["floor_level"] == 2
    native_ids = {item["identifier"] for group in ("walls", "doors", "windows", "openings", "floors", "objects") for item in native[group]}
    native_floor_ids = {item["identifier"] for item in native["floors"]}
    floor_ys = sorted(item["map_from_surface"][13] for item in capture["surfaces"] if item["id"] in native_floor_ids)
    assert floor_ys, "The native floor plane is required for vertical registration"
    registration = estimate_registration(baseline, raw, floor_ys[len(floor_ys) // 2])
    save(EVIDENCE / "registration.json", registration)
    merged = copy.deepcopy(baseline); decisions, projections, withheld_floors = [], [], []
    for surface in capture["surfaces"]:
        projected = project_surface(surface, registration)
        is_native = surface["id"] in native_ids
        projections.append({"source_id": surface["id"], "native_completed_roomplan": is_native, "footprint": projected})
        if surface["kind"] == "floor":
            entry = {"source_id": surface["id"], "native_completed_roomplan": is_native,
                     "projected_area_m2": area(projected["polygon"]), "footprint": projected,
                     "decision": "withheld_from_routing", "reason": "Broad inferred coverage does not establish support over the complete polygon; retain original measured floors"}
            withheld_floors.append(entry); decisions.append({k: v for k, v in entry.items() if k != "footprint"}); continue
        if not is_native:
            decisions.append({"source_id": surface["id"], "kind": surface["kind"], "decision": "evidence_only_not_completed_native_structure"}); continue
        additions, decision = subtract_existing(projected, baseline["footprints"])
        merged["footprints"].extend(additions); decisions.append(decision)
    object_projections = []
    for obj in capture["objects"]:
        projected = project_object(obj, registration)
        object_projections.append({"source_id": obj["id"], "footprint": projected})
        if obj["id"] not in native_ids:
            decisions.append({"source_id": obj["id"], "kind": obj["category"], "decision": "evidence_only_not_completed_native_object"})
        elif projected["bottom"] >= baseline["floorY"] + OVERHEAD_CLEARANCE_M:
            decisions.append({"source_id": obj["id"], "kind": obj["category"], "decision": "excluded_above_overhead_clearance",
                              "bottom_above_floor_m": projected["bottom"] - baseline["floorY"], "threshold_m": OVERHEAD_CLEARANCE_M})
        else:
            merged["footprints"].append(projected)
            decisions.append({"source_id": obj["id"], "kind": obj["category"], "decision": "added_completed_native_floor_obstacle"})
    validation = validate(merged, baseline)
    save(EVIDENCE / "merged-floor-2.json", merged)
    save(EVIDENCE / "registered-projection.json", {"registration": registration, "surfaces": projections, "objects": object_projections, "withheld_floors": withheld_floors})
    save(EVIDENCE / "canonical-capture.json", registered_capture(capture, registration, native_ids))
    inputs = [{"path": str(p.relative_to(EVIDENCE)), "sha256": digest(p), "bytes": p.stat().st_size}
              for p in [BASELINE, *(ORIGINALS / name for name in SOURCE_NAMES)]]
    manifest = {"schema_version": 1, "source_capture_id": CAPTURE_ID, "input_files": inputs, "registration": registration,
                "policy": {"keep_original_measured_floors": True, "raw_observed_walls_objects_and_walk_trace": "registration_and_review_evidence_only",
                           "native_new_floor_polygons": "archived_but_withheld_from_routing", "wall_thickness_m": WALL_THICKNESS_M,
                           "overhead_clearance_m": OVERHEAD_CLEARANCE_M, "deduplicate_same_kind": True,
                           "deduplicate_normal_distance_m": SAME_LINE_DISTANCE_M, "deduplicate_orientation_degrees": SAME_LINE_ANGLE_DEGREES,
                           "deduplicate_endpoint_slack_m": SAME_ENDPOINT_SLACK_M},
                "baseline_counts": dict(Counter(p["kind"] for p in baseline["footprints"])),
                "merged_counts": dict(Counter(p["kind"] for p in merged["footprints"])),
                "added_footprints": len(merged["footprints"]) - len(baseline["footprints"]),
                "withheld_floor_regions": len(withheld_floors), "decisions": decisions, "validation": validation,
                "output_files": [{"path": name, "sha256": digest(EVIDENCE / name)}
                                 for name in ("merged-floor-2.json", "registered-projection.json", "registration.json", "canonical-capture.json")]}
    save(EVIDENCE / "manifest.json", manifest)
    if not args.no_render: render_plans(baseline, merged, raw, registration)
    print(json.dumps({"output": str(EVIDENCE), "rotation_degrees": registration["horizontal_rotation_degrees"],
                      "endpoint_rms_m": registration["endpoint_rms_m"], "added_footprints": manifest["added_footprints"],
                      "counts": manifest["merged_counts"], "withheld_floor_regions": len(withheld_floors), "validation": validation}))


if __name__ == "__main__": main()

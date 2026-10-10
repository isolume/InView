"""Keyframes -> per-frame sign observations -> 3D-deduplicated, assessed `signs` product."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable

import numpy as np

from ..inputs import Frame
from . import assess as assess_mod
from . import i18n
from .placement import LocalFrame, height_range, local_frame, locate, map_direction
from .plates import Detection, detect, overlap_fraction
from .arrows import name_for as arrow_name
from .reader import Reading, read

MERGE_DISTANCE_M = 0.6
TEXT_LINK_OVERLAP = 0.5
LEGACY_KIND = {"red": "exit_sign_candidate", "green": "exit_sign_candidate", "blue": "accessibility_sign_candidate"}


@dataclass
class Observation:
    frame_id: str
    color_asset: str
    image_size: tuple[int, int]
    detection: Detection
    reading: Reading | None
    position: list[float] | None
    local: LocalFrame | None
    texts: list[dict] = field(default_factory=list)      # linked upstream text observations
    camera: np.ndarray | None = None

    @property
    def is_plate(self) -> bool:
        return self.detection.kind != "text_region"


def _hex(bgr) -> str | None:
    return None if bgr is None else "#{:02x}{:02x}{:02x}".format(int(bgr[2]), int(bgr[1]), int(bgr[0]))


def _observe(frame: Frame, image: np.ndarray, texts_by_frame: dict[str, list[dict]], cameras: dict, ocr: bool):
    height, width = image.shape[:2]
    for detection in detect(image, ocr=ocr):
        reading = read(image, detection) if detection.kind != "text_region" else None
        linked = [t for t in texts_by_frame.get(frame.id, [])
                  if len(t.get("bbox_px") or []) == 4 and overlap_fraction(t["bbox_px"], detection.bbox) >= TEXT_LINK_OVERLAP]
        # Neutral plates must carry something readable, otherwise they are just rectangles.
        if detection.kind == "sign_candidate" and not (reading and reading.has_content) and not linked:
            continue
        yield Observation(frame.id, frame.color_asset, (width, height), detection, reading,
                          locate(detection.bbox, frame, width, height),
                          local_frame(detection.bbox, frame, width, height), linked, cameras.get(frame.id))


def _measure(obs: Observation, floor_height: float | None) -> dict:
    """Per-observation geometry: arrows in the map frame, heights, character size, distance."""
    reading, local, (x, y, w, h) = obs.reading, obs.local, obs.detection.bbox
    record: dict = {"frame_id": obs.frame_id, "color_asset": obs.color_asset,
                    "bbox_xywh_px": list(map(int, obs.detection.bbox)), "image_size_px": list(obs.image_size),
                    "score": obs.detection.score}
    arrows = []
    for arrow in (reading.arrows if reading else []):
        direction_xz, meaning = map_direction(local, arrow["direction_px"]) if local else (None, "unknown")
        arrows.append({**arrow, "direction_xz": direction_xz, "meaning": meaning})
    record["arrows"] = arrows
    if local is not None:
        record["normal_m"] = [round(float(c), 3) for c in local.normal]
        record["plane_residual_m"] = round(local.residual_m, 4)
    if obs.camera is not None and obs.position is not None:
        record["distance_m"] = round(float(np.linalg.norm(np.subtract(obs.position, obs.camera))), 3)
    if floor_height is not None and local is not None:
        bottom, top = height_range(local, obs.detection.bbox)
        heights = {"top": top, "bottom": bottom}
        lines = reading.text_lines if reading else []
        if lines:
            # A line's baseline is its lowest world point (character bottoms), whatever the camera roll.
            baselines = [height_range(local, line["bbox_px"])[0] for line in lines]
            heights["text_baseline_low"], heights["text_baseline_high"] = min(baselines), max(baselines)
        record["heights_m"] = {k: round(v - floor_height, 3) for k, v in heights.items()}
    if obs.position is not None and floor_height is not None:
        record["mounting_height_m"] = round(obs.position[1] - floor_height, 3)
    if local is not None and reading and reading.text_lines:
        px = max(line["char_height_px"] for line in reading.text_lines)
        record["char_height_m"] = round(px * local.meters_per_px_vertical(), 4)
    return record


def _merge_key(obs: Observation) -> tuple[str, str]:
    return ("plate" if obs.is_plate else "text"), _category(obs)[0]


def _pictogram_names(obs: Observation) -> list[str]:
    if not obs.reading:
        return []
    return assess_mod.resolve_pictograms([p["name"] for p in obs.reading.pictograms],
                                         [a["image_direction"] for a in obs.reading.arrows])


def _texts(obs: Observation) -> list[str]:
    out = [t.get("text", "") for t in obs.texts if t.get("text")]
    if obs.detection.text:
        out.append(obs.detection.text)
    return out


def _category(obs: Observation):
    text_categories = [c for text in _texts(obs) for _, c, _ in i18n.lexicon_hits(text)]
    arrows = [a["image_direction"] for a in obs.reading.arrows] if obs.reading else []
    has_text = bool(_texts(obs) or (obs.reading and obs.reading.text_lines) or not obs.is_plate)
    return assess_mod.infer_category(_pictogram_names(obs), arrows, obs.detection.color if obs.is_plate else None,
                                     text_categories, has_text)


def _cluster(observations: list[Observation]) -> list[list[Observation]]:
    clusters: list[list[Observation]] = []
    order = sorted(observations, key=lambda o: (-o.detection.score, o.frame_id, o.detection.bbox))
    for obs in order:
        key = _merge_key(obs)
        twin = None
        if obs.position is not None:
            for cluster in clusters:
                head = cluster[0]
                if head.position is None or _merge_key(head)[0] != key[0]:
                    continue
                distance = float(np.linalg.norm(np.subtract(head.position, obs.position)))
                same_category = _merge_key(head)[1] == key[1]
                if distance < MERGE_DISTANCE_M and (same_category or distance < MERGE_DISTANCE_M / 2):
                    twin = cluster
                    break
        if twin is None:
            clusters.append([obs])
        else:
            twin.append(obs)
    return clusters


def _median(values):
    values = [v for v in values if v is not None]
    return round(float(np.median(values)), 3) if values else None


def _arrow_key(arrow: dict) -> str:
    """Group arrows by their map-frame meaning when known (camera roll changes the image name)."""
    if arrow.get("meaning") not in (None, "unknown"):
        return f"map:{arrow['meaning']}"
    return f"image:{arrow['image_direction']}"


def _merge_arrows(records: list[dict]) -> list[dict]:
    groups: dict[str, list[dict]] = {}
    for record in records:
        for arrow in record["arrows"]:
            groups.setdefault(_arrow_key(arrow), []).append(arrow)
    merged = []
    for _, arrows in sorted(groups.items()):
        vectors = [a["direction_xz"] for a in arrows if a["direction_xz"]]
        direction = None
        if vectors:
            mean = np.mean(vectors, axis=0)
            n = np.linalg.norm(mean)
            direction = [round(float(c), 3) for c in mean / n] if n > 1e-9 else None
        # Circular mean of the image angles (a plain median breaks across 0/360 degrees).
        radians = np.radians([a["angle_deg"] for a in arrows])
        angle = float(np.degrees(np.arctan2(np.sin(radians).mean(), np.cos(radians).mean())) % 360)
        meanings = [a["meaning"] for a in arrows if a.get("meaning") not in (None, "unknown")]
        merged.append({"direction_xz": direction, "image_direction": arrow_name(angle),
                       "meaning": max(sorted(set(meanings)), key=meanings.count) if meanings else "unknown",
                       "angle_deg": round(angle, 1), "score": _median([a["score"] for a in arrows])})
    return merged


def _sign(cluster: list[Observation], floor_height: float | None) -> dict:
    head = cluster[0]
    records = [_measure(o, floor_height) for o in cluster]
    readings = [o.reading for o in cluster if o.reading]
    pictos = sorted({p for o in cluster for p in _pictogram_names(o)})
    arrows = _merge_arrows(records)
    texts = [t for o in cluster for t in o.texts]
    text_ids = sorted({t["id"] for t in texts if t.get("id")})
    all_texts = [t for o in cluster for t in _texts(o)]
    text_categories = [c for text in all_texts for _, c, _ in i18n.lexicon_hits(text)]
    text_lines = [line for r in readings for line in r.text_lines]
    colors = [o.detection.color for o in cluster if o.detection.color]
    color = max(sorted(set(colors)), key=colors.count) if colors else None
    category, confidence, evidence = assess_mod.infer_category(
        pictos, [a["image_direction"] for a in arrows], color if head.is_plate else None, text_categories,
        bool(all_texts or text_lines or not head.is_plate))
    languages = sorted({lang for t in texts for lang in i18n.languages(t.get("text", ""), t.get("language"))}
                       | {lang for o in cluster if o.detection.text for lang in i18n.languages(o.detection.text)})
    scripts = sorted({s for t in texts for s in ([t["script"]] if t.get("script") else i18n.scripts(t.get("text", "")))}
                     | {s for text in all_texts for s in i18n.scripts(text)})
    positions = [o.position for o in cluster if o.position is not None]
    position = [round(float(c), 3) for c in np.median(positions, axis=0)] if positions else None
    normals = [r["normal_m"] for r in records if "normal_m" in r]
    normal = None
    if normals:
        mean = np.mean(normals, axis=0)
        normal = [round(float(c), 3) for c in mean / max(np.linalg.norm(mean), 1e-9)]
    heights = {}
    for key in ("top", "bottom", "text_baseline_low", "text_baseline_high"):
        value = _median([r.get("heights_m", {}).get(key) for r in records])
        if value is not None:
            heights[key] = value
    braille = [r.braille for r in readings if r.braille]
    text = max(all_texts, key=len) if all_texts else None
    if len({t.get("text") for t in texts if t.get("text")}) > 1:
        ordered = sorted(texts, key=lambda t: (t["bbox_px"][1], t["bbox_px"][0]))
        text = " / ".join(dict.fromkeys(t["text"] for t in ordered if t.get("text")))
    sign = {
        "kind": _legacy_kind(head, category, pictos, color),
        "category": category,
        "category_confidence": confidence,
        "evidence": evidence,
        "color": color,
        "text": text,
        "score": max(o.detection.score for o in cluster),
        "pictograms": pictos,
        "text_ids": text_ids,
        "text_lines": [{"char_height_px": round(line["char_height_px"], 1), "characters": line["characters"]}
                       for line in text_lines],
        "arrows": arrows,
        "braille": bool(braille),
        "braille_detail": max(braille, key=lambda b: b["dots"]) if braille else None,
        "contrast_ratio": _median([r.contrast_ratio for r in readings]),
        "legend_color": _hex(readings[0].legend_bgr) if readings else None,
        "background_color": _hex(readings[0].background_bgr) if readings else None,
        "mounting_height_m": _median([r.get("mounting_height_m") for r in records]),
        "heights_m": heights,
        "char_height_m": _median([r.get("char_height_m") for r in records]),
        "viewing_distance_m": _median([r.get("distance_m") for r in records]),
        "languages": languages,
        "scripts": scripts,
        "position_m": position,
        "normal_m": normal,
        "observations": [{k: v for k, v in r.items() if k not in {"heights_m"}} for r in records],
        "observation_count": len(records),
    }
    sign["legibility"] = _legibility(sign)
    sign["i18n"] = {"language_independent": bool(pictos or arrows), "languages": languages, "scripts": scripts,
                    "multilingual": len(languages) > 1 or len(scripts) > 1,
                    "text_only": bool((all_texts or text_lines) and not pictos and not arrows)}
    sign["issues"], sign["notes"] = assess_mod.assess(sign)
    return sign


def _legibility(sign: dict) -> dict | None:
    char_height, distance = sign.get("char_height_m"), sign.get("viewing_distance_m")
    baseline = sign.get("heights_m", {}).get("text_baseline_low")
    if char_height is None or distance is None or baseline is None:
        return None
    required = assess_mod.min_character_height_m(baseline, distance)
    return {"char_height_m": char_height, "viewing_distance_m": distance,
            "required_min_char_height_m": round(required, 4), "meets": char_height >= required,
            "rule": "ADA 2010 703.5.5 (observed capture distance as the viewing distance)"}


def _legacy_kind(head: Observation, category: str, pictos: list[str], color: str | None) -> str:
    if not head.is_plate:
        return "text_region"
    if category in {"exit", "emergency_exit"}:
        return "exit_sign_candidate"
    if "wheelchair" in pictos or category == "accessible_restroom":
        return "accessibility_sign_candidate"
    return LEGACY_KIND.get(color or "", "sign_candidate") if category in {"informational", "directional"} else "sign_candidate"


def analyze(frames: list[Frame], read_image: Callable[[str], np.ndarray | None], *, texts: list[dict] | None = None,
            floor_height: float | None = None, cameras: dict[str, np.ndarray] | None = None,
            ocr: bool = True) -> tuple[list[dict], int]:
    """Returns assessed, deduplicated signs and the number of keyframes examined."""
    texts_by_frame: dict[str, list[dict]] = {}
    for text in texts or []:
        if text.get("frame_id"):
            texts_by_frame.setdefault(text["frame_id"], []).append(text)
    observations, examined = [], 0
    for frame in frames:
        if not frame.color_asset:
            continue
        image = read_image(frame.color_asset)
        if image is None:
            continue
        examined += 1
        observations.extend(_observe(frame, image, texts_by_frame, cameras or {}, ocr))
    signs = [_sign(cluster, floor_height) for cluster in _cluster(observations)]
    signs.sort(key=lambda s: (s["kind"] == "text_region", -s["score"], s["category"],
                              s["position_m"] or [1e9] * 3, s["observations"][0]["frame_id"],
                              s["observations"][0]["bbox_xywh_px"]))
    for index, sign in enumerate(signs):
        sign["id"] = f"sign-{index:03d}"
    return [{"id": s.pop("id"), **s} for s in signs], examined

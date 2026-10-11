"""Draws the ranked highlights on the floor plan with OpenCV.

The plan is dimmed everywhere except around what matters (a Gaussian-blurred spotlight mask),
each item is outlined in its severity colour, numbered callouts are placed without overlapping,
and a legend panel lists them. Pixel positions are returned so a viewer can hit-test the image.
"""
from __future__ import annotations

import math
import unicodedata
from typing import Any

import cv2
import numpy as np

from .rank import SEVERITIES, Highlight, Options

# BGR. Same palette as the web studio: barrier #c62828, warning #c77700, asset #2e9d57, route #0071e3.
SEVERITY_COLORS = {"barrier": (40, 40, 198), "warning": (0, 119, 199), "asset": (87, 157, 46), "info": (227, 113, 0)}
ROUTE_COLOR = (227, 113, 0)
PAPER = (245, 245, 243)
INK = (38, 36, 34)
MUTED = (110, 106, 100)
FONT = cv2.FONT_HERSHEY_DUPLEX
SMALL = cv2.FONT_HERSHEY_SIMPLEX
MAX_PNG_BYTES = 6 * 1024 * 1024


def ascii_text(text: str) -> str:
    """cv2.putText only draws ASCII; accents fold to their base letter, the rest becomes '?'."""
    folded = unicodedata.normalize("NFKD", text)
    return "".join(c if 32 <= ord(c) < 127 else ("?" if not unicodedata.combining(c) else "") for c in folded)


def _wrap(text: str, font, scale: float, thickness: int, width: int, max_lines: int) -> list[str]:
    lines: list[str] = []
    line = ""
    for word in ascii_text(text).split():
        trial = f"{line} {word}".strip()
        if cv2.getTextSize(trial, font, scale, thickness)[0][0] <= width or not line:
            line = trial
        else:
            lines.append(line)
            line = word
    if line:
        lines.append(line)
    if len(lines) > max_lines:
        lines = lines[:max_lines]
        lines[-1] = lines[-1][: max(0, len(lines[-1]) - 3)].rstrip() + "..."
    return lines


def _overlaps(rect, others, margin=4) -> bool:
    x, y, w, h = rect
    return any(x - margin < ox + ow and ox - margin < x + w and y - margin < oy + oh and oy - margin < y + h
               for ox, oy, ow, oh in others)


def _pixels(points, origin, resolution, scale) -> np.ndarray:
    arr = np.asarray(points, np.float64).reshape(-1, 2)
    return np.round((arr - np.asarray(origin)) / resolution * scale).astype(np.int32)


def _free_slot(anchor, radius, map_w, map_h, occupied):
    """The nearest badge position to `anchor` that stays inside the map and clear of other badges:
    expanding rings with fine angular steps, then a sweep of the whole map."""
    def fits(cx, cy):
        rect = (cx - radius, cy - radius, 2 * radius, 2 * radius)
        inside = rect[0] >= 0 and rect[1] >= 0 and rect[0] + rect[2] <= map_w and rect[1] + rect[3] <= map_h
        return rect if inside and not _overlaps(rect, occupied) else None

    ring = 2.3
    while ring <= 16:
        steps = max(8, int(2 * math.pi * ring * radius / (2 * radius + 6)))
        for k in range(steps):
            angle = -math.pi / 2 + 2 * math.pi * k / steps
            cx = int(anchor[0] + math.cos(angle) * radius * ring)
            cy = int(anchor[1] + math.sin(angle) * radius * ring)
            rect = fits(cx, cy)
            if rect:
                return cx, cy, rect
        ring += 0.9
    best = None
    for cy in range(radius, max(radius + 1, map_h - radius + 1), radius):
        for cx in range(radius, max(radius + 1, map_w - radius + 1), radius):
            rect = fits(cx, cy)
            if rect:
                d = math.dist((cx, cy), anchor)
                if best is None or d < best[0]:
                    best = (d, cx, cy, rect)
    if best:
        return best[1], best[2], best[3]
    cx, cy = min(max(radius, anchor[0]), map_w - radius), min(max(radius, anchor[1]), map_h - radius)
    return cx, cy, (cx - radius, cy - radius, 2 * radius, 2 * radius)


def _nice_length(meters_per_px: float) -> float:
    for length in (0.5, 1, 2, 5, 10, 20, 50):
        if 70 <= length / meters_per_px <= 220:
            return float(length)
    return 5.0


def _dashed(image, a, b, color, thickness) -> None:
    a, b = np.asarray(a, np.float64), np.asarray(b, np.float64)
    total = float(np.linalg.norm(b - a))
    if total < 1:
        return
    step = max(10.0, thickness * 3.0)
    for start in np.arange(0, total, step * 2):
        p = a + (b - a) * (start / total)
        q = a + (b - a) * (min(total, start + step) / total)
        cv2.line(image, tuple(np.round(p).astype(int)), tuple(np.round(q).astype(int)), color, thickness, cv2.LINE_AA)


def render_scene(base_bgra: np.ndarray, grid: dict[str, Any], highlights: list[Highlight],
                 polylines: list[list[list[float]]] | None = None,
                 options: Options | None = None) -> tuple[bytes, dict[str, Any]]:
    """Returns the PNG and its metadata (size, scale, origin, per-item pixel positions)."""
    options = options or Options()
    height, width = base_bgra.shape[:2]
    origin = grid["origin_xz_m"]
    resolution = float(grid["resolution_m"])
    scale = float(min(4.0, max(1.0, options.width_px / max(width, 1))))
    for _ in range(3):
        png, meta = _render(base_bgra, origin, resolution, scale, highlights, polylines or [], options)
        if len(png) <= MAX_PNG_BYTES or scale <= 1.0:
            break
        scale = max(1.0, scale / 1.6)
    meta["origin_xz_m"] = [float(origin[0]), float(origin[1])]
    return png, meta


def _render(base_bgra, origin, resolution, scale, highlights, polylines, options):
    h0, w0 = base_bgra.shape[:2]
    map_w, map_h = max(1, round(w0 * scale)), max(1, round(h0 * scale))
    resized = cv2.resize(base_bgra, (map_w, map_h), interpolation=cv2.INTER_LINEAR)
    alpha = resized[..., 3:4].astype(np.float32) / 255.0
    paper = np.empty((map_h, map_w, 3), np.uint8)
    paper[:] = PAPER
    scene = (paper * (1 - alpha) + resized[..., :3] * alpha).astype(np.uint8)

    px_per_m = scale / resolution
    # A faint metre grid orients the eye without competing with the highlights.
    spacing = max(1, round(px_per_m * (2 if px_per_m * 2 < 700 else 1)))
    grid_layer = scene.copy()
    for x in range(0, map_w, spacing):
        cv2.line(grid_layer, (x, 0), (x, map_h), (225, 226, 224), 1)
    for y in range(0, map_h, spacing):
        cv2.line(grid_layer, (0, y), (map_w, y), (225, 226, 224), 1)
    scene = np.where(alpha > 0, scene, grid_layer).astype(np.uint8)

    def px(points):
        return _pixels(points, origin, resolution, scale)

    # Spotlight: dim the plan outside the neighbourhood of every highlight.
    focus_mass: np.ndarray | None = None
    if highlights:
        focus = np.zeros((map_h, map_w), np.uint8)
        reach = max(6, int(1.1 * px_per_m))
        for item in highlights:
            geometry = item.geometry
            kind, xz = geometry.get("type"), geometry.get("xz") or [item.position_xz_m]
            points = px(xz)
            if kind == "polygon" and len(points) >= 3:
                cv2.fillPoly(focus, [points], 255)
            elif kind in ("segment", "polyline") and len(points) >= 2:
                cv2.polylines(focus, [points], False, 255, max(2, reach), cv2.LINE_AA)
            else:
                radius = int(max(0.5, float(geometry.get("radius_m", 0.5))) * px_per_m) + reach
                cv2.circle(focus, tuple(points[0]), radius, 255, -1, cv2.LINE_AA)
        focus = cv2.dilate(focus, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * reach + 1,) * 2))
        sigma = max(4.0, reach * 1.4)
        focus = cv2.GaussianBlur(focus, (0, 0), sigma).astype(np.float32) / 255.0
        focus_mass = focus
        # Fade towards paper (not black) so the plan stays readable but quiet away from the findings.
        fade = (0.62 * (1.0 - focus))[..., None]
        scene = (scene.astype(np.float32) * (1 - fade) + np.asarray(PAPER, np.float32) * fade).astype(np.uint8)

    # Routes sit under the highlights.
    line = max(2, int(0.1 * px_per_m))
    for path in polylines:
        points = px(path)
        if len(points) < 2:
            continue
        cv2.polylines(scene, [points], False, ROUTE_COLOR, line, cv2.LINE_AA)
        distance = 0.0
        for a, b in zip(points[:-1], points[1:]):
            distance += float(np.linalg.norm(b - a))
            if distance >= 3.0 * px_per_m:
                distance = 0.0
                direction = (b - a).astype(np.float32)
                length = float(np.linalg.norm(direction)) or 1.0
                unit = direction / length
                normal = np.array([-unit[1], unit[0]], np.float32)
                size = max(6.0, min(14.0, 0.2 * px_per_m))
                tip = b.astype(np.float32)
                head = np.array([tip, tip - unit * size + normal * size * 0.55, tip - unit * size - normal * size * 0.55])
                cv2.fillConvexPoly(scene, np.round(head).astype(np.int32), ROUTE_COLOR, cv2.LINE_AA)

    # Translucent fills, then crisp outlines (lowest importance first so the top item is on top).
    layer = scene.copy()
    ordered = list(reversed(highlights))
    shapes = []
    for item in ordered:
        color = SEVERITY_COLORS.get(item.severity, SEVERITY_COLORS["info"])
        geometry = item.geometry
        kind = geometry.get("type", "point")
        points = px(geometry.get("xz") or [item.position_xz_m])
        shapes.append((item, color, kind, points, geometry))
        if kind == "polygon" and len(points) >= 3:
            cv2.fillPoly(layer, [points], color)
        elif kind == "circle":
            cv2.circle(layer, tuple(points[0]), int(float(geometry.get("radius_m", 0.6)) * px_per_m), color, -1, cv2.LINE_AA)
        elif kind in ("segment", "polyline") and len(points) >= 2:
            if geometry.get("dashed"):
                for a, b in zip(points[:-1], points[1:]):
                    _dashed(layer, a, b, color, 3)
            else:
                cv2.polylines(layer, [points], False, color, max(4, int(0.28 * px_per_m)), cv2.LINE_AA)
    scene = cv2.addWeighted(layer, 0.42, scene, 0.58, 0)
    for item, color, kind, points, geometry in shapes:
        thickness = 3 if item.rank and item.rank <= max(3, options.callouts // 3) else 2
        if kind == "polygon" and len(points) >= 3:
            cv2.polylines(scene, [points], True, color, thickness, cv2.LINE_AA)
        elif kind == "circle":
            cv2.circle(scene, tuple(points[0]), int(float(geometry.get("radius_m", 0.6)) * px_per_m), color, thickness, cv2.LINE_AA)
        elif kind in ("segment", "polyline") and len(points) >= 2 and not geometry.get("dashed"):
            cv2.polylines(scene, [points], False, color, thickness, cv2.LINE_AA)
        center = tuple(px([item.position_xz_m])[0])
        cv2.circle(scene, center, 5, (255, 255, 255), -1, cv2.LINE_AA)
        cv2.circle(scene, center, 5, color, 2, cv2.LINE_AA)

    # Numbered callouts without overlaps.
    radius = max(11, min(18, map_w // 90))
    font_scale = radius / 20.0 + 0.2
    occupied: list[tuple[int, int, int, int]] = []
    placed: dict[str, dict[str, Any]] = {}
    numbered = highlights[:options.callouts]
    for number, item in enumerate(numbered, start=1):
        anchor = tuple(int(v) for v in px([item.position_xz_m])[0])
        chosen = _free_slot(anchor, radius, map_w, map_h, occupied)
        cx, cy, rect = chosen
        occupied.append(rect)
        color = SEVERITY_COLORS.get(item.severity, SEVERITY_COLORS["info"])
        cv2.line(scene, anchor, (cx, cy), (255, 255, 255), 4, cv2.LINE_AA)
        cv2.line(scene, anchor, (cx, cy), color, 2, cv2.LINE_AA)
        cv2.circle(scene, (cx, cy), radius + 2, (255, 255, 255), -1, cv2.LINE_AA)
        cv2.circle(scene, (cx, cy), radius, color, -1, cv2.LINE_AA)
        label = str(number)
        fit = font_scale * (0.74 if len(label) > 1 else 1.0)
        (tw, th), _ = cv2.getTextSize(label, FONT, fit, 1)
        cv2.putText(scene, label, (cx - tw // 2, cy + th // 2), FONT, fit, (255, 255, 255), 1, cv2.LINE_AA)
        placed[item.id] = {"number": number, "anchor_px": list(anchor), "callout_px": [cx, cy]}
    for item in highlights[options.callouts:]:
        placed[item.id] = {"number": None, "anchor_px": [int(v) for v in px([item.position_xz_m])[0]], "callout_px": None}

    # Scale bar and axes.
    meters_per_px = resolution / scale
    length_m = _nice_length(meters_per_px)
    bar = int(length_m / meters_per_px)
    x0, y0 = 14, map_h - 18
    if focus_mass is not None and bar + 28 < map_w and map_h > 120:
        # Put the scale bar in whichever bottom/top-right corner has the least going on.
        spots = [(14, map_h - 18), (map_w - bar - 14, map_h - 18), (map_w - bar - 14, 30)]
        def busy(spot):
            x, y = spot
            return float(focus_mass[max(0, y - 14): y + 12, max(0, x - 4): x + bar + 8].mean())
        x0, y0 = min(spots, key=busy)
    if bar + 28 < map_w and map_h > 40:
        cv2.rectangle(scene, (x0, y0), (x0 + bar, y0 + 6), INK, -1)
        cv2.rectangle(scene, (x0 + bar // 2, y0), (x0 + bar, y0 + 6), (255, 255, 255), -1)
        cv2.rectangle(scene, (x0, y0), (x0 + bar, y0 + 6), INK, 1)
        cv2.putText(scene, f"{length_m:g} m", (x0, y0 - 6), SMALL, 0.45, INK, 1, cv2.LINE_AA)
    if map_w > 90 and map_h > 90:
        cv2.arrowedLine(scene, (16, 16), (46, 16), MUTED, 2, cv2.LINE_AA, tipLength=0.3)
        cv2.arrowedLine(scene, (16, 16), (16, 46), MUTED, 2, cv2.LINE_AA, tipLength=0.3)
        cv2.putText(scene, "X", (50, 20), SMALL, 0.45, MUTED, 1, cv2.LINE_AA)
        cv2.putText(scene, "Z", (12, 62), SMALL, 0.45, MUTED, 1, cv2.LINE_AA)

    canvas, legend_meta = _with_legend(scene, numbered, highlights, radius, font_scale)
    ok, png = cv2.imencode(".png", canvas, [cv2.IMWRITE_PNG_COMPRESSION, 6])
    if not ok:
        raise RuntimeError("Could not encode the highlights image")
    meta = {"width": int(canvas.shape[1]), "height": int(canvas.shape[0]), "map_width_px": map_w,
            "map_height_px": map_h, "scale": round(scale, 3), "resolution_m_per_px": round(meters_per_px, 5),
            "legend": legend_meta, "items": placed, "axes": "x right, z down (top-down plan)",
            "text_ascii_only": True}
    return png.tobytes(), meta


def _with_legend(scene, numbered, all_items, radius, font_scale):
    map_h, map_w = scene.shape[:2]
    panel_w = int(max(280, min(460, map_w * 0.34)))
    pad = 14
    text_w = panel_w - pad * 2 - (radius * 2 + 10)
    rows: list[tuple[int, Highlight, list[str], list[str]]] = []
    y = pad + 58
    for number, item in enumerate(numbered, start=1):
        title = _wrap(item.title, FONT, 0.5, 1, text_w, 2)
        reason = _wrap(item.reason, SMALL, 0.42, 1, text_w, 2)
        row_h = max(radius * 2 + 8, 20 * len(title) + 17 * len(reason) + 14)
        rows.append((y, item, title, reason))
        y += row_h
    height = max(map_h, y + pad)
    panel = np.empty((height, panel_w, 3), np.uint8)
    panel[:] = (252, 252, 251)
    cv2.line(panel, (0, 0), (0, height), (210, 210, 206), 1)
    cv2.putText(panel, "Key aspects", (pad, pad + 20), FONT, 0.7, INK, 1, cv2.LINE_AA)
    counts = {s: sum(1 for i in all_items if i.severity == s) for s in SEVERITIES}
    x = pad
    for severity in SEVERITIES:
        if not counts[severity]:
            continue
        cv2.circle(panel, (x + 6, pad + 40), 6, SEVERITY_COLORS[severity], -1, cv2.LINE_AA)
        label = f"{counts[severity]} {severity}"
        cv2.putText(panel, label, (x + 17, pad + 44), SMALL, 0.42, MUTED, 1, cv2.LINE_AA)
        x += 17 + cv2.getTextSize(label, SMALL, 0.42, 1)[0][0] + 12
    for number, (top, item, title, reason) in enumerate(rows, start=1):
        color = SEVERITY_COLORS.get(item.severity, SEVERITY_COLORS["info"])
        cx, cy = pad + radius, top + radius
        cv2.circle(panel, (cx, cy), radius, color, -1, cv2.LINE_AA)
        label = str(number)
        fit = font_scale * (0.74 if len(label) > 1 else 1.0)
        (tw, th), _ = cv2.getTextSize(label, FONT, fit, 1)
        cv2.putText(panel, label, (cx - tw // 2, cy + th // 2), FONT, fit, (255, 255, 255), 1, cv2.LINE_AA)
        tx, ty = pad + radius * 2 + 10, top + 12
        for line in title:
            cv2.putText(panel, line, (tx, ty), FONT, 0.5, INK, 1, cv2.LINE_AA)
            ty += 20
        for line in reason:
            cv2.putText(panel, line, (tx, ty), SMALL, 0.42, MUTED, 1, cv2.LINE_AA)
            ty += 17
        bar = int(max(0.0, min(1.0, item.importance)) * (text_w - 4))
        cv2.rectangle(panel, (tx, ty - 6), (tx + text_w - 4, ty - 3), (226, 226, 222), -1)
        cv2.rectangle(panel, (tx, ty - 6), (tx + bar, ty - 3), color, -1)
    if height > map_h:
        pad_img = np.empty((height - map_h, map_w, 3), np.uint8)
        pad_img[:] = PAPER
        scene = np.vstack([scene, pad_img])
    return np.hstack([scene, panel]), {"x": map_w, "width": panel_w, "rows": len(rows)}

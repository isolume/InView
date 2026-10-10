"""Deterministic gallery of rendered signs for tests and an offline confusion report.

Each `SignSpec` is rendered as a plate (pictograms, arrows, text, braille) and composited onto a
textured wall with a perspective tilt, blur and JPEG compression. `evaluate()` runs the signage
reader over every scene and tallies category / pictogram / arrow confusions.

    python -m inview_worker.signage.gallery            # prints the confusion report
"""
from __future__ import annotations

import sys
from collections import Counter
from dataclasses import dataclass, field

import cv2
import numpy as np

from . import pictograms
from .plates import detect
from .reader import read


@dataclass(frozen=True)
class SignSpec:
    name: str
    category: str
    plate_bgr: tuple[int, int, int]
    legend_bgr: tuple[int, int, int]
    symbols: tuple[str, ...] = ()          # pictogram names, "arrow_<dir>", "<name>:mirrored"
    text: str | None = None
    braille: bool = False
    size: tuple[int, int] = (300, 150)     # plate width, height in pixels
    expected_pictograms: tuple[str, ...] | None = None
    expected_arrows: tuple[str, ...] = field(default=())


GREEN, RED, BLUE, WHITE, BLACK = (60, 140, 0), (40, 30, 200), (160, 80, 10), (245, 245, 245), (25, 25, 25)

GALLERY: tuple[SignSpec, ...] = (
    SignSpec("exit_text", "exit", GREEN, WHITE, text="EXIT", expected_pictograms=()),
    SignSpec("emergency_exit_right", "emergency_exit", GREEN, WHITE, ("exit_running_person", "arrow_right"),
             expected_pictograms=("exit_running_person",), expected_arrows=("right",)),
    SignSpec("emergency_exit_left", "emergency_exit", GREEN, WHITE, ("arrow_left", "exit_running_person:mirrored"),
             expected_pictograms=("exit_running_person",), expected_arrows=("left",)),
    SignSpec("restroom", "restroom", WHITE, BLACK, ("man", "woman"), size=(260, 170)),
    SignSpec("restroom_blue_text", "restroom", BLUE, WHITE, ("man", "woman"), text="RESTROOM", size=(280, 220)),
    SignSpec("accessible_restroom", "accessible_restroom", BLUE, WHITE, ("man", "woman", "wheelchair"), size=(330, 160)),
    SignSpec("all_gender", "restroom", BLACK, WHITE, ("all_gender",), size=(170, 200)),
    SignSpec("accessible_route", "directional", BLUE, WHITE, ("wheelchair", "arrow_up_right"), size=(300, 160),
             expected_arrows=("up_right",)),
    SignSpec("elevator", "elevator", BLACK, WHITE, ("elevator",), size=(160, 190)),
    SignSpec("stairs_up", "stairs", WHITE, BLACK, ("stairs_up",), size=(190, 190), expected_pictograms=("stairs_up",),
             expected_arrows=("up_right",)),
    SignSpec("stairs_down", "stairs", WHITE, BLACK, ("stairs_down",), size=(190, 190),
             expected_pictograms=("stairs_down",), expected_arrows=("down_left",)),
    SignSpec("information", "information", BLUE, WHITE, ("information",), size=(170, 170)),
    SignSpec("fire_extinguisher", "fire_extinguisher", RED, WHITE, ("fire_extinguisher",), size=(170, 200)),
    SignSpec("first_aid", "first_aid", GREEN, WHITE, ("first_aid",), size=(180, 180)),
    *(SignSpec(f"arrow_{d}", "directional", BLACK, WHITE, (f"arrow_{d}",), size=(170, 170), expected_pictograms=(),
               expected_arrows=(d,)) for d in pictograms.ARROW_ANGLES),
    SignSpec("room_braille", "informational", BLACK, WHITE, text="ROOM 101", braille=True, size=(300, 170),
             expected_pictograms=()),
    SignSpec("low_contrast", "informational", (232, 232, 232), (165, 165, 165), text="OFFICE", size=(300, 130),
             expected_pictograms=()),
)


def _symbol_mask(symbol: str) -> np.ndarray:
    name, _, flag = symbol.partition(":")
    return pictograms.render(name, mirrored=flag == "mirrored")


def _paint(plate: np.ndarray, mask: np.ndarray, box, color) -> None:
    x, y, w, h = box
    side = min(w, h)
    resized = cv2.resize(mask, (side, side), interpolation=cv2.INTER_AREA).astype(np.float32)[..., None] / 255
    x0, y0 = x + (w - side) // 2, y + (h - side) // 2
    roi = plate[y0:y0 + side, x0:x0 + side].astype(np.float32)
    plate[y0:y0 + side, x0:x0 + side] = (roi * (1 - resized) + np.float32(color) * resized).astype(np.uint8)


def _braille(plate: np.ndarray, box, color) -> None:
    x, y, w, h = box
    pitch = max(5, h // 3)
    radius = max(1, int(round(pitch * 0.32)))
    cells = "100110 110000 101011 111100 100101 110111".split()
    cx = x + pitch
    for cell in cells:
        if cx + pitch > x + w:
            break
        for k, bit in enumerate(cell):
            if bit == "1":
                col, row = divmod(k, 3)
                cv2.circle(plate, (cx + col * pitch, y + pitch // 2 + row * pitch), radius, color, -1, cv2.LINE_AA)
        cx += int(2.6 * pitch)


def render_plate(spec: SignSpec) -> np.ndarray:
    w, h = spec.size
    plate = np.full((h, w, 3), spec.plate_bgr, np.uint8)
    margin = int(0.08 * min(w, h))
    rows = []
    if spec.symbols:
        rows.append(("symbols", 0.62 if (spec.text or spec.braille) else 1.0))
    if spec.text:
        rows.append(("text", 0.38 if spec.symbols else (0.55 if spec.braille else 1.0)))
    if spec.braille:
        rows.append(("braille", 0.3 if spec.text else 1.0))
    total = sum(r[1] for r in rows)
    y = margin
    inner_w, inner_h = w - 2 * margin, h - 2 * margin
    for kind, share in rows:
        row_h = int(inner_h * share / total)
        if kind == "symbols":
            n = len(spec.symbols)
            gap = int(0.06 * inner_w)
            cell = (inner_w - gap * (n - 1)) // n
            for i, symbol in enumerate(spec.symbols):
                _paint(plate, _symbol_mask(symbol), (margin + i * (cell + gap), y, cell, row_h), spec.legend_bgr)
        elif kind == "text":
            scale = 1.0
            (tw, th), _ = cv2.getTextSize(spec.text, cv2.FONT_HERSHEY_DUPLEX, scale, 2)
            scale = min(inner_w / tw, 0.7 * row_h / th)
            thickness = max(2, int(round(scale * 2.2)))
            (tw, th), _ = cv2.getTextSize(spec.text, cv2.FONT_HERSHEY_DUPLEX, scale, thickness)
            cv2.putText(plate, spec.text, (margin + (inner_w - tw) // 2, y + (row_h + th) // 2),
                        cv2.FONT_HERSHEY_DUPLEX, scale, spec.legend_bgr, thickness, cv2.LINE_AA)
        else:
            _braille(plate, (margin, y, inner_w, row_h), spec.legend_bgr)
        y += row_h
    return plate


@dataclass(frozen=True)
class Variant:
    name: str
    scale: float          # plate width as a fraction of the image width
    tilt: float           # horizontal perspective foreshortening (0 = frontal)
    blur: float
    jpeg: int
    roll: float = 0.0     # in-plane rotation, degrees counter-clockwise
    noise: float = 3.0    # wall noise sigma


VARIANTS = (Variant("frontal", 0.55, 0.0, 0.0, 92), Variant("small_tilted", 0.32, 0.12, 0.7, 85),
            Variant("oblique", 0.45, 0.22, 1.0, 80), Variant("rolled_noisy", 0.4, 0.08, 1.2, 70, roll=7, noise=7))


def render_scene(spec: SignSpec, variant: Variant = VARIANTS[0], size=(480, 640), seed: int = 0):
    """Upright keyframe-like image with the plate on a wall; returns (image, plate quad)."""
    width, height = size
    rng = np.random.default_rng(seed)
    ys = np.linspace(0, 1, height)[:, None]
    wall = (np.array([186, 182, 176]) * (0.9 + 0.1 * ys))[..., None].transpose(0, 2, 1)
    image = np.broadcast_to(wall, (height, width, 3)).astype(np.float32)
    image = np.clip(image + rng.normal(0, variant.noise, image.shape), 0, 255).astype(np.uint8)
    plate = render_plate(spec)
    ph, pw = plate.shape[:2]
    target_w = variant.scale * width
    target_h = target_w * ph / pw
    cx, cy = width / 2, height * 0.42
    squeeze = variant.tilt * target_h
    dst = np.float32([[cx - target_w / 2, cy - target_h / 2], [cx + target_w / 2, cy - target_h / 2 + squeeze / 2],
                      [cx + target_w / 2, cy + target_h / 2 - squeeze / 2], [cx - target_w / 2, cy + target_h / 2]])
    if variant.roll:
        roll = cv2.getRotationMatrix2D((cx, cy), variant.roll, 1.0)
        dst = (np.hstack((dst, np.ones((4, 1), np.float32))) @ roll.T).astype(np.float32)
    src = np.float32([[0, 0], [pw, 0], [pw, ph], [0, ph]])
    warp = cv2.getPerspectiveTransform(src, dst)
    warped = cv2.warpPerspective(plate, warp, (width, height), flags=cv2.INTER_AREA)
    mask = cv2.warpPerspective(np.full((ph, pw), 255, np.uint8), warp, (width, height))
    image[mask > 127] = warped[mask > 127]
    if variant.blur:
        image = cv2.GaussianBlur(image, (0, 0), variant.blur)
    image = cv2.imdecode(cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, variant.jpeg])[1], cv2.IMREAD_COLOR)
    return image, dst


def read_scene(image: np.ndarray):
    """Best plate detection in a scene and its reading (no OCR)."""
    plates = [d for d in detect(image, ocr=False) if d.kind != "text_region"]
    if not plates:
        return None, None
    plate = max(plates, key=lambda d: d.bbox[2] * d.bbox[3])
    return plate, read(image, plate)


def evaluate(variants=VARIANTS) -> dict:
    from .assess import infer_category

    rows, category_confusion, pictogram_confusion, arrow_confusion = [], Counter(), Counter(), Counter()
    for spec in GALLERY:
        expected_pictos = spec.expected_pictograms if spec.expected_pictograms is not None else tuple(
            s.partition(":")[0] for s in spec.symbols if not s.startswith("arrow_"))
        for variant in variants:
            image, _ = render_scene(spec, variant)
            plate, reading = read_scene(image)
            if reading is None:
                found_category, pictos, arrows = "missed", (), ()
            else:
                pictos = tuple(sorted(_pictogram_names(reading)))
                arrows = tuple(sorted(a["image_direction"] for a in reading.arrows))
                found_category = infer_category(pictos, [a["image_direction"] for a in reading.arrows],
                                                plate.color, [], bool(reading.text_lines))[0]
            category_confusion[(spec.category, found_category)] += 1
            pictogram_confusion[(",".join(sorted(expected_pictos)) or "-", ",".join(pictos) or "-")] += 1
            arrow_confusion[(",".join(sorted(spec.expected_arrows)) or "-", ",".join(arrows) or "-")] += 1
            rows.append({"sign": spec.name, "variant": variant.name, "expected": spec.category,
                         "category": found_category, "pictograms": list(pictos), "arrows": list(arrows),
                         "contrast_ratio": reading.contrast_ratio if reading else None,
                         "braille": bool(reading and reading.braille)})
    correct = sum(n for (a, b), n in category_confusion.items() if a == b)
    total = sum(category_confusion.values())
    return {"rows": rows, "category_accuracy": round(correct / max(total, 1), 3),
            "category_confusion": {f"{a} -> {b}": n for (a, b), n in sorted(category_confusion.items())},
            "pictogram_confusion": {f"{a} -> {b}": n for (a, b), n in sorted(pictogram_confusion.items())},
            "arrow_confusion": {f"{a} -> {b}": n for (a, b), n in sorted(arrow_confusion.items())}}


def _pictogram_names(reading) -> list[str]:
    from .assess import resolve_pictograms

    return resolve_pictograms([p["name"] for p in reading.pictograms], [a["image_direction"] for a in reading.arrows])


def main() -> None:
    report = evaluate()
    for row in report["rows"]:
        mark = "ok " if row["expected"] == row["category"] else "ERR"
        print(f"{mark} {row['sign']:<22} {row['variant']:<13} -> {row['category']:<20} "
              f"pictograms={row['pictograms']} arrows={row['arrows']} contrast={row['contrast_ratio']} "
              f"braille={row['braille']}")
    print(f"\ncategory accuracy: {report['category_accuracy']}")
    for key in ("category_confusion", "pictogram_confusion", "arrow_confusion"):
        print(f"\n{key}:")
        for pair, n in report[key].items():
            a, b = pair.split(" -> ")
            print(f"  {'  ' if a == b else '!!'} {pair}: {n}")


if __name__ == "__main__":
    sys.exit(main())

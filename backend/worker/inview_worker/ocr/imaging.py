"""Image preprocessing and quad geometry for OCR: CLAHE, denoising, rectification, line splitting."""
from __future__ import annotations

import cv2
import numpy as np


def clahe(bgr: np.ndarray, clip: float = 2.5, tiles: int = 8) -> np.ndarray:
    """Local contrast equalisation on the LAB lightness channel (keeps colour for colour models)."""
    lab = cv2.cvtColor(bgr, cv2.COLOR_BGR2LAB)
    lab[..., 0] = cv2.createCLAHE(clipLimit=clip, tileGridSize=(tiles, tiles)).apply(np.ascontiguousarray(lab[..., 0]))
    return cv2.cvtColor(lab, cv2.COLOR_LAB2BGR)


def denoise(bgr: np.ndarray) -> np.ndarray:
    """Non-local-means denoising sized for small crops (JPEG blocking, sensor noise)."""
    return cv2.fastNlMeansDenoisingColored(bgr, None, 5, 5, 7, 21)


def order_quad(points) -> np.ndarray:
    """Corners as [bottom-left, top-left, top-right, bottom-right] for left-to-right reading.

    The reading direction is the quad's long axis, oriented so it points right (+x) in the image;
    "up" is perpendicular to it, towards smaller y. Vertical lines read top-to-bottom.
    """
    pts = np.asarray(points, np.float64).reshape(4, 2)
    center = pts.mean(axis=0)
    (_, _), (w, h), angle = cv2.minAreaRect(pts.astype(np.float32))
    theta = np.radians(angle)
    axis = np.array([np.cos(theta), np.sin(theta)])
    if h > w:
        axis = np.array([-axis[1], axis[0]])
    axis[np.abs(axis) < 1e-9] = 0.0  # minAreaRect angles of ±90° leave rounding residue
    if axis[0] < -1e-9 or (abs(axis[0]) <= 1e-9 and axis[1] < 0):
        axis = -axis
    up = np.array([axis[1], -axis[0]])
    if up[1] > 0:
        up = -up
    along, across = (pts - center) @ axis, (pts - center) @ up
    left = np.argsort(along, kind="stable")[:2]
    right = np.argsort(along, kind="stable")[2:]
    tl, bl = (left[0], left[1]) if across[left[0]] >= across[left[1]] else (left[1], left[0])
    tr, br = (right[0], right[1]) if across[right[0]] >= across[right[1]] else (right[1], right[0])
    return pts[[bl, tl, tr, br]].astype(np.float32)


def quad_size(quad: np.ndarray) -> tuple[float, float]:
    """(reading length, line height) of an ordered quad."""
    bl, tl, tr, br = quad
    return (float(np.linalg.norm(tr - tl) + np.linalg.norm(br - bl)) / 2,
            float(np.linalg.norm(bl - tl) + np.linalg.norm(br - tr)) / 2)


def expand_quad(quad: np.ndarray, pad_x: float, pad_y: float) -> np.ndarray:
    """Grow an ordered quad by fractions of its length/height along its own axes."""
    bl, tl, tr, br = quad.astype(np.float64)
    right = ((tr - tl) + (br - bl)) / 2
    down = ((bl - tl) + (br - tr)) / 2
    dx, dy = right * pad_x, down * pad_y
    return np.array([bl - dx + dy, tl - dx - dy, tr + dx - dy, br + dx + dy], np.float32)


def rectify(bgr: np.ndarray, quad: np.ndarray, height: int | None = None) -> np.ndarray:
    """Perspective-rectify an ordered quad into an upright crop (`getPerspectiveTransform`).

    The output keeps the quad's aspect ratio; `height` rescales it (default: native line height).
    """
    length, line = quad_size(quad)
    out_h = max(8, int(round(height or line)))
    out_w = max(8, int(round(out_h * length / max(line, 1.0))))
    target = np.array([[0, out_h - 1], [0, 0], [out_w - 1, 0], [out_w - 1, out_h - 1]], np.float32)
    matrix = cv2.getPerspectiveTransform(quad.astype(np.float32), target)
    return cv2.warpPerspective(bgr, matrix, (out_w, out_h), flags=cv2.INTER_CUBIC, borderMode=cv2.BORDER_REPLICATE)


def ink_mask(crop: np.ndarray) -> np.ndarray:
    """Otsu text mask; the minority class is ink (works for dark-on-light and light-on-dark)."""
    gray = crop if crop.ndim == 2 else cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
    _, mask = cv2.threshold(gray, 0, 1, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    return mask if mask.mean() < 0.5 else 1 - mask


def split_line(crop: np.ndarray, max_aspect: float = 4.0) -> list[tuple[np.ndarray, bool]]:
    """Split a long rectified line into chunks a fixed-width (100×32) CRNN can read.

    Cuts at inter-word gaps of the column ink profile, grouping words while a chunk stays under
    `max_aspect`; an over-long word is cut at its emptiest column. Returns (chunk, space_before).
    """
    h, w = crop.shape[:2]
    if w <= max_aspect * h:
        return [(crop, False)]
    ink = ink_mask(crop)
    margin = max(1, h // 8)
    profile = ink[margin:h - margin].sum(axis=0) if h > 2 * margin + 1 else ink.sum(axis=0)
    empty = profile <= max(1, 0.02 * h)
    # Runs of empty columns wider than a fraction of the height are word gaps.
    gaps, start = [], None
    for x, is_empty in enumerate(np.append(empty, False)):
        if is_empty and start is None:
            start = x
        elif not is_empty and start is not None:
            if x - start >= max(2, 0.18 * h) and start > 0 and x < w:
                gaps.append(((start + x) // 2, x - start))
            start = None
    cuts, chunk_start, last_gap = [], 0, None
    for x, width in gaps + [(w, 0)]:
        if x - chunk_start > max_aspect * h and last_gap is not None and last_gap[0] > chunk_start:
            cuts.append(last_gap)
            chunk_start = last_gap[0]
        last_gap = (x, width)
    bounds, spaces = [0] + [c for c, _ in cuts] + [w], [False] + [g >= 0.3 * h for _, g in cuts]
    chunks: list[tuple[np.ndarray, bool]] = []
    for (x0, x1), space in zip(zip(bounds[:-1], bounds[1:]), spaces):
        piece = crop[:, x0:x1]
        while piece.shape[1] > max_aspect * h * 1.25:  # a single over-long word: cut at the emptiest column
            lo, hi = int(0.6 * max_aspect * h), int(max_aspect * h)
            local = ink_mask(piece)[:, lo:hi].sum(axis=0)
            cut = lo + int(np.argmin(local))
            chunks.append((piece[:, :cut], space))
            piece, space = piece[:, cut:], False
        if piece.shape[1] >= 2:
            chunks.append((piece, space))
    return chunks


def iou_xywh(a, b) -> float:
    ax2, ay2, bx2, by2 = a[0] + a[2], a[1] + a[3], b[0] + b[2], b[1] + b[3]
    w, h = max(0.0, min(ax2, bx2) - max(a[0], b[0])), max(0.0, min(ay2, by2) - max(a[1], b[1]))
    union = a[2] * a[3] + b[2] * b[3] - w * h
    return float(w * h / union) if union > 0 else 0.0


def bbox_of(quad: np.ndarray, width: int, height: int) -> list[int]:
    """Axis-aligned [x, y, w, h] of a quad, clipped to the image."""
    x0, y0 = np.clip(np.floor(quad.min(axis=0)), 0, [width - 1, height - 1])
    x1, y1 = np.clip(np.ceil(quad.max(axis=0)), 0, [width, height])
    return [int(x0), int(y0), max(1, int(x1 - x0)), max(1, int(y1 - y0))]

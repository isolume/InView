"""Detection and rectification geometry on rendered text, with a mocked recognizer (no models)."""
import cv2
import numpy as np
import pytest

from inview_worker.ocr.detect import MserDetector, Region, input_sizes, rotated_nms
from inview_worker.ocr.engine import OcrConfig, OcrEngine
from inview_worker.ocr.imaging import expand_quad, iou_xywh, order_quad, quad_size, rectify, split_line
from inview_worker.ocr.recognize import Reading, ctc_greedy, log_softmax


def render(text: str, scale: float = 2.0, thickness: int = 4, pad: int = 12) -> np.ndarray:
    (w, h), base = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, scale, thickness)
    canvas = np.full((h + base + 2 * pad, w + 2 * pad, 3), 245, np.uint8)
    cv2.putText(canvas, text, (pad, pad + h), cv2.FONT_HERSHEY_SIMPLEX, scale, (20, 20, 20), thickness, cv2.LINE_AA)
    return canvas


def place_on_scene(patch: np.ndarray, homography_target: np.ndarray, size=(640, 480)) -> tuple[np.ndarray, np.ndarray]:
    """Warp `patch` so its corners land on `homography_target` ([tl, tr, br, bl]); returns (scene, quad)."""
    h, w = patch.shape[:2]
    source = np.array([[0, 0], [w - 1, 0], [w - 1, h - 1], [0, h - 1]], np.float32)
    matrix = cv2.getPerspectiveTransform(source, homography_target.astype(np.float32))
    scene = np.full((size[1], size[0], 3), 170, np.uint8)
    mask = cv2.warpPerspective(np.full((h, w), 255, np.uint8), matrix, size)
    warped = cv2.warpPerspective(patch, matrix, size, flags=cv2.INTER_CUBIC)
    scene[mask > 0] = warped[mask > 0]
    return scene, homography_target


def rotated_target(w: float, h: float, angle_deg: float, center=(320, 240)) -> np.ndarray:
    theta = np.radians(angle_deg)
    rotation = np.array([[np.cos(theta), -np.sin(theta)], [np.sin(theta), np.cos(theta)]])
    corners = np.array([[-w / 2, -h / 2], [w / 2, -h / 2], [w / 2, h / 2], [-w / 2, h / 2]])
    return corners @ rotation.T + center


def similarity(a: np.ndarray, b: np.ndarray) -> float:
    a = cv2.cvtColor(a, cv2.COLOR_BGR2GRAY).astype(np.float32)
    b = cv2.resize(cv2.cvtColor(b, cv2.COLOR_BGR2GRAY), (a.shape[1], a.shape[0])).astype(np.float32)
    return float(cv2.matchTemplate(a, b, cv2.TM_CCOEFF_NORMED).max())


@pytest.mark.parametrize("angle", [-60, -35, -10, 0, 20, 45, 70])
def test_order_quad_reads_left_to_right_for_any_corner_order(angle):
    target = rotated_target(300, 80, angle)              # tl, tr, br, bl in reading order
    for shift in range(4):
        shuffled = np.roll(target, shift, axis=0)[::-1 if shift % 2 else 1]
        bl, tl, tr, br = order_quad(shuffled)
        np.testing.assert_allclose([tl, tr, br, bl], target, atol=1e-3)


@pytest.mark.parametrize("angle,scale", [(0, 1.0), (25, 1.5), (-30, 2.0), (50, 1.2), (-70, 2.5)])
def test_rectify_undoes_rotation(angle, scale):
    patch = render("EXIT", scale)
    h, w = patch.shape[:2]
    scene, target = place_on_scene(patch, rotated_target(w, h, angle))
    crop = rectify(scene, order_quad(target))
    assert crop.shape[1] > crop.shape[0]
    assert similarity(crop, patch) > 0.85
    assert similarity(cv2.rotate(crop, cv2.ROTATE_180), patch) < similarity(crop, patch)


@pytest.mark.parametrize("target", [
    [[150, 160], [520, 120], [530, 300], [140, 270]],     # wall seen obliquely from the left
    [[100, 200], [560, 210], [500, 300], [160, 295]],     # sign above eye level (keystone)
    [[200, 100], [450, 180], [430, 260], [190, 200]],     # rotated + perspective
])
def test_rectify_undoes_perspective(target):
    patch = render("Room 204", 2.0)
    scene, quad = place_on_scene(patch, np.asarray(target, np.float64))
    crop = rectify(scene, order_quad(quad))
    assert similarity(crop, patch) > 0.8


@pytest.mark.parametrize("box", [
    [[0, 0], [10, 0], [10, 100], [0, 100]],               # exactly vertical (minAreaRect angle ±90)
    [[0, 0], [100, 0], [100, 10], [0, 10]],
    [[5, 5], [5, 105], [15, 105], [15, 5]],
])
def test_order_quad_never_mirrors(box):
    bl, tl, tr, br = order_quad(box)
    right, down = tr - tl, bl - tl
    assert right[0] * down[1] - right[1] * down[0] > 0   # a rotation of the image, not a reflection


def test_expand_and_size():
    quad = order_quad(rotated_target(200, 50, 0))
    length, height = quad_size(quad)
    assert length == pytest.approx(200) and height == pytest.approx(50)
    grown = expand_quad(quad, 0.1, 0.2)
    assert quad_size(grown) == pytest.approx((240, 70))


def test_split_line_cuts_long_lines_at_word_gaps():
    crop = render("EMERGENCY EXIT ONLY", 1.5, 3)
    chunks = split_line(crop, max_aspect=4.0)
    assert len(chunks) >= 2
    assert all(c.shape[1] <= 4.0 * crop.shape[0] * 1.25 + 1 for c, _ in chunks)
    assert sum(c.shape[1] for c, _ in chunks) == crop.shape[1]
    assert chunks[0][1] is False and any(space for _, space in chunks[1:])
    short = render("EXIT")
    assert len(split_line(short)) == 1


def test_rotated_nms_merges_multiscale_duplicates():
    a = Region(order_quad(rotated_target(200, 40, 10)), 0.9, "db")
    b = Region(order_quad(rotated_target(204, 42, 11)), 0.8, "db")
    c = Region(order_quad(rotated_target(100, 30, 0, center=(100, 400))), 0.7, "db")
    kept = rotated_nms([b, c, a])
    assert [r.score for r in kept] == [0.9, 0.7]


def test_input_sizes_are_multiples_of_32_and_capped():
    assert input_sizes(480, 640) == [(544, 736), (960, 1280)]
    assert all(w % 32 == 0 and h % 32 == 0 for w, h in input_sizes(1920, 1440))
    assert input_sizes(200, 100) == [(384, 192)]           # never more than 2x upscale; duplicates removed


def test_ctc_greedy_collapses_repeats_and_blanks():
    charset = list("EXIT")
    steps = [1, 1, 0, 2, 3, 3, 0, 4, 0, 5, 0]               # E E - X I I - T - <space> -
    logits = np.full((len(steps), 6), -10.0)
    logits[np.arange(len(steps)), steps] = 10.0
    text, confidence = ctc_greedy(log_softmax(logits), charset)
    assert text == "EXIT" and confidence > 0.99
    assert np.allclose(log_softmax(log_softmax(logits)), log_softmax(logits))   # idempotent on log-probs


def test_iou():
    assert iou_xywh((0, 0, 10, 10), (5, 0, 10, 10)) == pytest.approx(1 / 3)
    assert iou_xywh((0, 0, 1, 1), (2, 2, 1, 1)) == 0.0


class FakeRecognizer:
    engine = "opencv_dnn"
    name = "fake"

    def __init__(self):
        self.crops = []

    def recognize(self, crop):
        self.crops.append(crop)
        return Reading("EXIT", 0.9, self.engine, self.name)


@pytest.mark.parametrize("scale", [1.0, 1.6, 2.4])
def test_mser_fallback_detects_rendered_text_and_feeds_upright_crops(scale):
    patch = render("EXIT", scale, max(2, int(2 * scale)))
    h, w = patch.shape[:2]
    scene, target = place_on_scene(patch, rotated_target(w, h, 0))
    recognizer = FakeRecognizer()
    engine = OcrEngine(MserDetector(), [recognizer], OcrConfig())
    results = engine.read(scene)
    assert results and all(reading.text == "EXIT" for _, reading in results)
    box = cv2.boundingRect(cv2.findNonZero((cv2.cvtColor(scene, cv2.COLOR_BGR2GRAY) < 100).astype(np.uint8)))
    best = max(iou_xywh(cv2.boundingRect(region.quad), box) for region, _ in results)
    assert best > 0.5
    assert all(crop.shape[1] > crop.shape[0] for crop in recognizer.crops)


def test_engine_drops_low_confidence_and_prefers_cjk():
    class Fixed:
        engine = "opencv_dnn"

        def __init__(self, name, text, confidence):
            self.name, self.text, self.confidence = name, text, confidence

        def recognize(self, crop):
            return Reading(self.text, self.confidence, self.engine, self.name)

    class OneBox:
        name = "fixed"

        def detect(self, bgr):
            return [Region(order_quad(rotated_target(200, 50, 0)), 0.9, "fixed")]

    scene = np.full((480, 640, 3), 200, np.uint8)
    low = OcrEngine(OneBox(), [Fixed("a", "EXIT", 0.2)], OcrConfig(min_confidence=0.5))
    assert low.read(scene) == []
    mixed = OcrEngine(OneBox(), [Fixed("crnn_ch", "LI", 0.8), Fixed("crnn_cn", "出口", 0.78)], OcrConfig())
    assert mixed.read(scene)[0][1].text == "出口"
    latin = OcrEngine(OneBox(), [Fixed("crnn_ch", "EXIT", 0.95), Fixed("crnn_cn", "出口", 0.5)], OcrConfig())
    assert latin.read(scene)[0][1].text == "EXIT"

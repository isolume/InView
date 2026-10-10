"""Text stage on the synthetic package: 3D placement and normal, image selection, fallbacks.

Real-model tests run only when the OpenCV-zoo models are already cached (`INVIEW_MODEL_DIR`);
nothing here downloads.
"""
import json

import cv2
import numpy as np
import pytest

from inview_worker import ocr
from inview_worker.core import MemorySource, ScanContext, runner
from inview_worker.geometry import jpeg_to_sensor_uv
from inview_worker.inputs import Frame, ScanInputs
from inview_worker.ocr import engine as ocr_engine
from inview_worker.ocr.detect import Region
from inview_worker.ocr.imaging import order_quad
from inview_worker.ocr.placement import fit_plane, place, sample_pixels
from inview_worker.ocr.recognize import Reading
from inview_worker.stages.text import TextStage
from inview_worker.synthetic import package

MODELS_CACHED = all(ocr.ModelStore(allow_download=False).cached(k) for k in ("detector_db", "crnn_charsets", "crnn_ch", "crnn_cn"))
needs_models = pytest.mark.skipif(not MODELS_CACHED, reason="OpenCV-zoo text models are not cached")


@pytest.fixture(autouse=True)
def no_downloads(monkeypatch):
    monkeypatch.setenv("INVIEW_MODEL_DOWNLOAD", "0")


def green_plate_quad(image: np.ndarray) -> np.ndarray:
    hsv = cv2.cvtColor(image, cv2.COLOR_BGR2HSV)
    x, y, w, h = cv2.boundingRect(cv2.findNonZero(cv2.inRange(hsv, (40, 100, 80), (85, 255, 255))))
    return order_quad([[x, y], [x + w, y], [x + w, y + h], [x, y + h]])


class PlateDetector:
    name = "plate"

    def detect(self, bgr):
        return [Region(green_plate_quad(bgr), 0.99, self.name)]


class FakeRecognizer:
    engine, name = "opencv_dnn", "fake"

    def recognize(self, crop):
        return Reading("EXIT", 0.93, self.engine, self.name)


def run_with(ctx, engine):
    return ocr.analyze(ctx.inputs.frames, ctx.manifest(), ctx.image, ctx.asset, engine, ctx.inputs.camera_positions)


def test_sample_pixels_inverts_jpeg_mapping():
    pts = np.array([[0, 0, 0, *jpeg_to_sensor_uv(123.0, 456.0, 480, 640)]])
    np.testing.assert_allclose(sample_pixels(pts, 480, 640), [[123.0, 456.0]])


def test_fit_plane_rejects_outliers_and_collinear_points():
    rng = np.random.default_rng(0)
    xy = rng.uniform(-0.3, 0.3, (60, 2))
    wall = np.column_stack((xy[:, 0], 2.0 + xy[:, 1], np.full(60, -2.0) + rng.normal(0, 0.002, 60)))
    wall[:5, 2] += 0.5                                     # a person in front of the sign
    _, normal, rms = fit_plane(wall)
    assert abs(normal[2]) > 0.999 and rms < 0.01
    assert fit_plane(np.column_stack((np.linspace(0, 1, 10), np.zeros(10), np.zeros(10)))) is None


def test_exit_sign_placed_on_north_wall_with_normal_toward_room(synthetic_ctx):
    engine = ocr.OcrEngine(PlateDetector(), [FakeRecognizer()], ocr.OcrConfig())
    results, summary, notices = run_with(synthetic_ctx, engine)
    assert len(results) == 1 and notices == []
    sign = results[0]
    assert sign["text"] == "EXIT" and sign["engine"] == "opencv_dnn" and sign["frame_id"] == "f0"
    assert sign["id"] == "text-f0-000" and sign["language"] == "en" and sign["script"] == "Latn"
    np.testing.assert_allclose(sign["position_m"], package.TRUTH["sign_center_m"], atol=0.08)
    np.testing.assert_allclose(sign["normal_m"], [0, 0, 1], atol=0.02)
    assert sign["depth_samples"] >= 8
    assert len(sign["quad_px"]) == 4 and sign["image_size_px"] == [480, 640]
    assert summary["placed_in_3d"] == 1 and summary["keyframes_examined"] == 1
    json.dumps(results)


def test_normal_orientation_falls_back_to_camera_track(synthetic_ctx):
    frame = synthetic_ctx.inputs.frames[0]
    image = synthetic_ctx.image(frame.color_asset)
    height, width = image.shape[:2]
    quad = green_plate_quad(image)
    toward = place(quad, frame.points, width, height, np.array([0.0, 1.4, 0.0]))
    away = place(quad, frame.points, width, height, np.array([0.0, 1.4, -5.0]))
    assert toward.normal_m[2] > 0.98 and away.normal_m[2] < -0.98
    assert place(quad, np.zeros((0, 5)), width, height).position_m is None


def test_apple_vision_observations_are_ingested_and_fused(synthetic_ctx):
    image = synthetic_ctx.image("f0.color.jpg")
    x, y, w, h = cv2.boundingRect(green_plate_quad(image))
    vision = {"schema_version": 1, "engine": "apple_vision", "observations": [
        {"frame_id": "f0", "image_asset": "f0.ocr.jpg", "image_size_px": [1440, 1920], "text": "EXIT",
         "confidence": 0.99, "bbox_norm": [x / 480, y / 640, w / 480, h / 640], "languages": ["en-US"]},
        {"frame_id": "f0", "image_asset": "f0.ocr.jpg", "image_size_px": [1440, 1920], "text": "Fire Door Keep Shut",
         "confidence": 0.8, "bbox_norm": [0.05, 0.9, 0.3, 0.03], "languages": ["en-US"]},
    ]}
    files = package.members(package.build())
    files["text-observations.json"] = json.dumps(vision).encode()
    ctx = ScanContext(synthetic_ctx.scan_id, synthetic_ctx.inputs, MemorySource(synthetic_ctx.manifest(), files))
    engine = ocr.OcrEngine(PlateDetector(), [FakeRecognizer()], ocr.OcrConfig())
    results, summary, _ = run_with(ctx, engine)
    assert summary["apple_vision_observations"] == 2 and summary["fused_with_apple_vision"] == 1
    fused = next(r for r in results if r["text"] == "EXIT")
    assert fused["engine"] == "apple_vision" and fused["language"] == "en-US"
    assert {r["engine"] for r in fused["readings"]} == {"apple_vision", "opencv_dnn"}
    np.testing.assert_allclose(fused["position_m"], package.TRUTH["sign_center_m"], atol=0.08)
    vision_only = next(r for r in results if r["text"] == "Fire Door Keep Shut")
    assert vision_only["engine"] == "apple_vision" and vision_only["bbox_px"][2] == 432
    assert summary["engines"] == ["apple_vision", "opencv_dnn"]


def test_image_jobs_prefer_ocr_stills():
    frames = [Frame("f0", np.zeros((0, 5)), "f0.color.jpg"), Frame("f1", np.zeros((0, 5)), "f1.color.jpg"),
              Frame("f2", np.zeros((0, 5)), "f2.color.jpg")]
    manifest = {
        "observations": [{"id": "f0", "rgb_asset": "f0.color.jpg", "ocr_asset": "f0.ocr.jpg"},
                         {"id": "f1", "rgb_asset": "f1.color.jpg"},
                         {"id": "f2", "rgb_asset": "f2.color.jpg"}],
        "assets": [{"path": "f0.ocr.jpg"}, {"path": "f1.ocr.jpg"}, {"path": "f9.ocr.jpg"}],
    }
    jobs = [(j.frame_id, j.image_asset, j.kind) for j in ocr.image_jobs(frames, manifest)]
    assert jobs == [("f0", "f0.ocr.jpg", "ocr_still"), ("f1", "f1.ocr.jpg", "ocr_still"),
                    ("f2", "f2.color.jpg", "keyframe"), ("f9", "f9.ocr.jpg", "ocr_still")]
    assert [j.image_asset for j in ocr.image_jobs(frames, None)] == ["f0.color.jpg", "f1.color.jpg", "f2.color.jpg"]


def test_offline_without_tesseract_reports_regions_with_notice(synthetic_ctx, tmp_path, monkeypatch):
    monkeypatch.setattr("inview_worker.ocr.recognize.shutil.which", lambda name: None)
    synthetic_ctx.config["ocr"] = {"model_dir": str(tmp_path)}
    result = TextStage().run(synthetic_ctx)
    assert any("No text recognizer" in n for n in result.notices)
    assert any("OCR models unavailable" in n for n in result.notices)
    assert result.summary["detector"] == "mser" and result.summary["recognizers"] == []
    for item in result.products["text"].json:
        assert item["text"] == "" and item["engine"] == "opencv_mser"
    assert list(tmp_path.iterdir()) == []                  # nothing was downloaded


def test_tesseract_fallback_is_used_when_models_are_missing(tmp_path):
    class FakeTesseract:
        engine = name = "tesseract"
        available = True

        def recognize(self, crop):
            return Reading("EXIT", 0.8, "tesseract", "tesseract")

    store = ocr.ModelStore(tmp_path, allow_download=False)
    engine = ocr.OcrEngine.build(store, ocr.OcrConfig(), tesseract=FakeTesseract())
    assert engine.detector.name == "mser" and engine.engine_names == ["tesseract"]
    assert any("MSER fallback" in n for n in engine.notices)


def test_stage_without_frames_or_manifest():
    ctx = ScanContext("json-only", ScanInputs("json-only"))
    ctx.config["ocr"] = {"download": False}
    analysis = runner.run(ctx, [TextStage()])
    assert analysis["stages"]["text"]["status"] == "ok" and analysis["text"] == []
    assert any("no text was read" in n for n in analysis["notices"])


def test_output_is_deterministic(synthetic_ctx, synthetic_archive):
    from inview_worker.synthetic import offline
    engine = ocr.OcrEngine(PlateDetector(), [FakeRecognizer()], ocr.OcrConfig())
    first = run_with(synthetic_ctx, engine)[0]
    second = run_with(offline.context_from_archive(synthetic_archive), engine)[0]
    assert first == second


# --- Real OpenCV DNN models (only when cached) -------------------------------------------------

@needs_models
def test_real_models_read_the_synthetic_exit_sign(synthetic_ctx):
    result = TextStage().run(synthetic_ctx)
    texts = result.products["text"].json
    exit_sign = next(t for t in texts if t["text"].upper() == "EXIT")
    assert exit_sign["engine"] == "opencv_dnn" and exit_sign["detector"] == "db_ppocrv3"
    np.testing.assert_allclose(exit_sign["position_m"], package.TRUTH["sign_center_m"], atol=0.15)
    np.testing.assert_allclose(exit_sign["normal_m"], [0, 0, 1], atol=0.05)


def _scene_with_signs() -> tuple[np.ndarray, list[str]]:
    scene = np.full((960, 1280, 3), 190, np.uint8)
    signs = [("EXIT", 3.0, 0, (380, 200), (40, 160, 30), (255, 255, 255)),
             ("Room 204", 2.0, 15, (900, 260), (235, 235, 235), (30, 30, 30)),
             ("Restrooms", 1.6, -20, (360, 640), (200, 120, 20), (255, 255, 255)),
             ("Elevator", 1.8, 0, (930, 720), (240, 240, 240), (10, 10, 10))]
    for text, scale, angle, center, plate, ink in signs:
        (w, h), base = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, scale, int(2 * scale))
        patch = np.full((h + base + 30, w + 40, 3), plate, np.uint8)
        cv2.putText(patch, text, (20, h + 15), cv2.FONT_HERSHEY_SIMPLEX, scale, ink, int(2 * scale), cv2.LINE_AA)
        matrix = cv2.getRotationMatrix2D((patch.shape[1] / 2, patch.shape[0] / 2), angle, 1.0)
        matrix[:, 2] += np.array(center) - np.array([patch.shape[1] / 2, patch.shape[0] / 2])
        mask = cv2.warpAffine(np.full(patch.shape[:2], 255, np.uint8), matrix, (1280, 960))
        warped = cv2.warpAffine(patch, matrix, (1280, 960), flags=cv2.INTER_CUBIC)
        scene[mask > 0] = warped[mask > 0]
    return scene, [s[0] for s in signs]


@needs_models
def test_real_models_read_rotated_signs():
    engine = ocr.OcrEngine.build(ocr.ModelStore(allow_download=False))
    scene, expected = _scene_with_signs()
    read = {reading.text.lower() for _, reading in engine.read(scene)}
    for text in expected:
        assert text.lower() in read, (text, read)


def test_engine_config_from_dict():
    config = ocr.OcrConfig.from_dict({"recognizers": ["crnn_en"], "long_sides": [640], "unknown": 1})
    assert config.recognizers == ("crnn_en",) and config.long_sides == (640,)
    assert ocr_engine.OcrConfig.from_dict(None) == ocr.OcrConfig()

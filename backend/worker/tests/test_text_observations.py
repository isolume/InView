"""Script/language heuristics, Apple Vision ingest and cross-engine fusion."""
import json

import numpy as np
import pytest

from inview_worker.ocr.language import detect_language, detect_script
from inview_worker.ocr.observations import Observation, fuse, parse_vision


@pytest.mark.parametrize("text,script,language", [
    ("EXIT", "Latn", "en"),
    ("Salida de emergencia", "Latn", "es"),
    ("Sortie", "Latn", "fr"),
    ("Notausgang", "Latn", "de"),
    ("Room 204", "Latn", "en"),
    ("Zxqv", "Latn", None),
    ("出口", "Hani", "zh"),
    ("非常口", "Hani", "zh"),
    ("トイレ", "Kana", "ja"),
    ("非常口 トイレ", "Jpan", "ja"),
    ("출구", "Hang", "ko"),
    ("مخرج", "Arab", "ar"),
    ("निकास", "Deva", "hi"),
    ("Выход", "Cyrl", "ru"),
    ("1234", None, None),
])
def test_script_and_language(text, script, language):
    assert detect_script(text) == script
    assert detect_language(text) == language


def test_language_hints_win():
    assert detect_language("EXIT", hints=["en_US"]) == "en-US"
    assert detect_language("Salida", hints=["es-MX", "en-US"]) == "es-MX"


VISION = {
    "schema_version": 1,
    "engine": "apple_vision",
    "observations": [
        {"frame_id": "f0", "image_asset": "f0.ocr.jpg", "image_size_px": [1440, 1920], "text": "EXIT",
         "confidence": 1.0, "bbox_norm": [0.5, 0.25, 0.1, 0.05], "languages": ["en-US"]},
        {"frame_id": "f0", "image_asset": "f0.ocr.jpg", "image_size_px": [1440, 1920], "text": " 出口 ",
         "confidence": 0.5, "bbox_norm": [0.1, 0.8, 0.2, 0.05], "languages": ["zh-Hans"]},
        {"frame_id": "f0", "image_size_px": [1440, 1920], "text": "", "bbox_norm": [0, 0, 0.1, 0.1]},
        {"frame_id": "f1", "text": "missing size", "bbox_norm": [0, 0, 0.1, 0.1]},
    ],
}


def test_parse_vision_converts_normalized_boxes():
    observations, skipped = parse_vision(json.dumps(VISION).encode())
    assert skipped == 2 and len(observations) == 2
    exit_sign = observations[0]
    assert exit_sign.engine == "apple_vision" and exit_sign.frame_id == "f0"
    assert exit_sign.bbox_px == [720, 480, 144, 96]
    assert exit_sign.languages == ["en-US"]
    assert observations[1].text == "出口"
    assert parse_vision(None) == ([], 0)
    assert parse_vision(b"not json") == ([], 1)


def box_obs(frame, size, xywh, text, confidence, engine):
    x, y, w, h = xywh
    quad = np.array([[x, y + h], [x, y], [x + w, y], [x + w, y + h]], np.float32)
    return Observation(frame, f"{frame}.jpg", size, quad, text, confidence, engine, engine)


def test_fusion_matches_by_normalized_iou_across_resolutions():
    # DNN read the 480x640 keyframe, Vision the 1440x1920 still of the same frame.
    dnn = [box_obs("f0", (480, 640), (240, 160, 48, 32), "EXlT", 0.7, "opencv_dnn"),
           box_obs("f0", (480, 640), (10, 10, 50, 20), "LOBBY", 0.9, "opencv_dnn"),
           box_obs("f1", (480, 640), (240, 160, 48, 32), "EXIT", 0.8, "opencv_dnn")]
    vision, _ = parse_vision(json.dumps(VISION).encode())
    merged, fused = fuse(dnn, vision)
    assert fused == 1 and len(merged) == 4
    exit_sign = merged[0]
    assert exit_sign.text == "EXIT" and exit_sign.engine == "apple_vision"
    assert [(r["engine"], r["text"]) for r in exit_sign.readings] == [("apple_vision", "EXIT"), ("opencv_dnn", "EXlT")]
    assert exit_sign.languages == ["en-US"]


def test_fusion_prefers_text_then_confidence():
    region = box_obs("f0", (100, 100), (10, 10, 40, 20), "", 0.95, "opencv_mser")
    reading = box_obs("f0", (100, 100), (12, 10, 40, 20), "EXIT", 0.4, "apple_vision")
    merged, fused = fuse([region], [reading])
    assert fused == 1 and merged[0].text == "EXIT"
    strong = box_obs("f0", (100, 100), (12, 10, 40, 20), "EXIT", 0.95, "opencv_dnn")
    weak = box_obs("f0", (100, 100), (10, 10, 40, 20), "EXT", 0.5, "apple_vision")
    merged, _ = fuse([strong], [weak])
    assert merged[0].engine == "opencv_dnn" and len(merged[0].readings) == 2


def _vision(*items):
    return json.dumps({"schema_version": 1, "engine": "apple_vision", "observations": list(items)}).encode()


def _item(**overrides):
    item = {"frame_id": "f0", "image_asset": "f0.color.jpg", "image_size_px": [480, 640], "text": "EXIT",
            "confidence": 0.9, "bbox_norm": [0.25, 0.25, 0.5, 0.25], "languages": ["en"]}
    item.update(overrides)
    return item


@pytest.mark.parametrize("bad", [
    {"bbox_norm": [float("nan"), 0.25, 0.5, 0.25]},
    {"bbox_norm": [0.25, 0.25, float("inf"), 0.25]},
    {"bbox_norm": [0.25, 0.25, 0.5]},
    {"confidence": float("nan")},
    {"confidence": float("-inf")},
    {"image_size_px": [float("inf"), 640]},
    {"bbox_norm": [1.2, 0.25, 0.5, 0.25]},      # entirely right of the image: empty after clipping
    {"bbox_norm": [0.25, -0.5, 0.5, 0.2]},      # entirely above the image
    {"bbox_norm": [0.25, 0.25, 0.0005, 0.25]},  # under one pixel wide
    {"image_orientation": "upside_down"},
])
def test_vision_rejects_non_finite_empty_or_unknown_geometry(bad):
    found, skipped = parse_vision(_vision(_item(**bad), _item(text="KEEP")))
    assert [o.text for o in found] == ["KEEP"] and skipped == 1


def test_vision_nan_from_raw_json_tokens_is_rejected():
    raw = b'{"observations":[{"frame_id":"f0","image_size_px":[480,640],"text":"X","confidence":NaN,"bbox_norm":[0.1,0.1,0.2,0.2]}]}'
    assert parse_vision(raw) == ([], 1)


def test_vision_orientation_and_sensor_box_agree():
    upright = _item(image_orientation="upright_rotated_right_from_sensor",
                    bbox_sensor_norm=[0.25, 0.25, 0.25, 0.5])
    sensor_only = _item(image_orientation="sensor_native", bbox_norm=None, bbox_sensor_norm=[0.25, 0.25, 0.25, 0.5])
    legacy = _item()
    boxes = [parse_vision(_vision(i))[0][0].bbox_norm for i in (upright, sensor_only, legacy)]
    for box in boxes:
        assert box == pytest.approx((0.25, 0.25, 0.5, 0.25), abs=1 / 480)

"""Signage unit: pictograms, arrows, braille, contrast, placement, i18n and sign screening."""
import cv2
import numpy as np
import pytest

from inview_worker.contracts import PlaceCategory, Thresholds
from inview_worker.core import MemorySource, ScanContext
from inview_worker.inputs import Frame, ScanInputs
from inview_worker.pipeline import analyze as run_pipeline
from inview_worker.signage import arrows, assess, braille, gallery, i18n, legend, pictograms
from inview_worker.signage.analyze import analyze
from inview_worker.signage.placement import LocalFrame, local_frame, map_direction
from inview_worker.synthetic import package

SPECS = {spec.name: spec for spec in gallery.GALLERY}
ALLOWED_CATEGORIES = {c.value for c in PlaceCategory} | {"directional", "informational"}


def expected_pictograms(spec):
    if spec.expected_pictograms is not None:
        return sorted(spec.expected_pictograms)
    return sorted(s.partition(":")[0] for s in spec.symbols if not s.startswith("arrow_"))


# --- pictograms and arrows --------------------------------------------------------------------

@pytest.mark.parametrize("name", sorted(pictograms.RENDERERS))
def test_every_template_matches_itself_after_downsampling(name):
    for mirrored in ((False, True) if name in pictograms.MIRRORED else (False,)):
        mask = cv2.resize(pictograms.render(name, mirrored), (36, 36), interpolation=cv2.INTER_AREA)
        mask = (cv2.resize(mask, (90, 90)) > 127).astype(np.uint8) * 255
        best = pictograms.classify(mask)[0]
        assert best.name == name and best.score > 0.8


def test_restroom_figures_are_told_apart_under_roll_and_mirroring():
    for name in pictograms.RESTROOM_FIGURES:
        for mirrored in (False, True):
            for roll in (-8, 0, 8):
                mask = pictograms.render(name, mirrored)
                mask = cv2.warpAffine(mask, cv2.getRotationMatrix2D((64, 64), roll, 1.0), (128, 128))
                mask = (cv2.resize(mask, (40, 40), interpolation=cv2.INTER_AREA) > 127).astype(np.uint8) * 255
                assert pictograms.restroom_figure(mask) == name


@pytest.mark.parametrize("direction", sorted(pictograms.ARROW_ANGLES))
def test_arrow_direction_is_recovered_in_eight_directions(direction):
    for side in (128, 48):
        mask = (cv2.resize(pictograms.arrow(pictograms.ARROW_ANGLES[direction]), (side, side)) > 127).astype(np.uint8) * 255
        found = arrows.detect(mask)
        assert found is not None and found.name == direction
        assert abs((found.angle_deg - pictograms.ARROW_ANGLES[direction] + 180) % 360 - 180) < 6


def test_letters_and_other_pictograms_are_not_arrows():
    for name in pictograms.RENDERERS:
        count, labels = cv2.connectedComponents(pictograms.render(name))
        for label in range(1, count):
            assert arrows.detect((labels == label).astype(np.uint8) * 255) is None, name
    for char in "ABCDEFGHJKLMNOPQRSTUVWXYZ0234567<>":
        mask = np.zeros((80, 80), np.uint8)
        cv2.putText(mask, char, (10, 65), cv2.FONT_HERSHEY_DUPLEX, 2.2, 255, 5)
        assert arrows.detect(mask) is None, char


@pytest.mark.parametrize("variant", gallery.VARIANTS, ids=lambda v: v.name)
@pytest.mark.parametrize("name", sorted(SPECS))
def test_gallery_sign_is_read_and_categorised(name, variant):
    spec = SPECS[name]
    image, quad = gallery.render_scene(spec, variant)
    plate, reading = gallery.read_scene(image)
    assert plate is not None, "plate not found"
    x, y, w, h = plate.bbox
    cx, cy = quad.mean(axis=0)
    assert x <= cx <= x + w and y <= cy <= y + h
    names = assess.resolve_pictograms([p["name"] for p in reading.pictograms], [a["image_direction"] for a in reading.arrows])
    assert sorted(names) == expected_pictograms(spec)
    assert sorted(a["image_direction"] for a in reading.arrows) == sorted(spec.expected_arrows)
    category = assess.infer_category(names, [a["image_direction"] for a in reading.arrows], plate.color, [],
                                     bool(reading.text_lines))[0]
    assert category == spec.category and category in ALLOWED_CATEGORIES
    assert bool(reading.braille) == spec.braille


def test_gallery_confusion_report_is_clean():
    report = gallery.evaluate(gallery.VARIANTS[:2])
    assert report["category_accuracy"] == 1.0
    assert all(a == b for pair in report["pictogram_confusion"] for a, b in [pair.split(" -> ")])


def test_rectangles_without_legend_are_not_signs():
    image = np.full((640, 480, 3), 180, np.uint8)
    cv2.rectangle(image, (60, 80), (420, 300), (235, 235, 235), -1)       # blank white board
    cv2.rectangle(image, (100, 380), (300, 600), (90, 60, 40), -1)         # door-like panel
    rng = np.random.default_rng(1)
    image[400:560, 330:450] = rng.integers(0, 255, (160, 120, 3), dtype=np.uint8)  # busy poster
    frame = Frame("f", np.zeros((0, 5)), "f.png")
    signs, examined = analyze([frame], lambda _: image, ocr=False)
    assert examined == 1 and [s for s in signs if s["kind"] != "text_region"] == []


# --- braille and contrast ---------------------------------------------------------------------

def test_braille_dot_lattice_is_detected_only_where_present():
    with_braille = gallery.render_plate(SPECS["room_braille"])
    without = gallery.render_plate(SPECS["exit_text"])
    found = braille.detect(cv2.cvtColor(with_braille, cv2.COLOR_BGR2GRAY))
    assert found and found["dots"] >= 12 and found["rows"] == 3
    assert braille.detect(cv2.cvtColor(without, cv2.COLOR_BGR2GRAY)) is None
    rng = np.random.default_rng(0)
    speckle = np.full((150, 300), 40, np.uint8)
    for x, y in rng.integers(10, 140, (40, 2)):
        cv2.circle(speckle, (int(x * 2), int(y)), 3, 230, -1)
    assert braille.detect(speckle) is None


def test_wcag_contrast_ratio_matches_reference_values():
    assert legend.contrast_ratio((255, 255, 255), (0, 0, 0)) == pytest.approx(21.0)
    assert legend.contrast_ratio((119, 119, 119), (255, 255, 255)) == pytest.approx(4.48, abs=0.01)
    assert legend.contrast_ratio((0, 0, 255), (255, 255, 255)) == pytest.approx(4.0, abs=0.01)  # pure red


def test_two_cluster_legend_split_measures_plate_contrast():
    plate = gallery.render_plate(SPECS["low_contrast"])
    split = legend.split(plate)
    assert split.polarity == "dark_on_light" and split.contrast_ratio == pytest.approx(
        legend.contrast_ratio((165, 165, 165), (232, 232, 232)), abs=0.15)
    plate = gallery.render_plate(SPECS["elevator"])
    assert legend.split(plate).contrast_ratio > 15


# --- placement --------------------------------------------------------------------------------

def wall_frame(width=480, height=640, z=-2.0, px_per_m=200.0, top_y=2.6, roll=False):
    """Depth samples on a wall at `z`, image right = +X and image down = −Y (portrait keyframe).

    With `roll`, the keyframe is landscape: image right = −Y and image down = −X.
    """
    py, px = np.mgrid[0:height:8, 0:width:8].astype(np.float64)
    px, py = px.ravel() + 0.5, py.ravel() + 0.5
    if roll:
        x, y = -(py - height / 2) / px_per_m, top_y - px / px_per_m
    else:
        x, y = (px - width / 2) / px_per_m, top_y - py / px_per_m
    u, v = py / height, 1.0 - px / width
    return Frame("f", np.column_stack((x, y, np.full(x.size, z), u, v)), "f.png")


def test_local_frame_recovers_the_wall_plane_and_scale():
    local = local_frame((200, 200, 80, 60), wall_frame(), 480, 640)
    assert local.normal == pytest.approx([0, 0, 1], abs=1e-6)
    assert local.meters_per_px_vertical() == pytest.approx(1 / 200, rel=1e-3)
    assert local.world(240, 0)[1] == pytest.approx(2.6, abs=1e-3)


@pytest.mark.parametrize("roll", [False, True])
def test_arrow_directions_map_to_the_floor_plan(roll):
    local = local_frame((200, 200, 80, 60), wall_frame(roll=roll), 480, 640)
    # Image directions as they appear in the keyframe for "right along the wall", "up the wall", ...
    world_right, world_up = ((0, -1), (-1, 0)) if roll else ((1, 0), (0, -1))
    world_right = np.array(world_right, float)
    world_up = np.array(world_up, float)
    assert map_direction(local, world_right) == ([1.0, 0.0], "right")
    assert map_direction(local, -world_right) == ([-1.0, 0.0], "left")
    assert map_direction(local, world_up) == ([0.0, -1.0], "ahead")       # into the wall's facing direction
    assert map_direction(local, -world_up) == (None, "down_or_here")
    diagonal, meaning = map_direction(local, (world_up + world_right) / np.sqrt(2))
    assert meaning == "ahead_right" and diagonal == pytest.approx([0.707, -0.707], abs=1e-3)


def test_ceiling_sign_arrows_stay_in_the_plane():
    local = LocalFrame(np.array([[0.005, 0, -1], [0, 0, 2.5], [0, 0.005, -1]]), np.array([0, -1.0, 0]), 0.0, 20)
    assert map_direction(local, (0, -1)) == ([0.0, -1.0], "along_plane")


# --- assessment and i18n ----------------------------------------------------------------------

def test_minimum_character_height_follows_ada_703_5_5():
    assert assess.min_character_height_m(1.5, 1.0) == pytest.approx(0.015875)
    assert assess.min_character_height_m(2.0, 3.0) == pytest.approx(0.0508)
    # 70–120 in band, 25 ft away: 2 in + 10 ft × 1/8 in.
    assert assess.min_character_height_m(2.0, 25 * 0.3048) == pytest.approx((2 + 10 / 8) * 0.0254)
    assert assess.min_character_height_m(3.5, 6.0) == pytest.approx(3 * 0.0254)


def test_tactile_range_issues_name_the_measured_height():
    low, high = Thresholds.TACTILE_SIGN_BASELINE_M
    assert assess.tactile_range_issues(1.3, 1.45, 1.4, "text baseline") == []
    [above] = assess.tactile_range_issues(1.9, 1.9, 2.0, "text baseline")
    assert "mounted 2.00 m" in above and "above" in above and f"{low:.2f}–{high:.2f}" in above
    [below] = assess.tactile_range_issues(1.0, 1.1, 1.05, "text baseline")
    assert "below" in below


def test_category_inference_prefers_pictograms_then_text_then_arrows():
    assert assess.infer_category(["exit_running_person"], ["right"], "green", [], False)[0] == "emergency_exit"
    assert assess.infer_category(["man", "woman", "wheelchair"], [], "blue", [], False)[0] == "accessible_restroom"
    assert assess.infer_category([], [], "light", ["restroom"], True)[0] == "restroom"
    assert assess.infer_category(["wheelchair"], ["left"], "blue", [], False)[0] == "directional"
    assert assess.infer_category([], [], "green", [], True)[0] == "exit"
    assert assess.infer_category([], [], "light", [], True)[0] == "informational"
    assert assess.resolve_pictograms(["stairs"], ["up_right"]) == ["stairs_up"]
    assert assess.resolve_pictograms(["stairs"], []) == ["stairs"]


def test_scripts_languages_and_lexicon():
    assert i18n.scripts("出口 EXIT") == ["Hani", "Latn"]
    assert i18n.scripts("화장실") == ["Hang"]
    assert i18n.languages("SALIDA") == ["es"]
    assert i18n.languages("Toilets / Aseos") == ["en", "es"]
    assert i18n.languages("anything", "fr-CA") == ["fr"]
    assert [h[1] for h in i18n.lexicon_hits("EMERGENCY EXIT")] == ["emergency_exit"]
    assert [h[1] for h in i18n.lexicon_hits("非常口")] == ["emergency_exit"]
    assert i18n.lexicon_hits("EXITING") == []


# --- end to end over frames -------------------------------------------------------------------

def scene_frame(spec_name, frame_id="f", variant=gallery.VARIANTS[0]):
    image, quad = gallery.render_scene(SPECS[spec_name], variant)
    frame = wall_frame()
    return Frame(frame_id, frame.points, f"{frame_id}.png"), image, quad


def test_bilingual_restroom_sign_links_text_and_screens_accessibility():
    frame, image, quad = scene_frame("accessible_restroom")
    x0, y0 = quad.min(axis=0).astype(int)
    x1, y1 = quad.max(axis=0).astype(int)
    texts = [
        {"id": "t-en", "text": "Restroom", "language": "en", "script": "Latn", "confidence": 0.9, "engine": "test",
         "frame_id": "f", "bbox_px": [int(x0 + 10), int(y0 + 10), int(x1 - x0 - 20), 30]},
        {"id": "t-es", "text": "Baños", "confidence": 0.9, "engine": "test", "frame_id": "f",
         "bbox_px": [int(x0 + 10), int(y1 - 40), int(x1 - x0 - 20), 30]},
        {"id": "t-other", "text": "EXIT", "frame_id": "other", "bbox_px": [int(x0), int(y0), 50, 50]},
    ]
    signs, _ = analyze([frame], lambda _: image, texts=texts, floor_height=0.0,
                       cameras={"f": np.array([0.0, 1.5, 0.5])}, ocr=False)
    [sign] = [s for s in signs if s["kind"] != "text_region"]
    assert sign["category"] == "accessible_restroom" and sign["kind"] == "accessibility_sign_candidate"
    assert sign["pictograms"] == ["man", "wheelchair", "woman"]
    assert sign["text_ids"] == ["t-en", "t-es"] and sign["languages"] == ["en", "es"]
    assert sign["i18n"]["multilingual"] and sign["i18n"]["language_independent"]
    assert sign["contrast_ratio"] > 4.5 and sign["observation_count"] == 1
    # Plate center sits at image row ~269 -> 2.6 − 269/200 ≈ 1.25 m on the synthetic wall.
    assert sign["mounting_height_m"] == pytest.approx(2.6 - quad[:, 1].mean() / 200, abs=0.05)
    assert sign["viewing_distance_m"] == pytest.approx(np.linalg.norm(np.subtract(sign["position_m"], [0, 1.5, 0.5])), abs=1e-3)
    assert all(s in {"Latn"} for s in sign["scripts"])
    assert not any("text-only" in issue for issue in sign["issues"])


def test_directional_sign_arrow_points_along_the_wall():
    frame, image, _ = scene_frame("arrow_left")
    signs, _ = analyze([frame], lambda _: image, floor_height=0.0, ocr=False)
    [sign] = signs
    assert sign["category"] == "directional"
    assert sign["arrows"][0]["direction_xz"] == pytest.approx([-1.0, 0.0], abs=0.02)
    assert sign["arrows"][0]["meaning"] == "left"


def test_low_contrast_and_text_only_issues():
    frame, image, _ = scene_frame("low_contrast")
    signs, _ = analyze([frame], lambda _: image, floor_height=0.0, ocr=False)
    [sign] = [s for s in signs if s["kind"] != "text_region"]
    assert sign["contrast_ratio"] < 3
    assert any(issue.startswith("low contrast") and "< 3:1" in issue for issue in sign["issues"])
    assert any(issue.startswith("text-only sign") for issue in sign["issues"])


def test_observations_from_two_frames_merge_into_one_sign():
    frame_a, image_a, _ = scene_frame("emergency_exit_right", "a")
    frame_b, image_b, _ = scene_frame("emergency_exit_right", "b", gallery.VARIANTS[1])
    images = {"a.png": image_a, "b.png": image_b}
    signs, examined = analyze([frame_a, frame_b], images.get, floor_height=0.0, ocr=False)
    plates = [s for s in signs if s["kind"] != "text_region"]
    assert examined == 2 and len(plates) == 1
    assert plates[0]["observation_count"] == 2 and {o["frame_id"] for o in plates[0]["observations"]} == {"a", "b"}
    assert plates[0]["category"] == "emergency_exit" and plates[0]["arrows"][0]["direction_xz"] == pytest.approx([1, 0], abs=0.05)


def test_signs_product_is_deterministic():
    frame, image, _ = scene_frame("stairs_up")
    first = analyze([frame], lambda _: image, floor_height=0.0, ocr=False)
    second = analyze([frame], lambda _: image, floor_height=0.0, ocr=False)
    assert first == second


def test_synthetic_package_exit_sign_is_found_measured_and_screened(synthetic_ctx):
    result = run_pipeline(synthetic_ctx)
    assert result["stages"]["signs"]["status"] == "ok"
    exits = [s for s in result["signs"] if s["category"] == "exit"]
    assert len(exits) == 1
    sign = exits[0]
    assert sign["kind"] == "exit_sign_candidate" and sign["color"] == "green" and sign["id"] == "sign-000"
    assert np.linalg.norm(np.subtract(sign["position_m"], package.TRUTH["sign_center_m"])) < 0.1
    assert sign["mounting_height_m"] == pytest.approx(2.0, abs=0.05)
    assert sign["heights_m"]["bottom"] == pytest.approx(package.SIGN_Y[0], abs=0.03)
    assert sign["heights_m"]["top"] == pytest.approx(package.SIGN_Y[1], abs=0.03)
    assert sign["normal_m"] == pytest.approx([0, 0, 1], abs=0.05)
    assert sign["contrast_ratio"] > 3
    assert any("above the 1.22–1.52 m tactile range" in issue for issue in sign["issues"])
    assert result["summary"]["signs"]["floor_height_source"] == "floor_map"
    # Studio reads these legacy fields.
    assert {"kind", "text", "position_m", "observation_count"} <= set(sign)


def test_merged_arrows_use_circular_angles_and_map_meaning():
    from inview_worker.signage.analyze import _merge_arrows

    def arrow(name, angle, meaning, xz):
        return {"image_direction": name, "angle_deg": angle, "meaning": meaning, "direction_xz": xz, "score": 0.9}

    records = [{"arrows": [arrow("right", 357.0, "unknown", None)]},
               {"arrows": [arrow("right", 1.0, "unknown", None)]},
               {"arrows": [arrow("right", 1.0, "right", [1.0, 0.0])]},
               {"arrows": [arrow("up", 90.0, "right", [1.0, 0.0])]}]  # same arrow, landscape keyframe
    merged = _merge_arrows(records)
    by_meaning = {m["meaning"]: m for m in merged}
    assert set(by_meaning) == {"right", "unknown"} and by_meaning["right"]["direction_xz"] == [1.0, 0.0]
    unknown = by_meaning["unknown"]
    assert unknown["image_direction"] == "right" and unknown["angle_deg"] == 359.0  # circular mean of 357 and 1


def test_overhead_exit_sign_gets_a_note_not_a_tactile_issue():
    sign = {"kind": "exit_sign_candidate", "category": "exit", "pictograms": ["exit_running_person"], "text": "EXIT",
            "mounting_height_m": 2.25, "heights_m": {"bottom": 2.12, "top": 2.38}}
    issues, notes = assess.assess(sign)
    assert not any("tactile range" in i for i in issues) and any("Overhead sign" in n for n in notes)
    sign["heights_m"] = {"bottom": 1.85, "top": 2.1}
    issues, _ = assess.assess(sign)
    assert any("tactile range" in i for i in issues)


def test_stage_without_keyframes_reports_a_notice():
    result = run_pipeline(ScanContext("empty", ScanInputs("empty")))
    assert result["signs"] == [] and any("No RGB keyframes" in n for n in result["notices"])


def test_stage_uses_roomplan_floor_without_floor_map_and_upstream_text():
    from inview_worker.stages.signs import SignsStage
    from inview_worker.core import Product

    frame, image, quad = scene_frame("exit_text")
    inputs = ScanInputs("s", frames=[frame])
    ctx = ScanContext("s", inputs, MemorySource(None, {"f.png": cv2.imencode(".png", image)[1].tobytes()}))
    x0, y0 = quad.min(axis=0).astype(int)
    ctx.products["text"] = Product([{"id": "t1", "text": "SALIDA", "frame_id": "f",
                                     "bbox_px": [int(x0) + 5, int(y0) + 5, 100, 40]}])
    result = SignsStage().run(ctx)
    [sign] = [s for s in result.products["signs"].json if s["kind"] != "text_region"]
    assert sign["text"] == "SALIDA" and sign["languages"] == ["es"] and sign["category"] == "exit"
    assert result.summary["floor_height_source"] is None and sign["mounting_height_m"] is None

"""A scan taken on an upper floor, a mezzanine or a basement is the same scan lifted or lowered.

ARKit's origin is wherever the session started, so absolute Y is arbitrary. Every hazard, the height map
and the step-free profiles must therefore be identical when all geometry moves by a constant dy.
"""
import copy

import numpy as np
import pytest

from inview_worker import terrain
from test_hazards import (ROOM_TRACK, Mesh, flat_room, kinds, ramp_corridor, run, stair_corridor)

LIFTS = [3.7, 12.4, -2.8, 0.013]


def lifted(inputs, dy):
    out = copy.deepcopy(inputs)
    shift = np.array([0.0, dy, 0.0])
    out.mesh_vertices = out.mesh_vertices + shift
    out.points = out.points + shift if len(out.points) else out.points
    out.camera_positions = out.camera_positions + shift
    for item in [*out.surfaces, *out.objects]:
        item.matrix = item.matrix.copy()
        item.matrix[1, 3] += dy
    return out


def strip(hazards, dy=0.0):
    """Hazards with absolute heights removed, so lifted and original compare field by field."""
    cleaned = []
    for h in hazards:
        h = copy.deepcopy(h)
        for key in ("height_m", "elevation_m", "y_m", "top_y_m", "bottom_y_m"):
            h.pop(key, None)
        if "position_m" in h and len(h["position_m"]) == 3:
            h["position_m"] = [h["position_m"][0], h["position_m"][2]]
        cleaned.append(h)
    return cleaned


SCENES = {
    "flat": lambda: (flat_room(), ROOM_TRACK),
    "platform": lambda: (Mesh().floor(-2, 0.5, -2, 2).floor(0.5, 2, -2, 2, 0.15).walls(-2, 2, -2, 2)
                         .quad((0.5, 0, -2), (0.5, 0, 2), (0.5, 0.15, 2), (0.5, 0.15, -2)), ROOM_TRACK),
    "ramp": lambda: (ramp_corridor(1 / 15), [[0, 1.4, -2.5], [0, 1.6, (0.2 * 15) - 0.5]]),
    "stairs": lambda: (stair_corridor(), [[0, 1.4, -2.0], [0, 1.91, 1.5]]),
    "pit": lambda: (Mesh().floor(-2, 0.0, -2, 2).floor(0.0, 2, -2, 2, -0.5).walls(-2, 2, -2, 2),
                    [[-1.0, 1.4, 0.0], [1.0, 0.9, 0.0]]),
}


@pytest.mark.parametrize("dy", LIFTS)
@pytest.mark.parametrize("scene", sorted(SCENES))
def test_hazards_do_not_depend_on_absolute_height(scene, dy):
    mesh, track = SCENES[scene]()
    base = mesh.inputs(track)
    _, hm0, h0 = run(base)
    _, hm1, h1 = run(lifted(base, dy))
    assert kinds(h1) == kinds(h0), (scene, dy)
    for a, b in zip(strip(h0, 0), strip(h1, dy)):
        assert a["id"] == b["id"] and a["severity"] == b["severity"]
        relative = {k: v for k, v in a["measure"].items() if not k.endswith("_y_m")}
        assert {k: v for k, v in b["measure"].items() if not k.endswith("_y_m")} == pytest.approx(relative, abs=0.02)
        for key in (k for k in a["measure"] if k.endswith("_y_m")):  # absolute heights move with the lift
            assert b["measure"][key] == pytest.approx(a["measure"][key] + dy, abs=0.03), key
    assert hm1.floor_height == pytest.approx(hm0.floor_height + dy, abs=0.03)
    np.testing.assert_allclose(hm1.relative(), hm0.relative(), atol=0.03, equal_nan=True)
    assert hm1.measured == hm0.measured
    np.testing.assert_array_equal(np.isfinite(hm1.elevation), np.isfinite(hm0.elevation))


@pytest.mark.parametrize("dy", LIFTS)
def test_step_free_profile_does_not_depend_on_absolute_height(dy):
    mesh, track = SCENES["platform"]()
    base = mesh.inputs(track)
    _, hm0, _ = run(base)
    _, hm1, _ = run(lifted(base, dy))
    for start, end in (([-1.0, 0.0], [1.5, 0.0]), ([-1.5, -1.0], [-0.5, 1.0])):
        a, b = terrain.segment_profile(hm0, start, end), terrain.segment_profile(hm1, start, end)
        assert a["step_free"] == b["step_free"]
        assert a["max_level_change_m"] == pytest.approx(b["max_level_change_m"], abs=0.02)


# --- unprotected drops: a lower level that was seen, never walked -----------------------------------------

def balcony(drop: float, railing: bool = False) -> Mesh:
    """An upper deck (x < 0) with three walls; its +X side is open to a lower level `drop` metres down."""
    mesh = Mesh().floor(-3, 0, -2, 2).floor(0, 4, -2, 2, -drop)
    for a, b in (((-3, -2), (0, -2)), ((0, 2), (-3, 2)), ((-3, 2), (-3, -2))):
        mesh.quad((a[0], 0, a[1]), (b[0], 0, b[1]), (b[0], 2.6, b[1]), (a[0], 2.6, a[1]))
    if railing:
        mesh.quad((0, 0, -2), (0, 0, 2), (0, 1.0, 2), (0, 1.0, -2))
    return mesh


DECK_TRACK = [[x, 1.4, 0.0] for x in np.linspace(-2.5, -0.6, 6)]


@pytest.mark.parametrize("drop", [0.6, 1.0, 3.0, 4.5, 6.0, 12.0])
def test_open_edge_above_a_lower_level_is_a_drop_off_at_any_depth(drop):
    _, hm, hazards = run(balcony(drop).inputs(DECK_TRACK))
    assert kinds(hazards) == ["drop_off"], hazards
    edge = hazards[0]
    assert edge["severity"] == "barrier" and "unprotected_drop" in edge["issues"]
    assert edge["measure"]["rise_m"] == pytest.approx(drop, abs=0.1)
    assert edge["measure"]["length_m"] == pytest.approx(4.0, abs=0.6)
    assert edge["position_m"][0] == pytest.approx(0.0, abs=0.2)
    assert edge["down_direction_xz"][0] > 0.9
    # The lower level is not a walking surface: nothing routes down there.
    assert not np.isfinite(hm.sample(hm.elevation, [[2.0, 0.0]])[0])


@pytest.mark.parametrize("dy", [3.7, -2.8])
def test_drop_off_is_the_same_on_an_elevated_floor(dy):
    base = balcony(3.0).inputs(DECK_TRACK)
    _, _, a = run(base)
    _, _, b = run(lifted(base, dy))
    assert kinds(a) == kinds(b) == ["drop_off"]
    assert b[0]["measure"]["rise_m"] == pytest.approx(a[0]["measure"]["rise_m"], abs=0.02)
    assert b[0]["measure"]["upper_y_m"] == pytest.approx(a[0]["measure"]["upper_y_m"] + dy, abs=0.03)


def test_a_railing_or_wall_at_the_edge_protects_it():
    _, _, hazards = run(balcony(3.0, railing=True).inputs(DECK_TRACK))
    assert hazards == []


def test_walking_down_into_the_lower_level_is_not_double_reported():
    # The pit case from test_hazards: the camera is in the lower area, so the edge is a single drop_off.
    pit = Mesh().floor(-2, 0.0, -2, 2).floor(0.0, 2, -2, 2, -0.5).walls(-2, 2, -2, 2)
    _, _, hazards = run(pit.inputs([[-1.0, 1.4, 0.0], [1.0, 0.9, 0.0]]))
    assert kinds(hazards) == ["drop_off"]

"""Decoders for the Swift Codable spellings RoomPlan JSON can take."""
import numpy as np
import pytest

from inview_worker.roomplan.codable import angle_degrees, enum_case, identifier, matrix4, points3, snake, vector

M = np.array([[0, 0, 1, 2.0], [0, 1, 0, 1.5], [-1, 0, 0, -3.0], [0, 0, 0, 1]])


@pytest.mark.parametrize("encoded", [
    M.T.tolist(),                                    # Swift simd: four column vectors
    M.reshape(-1, order="F").tolist(),               # flat column-major (portable capture)
    M.tolist(),                                      # rows (non-Swift producers): detected via the affine row
    {"columns": M.T.tolist()},
    [{"x": c[0], "y": c[1], "z": c[2], "w": c[3]} for c in M.T.tolist()],
])
def test_matrix_layouts(encoded):
    assert np.allclose(matrix4(encoded), M)


@pytest.mark.parametrize("bad", [None, [1, 2, 3], [[1, 2], [3, 4]], [float("nan")] * 16, list(range(16)), "x"])
def test_unusable_matrices_are_none(bad):
    assert matrix4(bad) is None


def test_enum_spellings():
    assert enum_case({"door": {"isOpen": True}}) == ("door", {"isOpen": True})
    assert enum_case({"livingRoom": {}}) == ("living_room", {})
    assert enum_case("washerDryer") == ("washer_dryer", {})
    assert enum_case({"door": True}) == ("door", {"_0": True})
    assert enum_case({"rawValue": "diningRoom"}) == ("dining_room", {})
    assert enum_case(None) == (None, {}) and enum_case(3) == (None, {})


def test_vectors_points_angles_and_ids():
    assert vector([1, 2, 3, 1], 3).tolist() == [1, 2, 3]
    assert vector({"x": 1, "y": 2}, 2).tolist() == [1, 2]
    assert vector([1, True, 3], 3) is None and vector([1, 2], 3) is None
    assert points3([[0, 0, 0], "bad", [1, 2, 3]]).shape == (2, 3) and points3(None).shape == (0, 3)
    assert angle_degrees({"value": np.pi, "unit": {"symbol": "rad"}}) == pytest.approx(180)
    assert angle_degrees({"value": 90, "unit": {"symbol": "°"}}) == pytest.approx(90)
    assert angle_degrees(np.pi / 2) == pytest.approx(90) and angle_degrees("x") is None
    assert identifier(" ab-cd ") == "AB-CD" and identifier("") is None and identifier(5) is None
    assert snake("ChairArmType") == "chair_arm_type" and snake("TVStand") == "tv_stand"

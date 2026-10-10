"""Robust building reference from GPS/compass/barometer samples, and the `georef` stage."""
import json
import math

import numpy as np
import pytest

from inview_worker.contracts import ProductName
from inview_worker.core import MemorySource, ScanContext, runner
from inview_worker.geo import LocalProjection, reference
from inview_worker.geo.projection import offset_m
from inview_worker.geometry import matrix
from inview_worker.inputs import ScanInputs
from inview_worker.stages.georef import GeorefStage

ORIGIN = (33.7756, -84.3963)


def pose(x=0.0, y=1.4, z=0.0, yaw=0.0, pitch=0.0) -> list[float]:
    """Column-major map_from_camera: yaw counterclockwise about +Y, then pitch about camera X."""
    c, s = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
    cp, sp = math.cos(math.radians(pitch)), math.sin(math.radians(pitch))
    m = np.eye(4)
    m[:3, :3] = np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]]) @ np.array([[1, 0, 0], [0, cp, -sp], [0, sp, cp]])
    m[:3, 3] = [x, y, z]
    return m.reshape(-1, order="F").tolist()


def observation(i, environment, **pose_args) -> dict:
    return {"id": f"f{i}", "map_from_camera": pose(**pose_args), "raw_depth": {"environment": environment}}


def truthful(camera_xz, yaw, heading, *, accuracy=5.0, heading_accuracy=8.0, gps_noise=(0.0, 0.0),
             compass_noise=0.0, **extra) -> dict:
    """Environment sample a phone at `camera_xz` facing `yaw` would record for the true building pose."""
    truth = LocalProjection(*ORIGIN, heading)
    lat, lon = truth.coordinate(*camera_xz)
    lat, lon = LocalProjection(lat, lon).coordinate(gps_noise[0], -gps_noise[1])      # east, north noise
    return {"recorded_at_unix_seconds": 1_791_000_000.0 + extra.pop("t", 0), "latitude": lat, "longitude": lon,
            "horizontal_accuracy_m": accuracy, "heading_degrees": (heading - yaw + compass_noise) % 360,
            "heading_accuracy_degrees": heading_accuracy, **extra}


def distance_to_origin(result) -> float:
    return float(np.linalg.norm(offset_m(*ORIGIN, result["latitude"], result["longitude"])))


def context(manifest, assets=None) -> ScanContext:
    return ScanContext("geo-test", ScanInputs(scan_id="geo-test"), MemorySource(manifest, assets or {}))


def test_device_yaw_convention():
    # ARKit's pose yaw is counterclockwise about +Y; compass headings run clockwise from local -Z.
    assert reference.device_yaw_degrees(matrix(pose(yaw=0))) == pytest.approx(0)
    assert reference.device_yaw_degrees(matrix(pose(yaw=90))) == pytest.approx(-90)
    assert reference.device_yaw_degrees(matrix(pose(yaw=-30, pitch=-20))) == pytest.approx(30)
    # Phone held flat (camera looking straight down): the heading follows the device top (camera -X).
    assert reference.device_yaw_degrees(matrix(pose(yaw=0, pitch=-90))) == pytest.approx(-90)
    assert reference.device_yaw_degrees(matrix(pose(yaw=0, pitch=-60))) == pytest.approx(-90)


def test_single_fix_matches_ios_camera_to_origin_shift():
    # ScanController.applyGeographicContext: coordinate(for: -camera_xz) with the fix's heading.
    env = truthful((10.0, -5.0), 0.0, 90.0)
    result, reason = reference.estimate_from_samples(reference.samples_from_manifest(
        {"observations": [observation(0, env, x=10.0, z=-5.0)]}))
    assert reason is None and result["method"] == "single_fix" and result["samples_used"] == 1
    ios_lat, ios_lon = LocalProjection(env["latitude"], env["longitude"], env["heading_degrees"]).coordinate(-10.0, 5.0)
    assert result["latitude"] == pytest.approx(ios_lat, abs=1e-7)
    assert result["longitude"] == pytest.approx(ios_lon, abs=1e-7)
    assert distance_to_origin(result) < 0.01
    assert result["heading_degrees"] == pytest.approx(90.0)
    assert result["horizontal_accuracy_m"] == pytest.approx(5.0, abs=0.5)


def test_noisy_walk_with_outliers_is_robust():
    rng = np.random.default_rng(7)
    heading, observations = 30.0, []
    for i in range(14):
        xz = (rng.uniform(-15, 15), rng.uniform(-15, 15))
        yaw = rng.uniform(-180, 180)
        env = truthful(xz, yaw, heading, gps_noise=rng.normal(0, 3.0, 2), compass_noise=rng.normal(0, 4.0), t=i)
        observations.append(observation(i, env, x=xz[0], z=xz[1], yaw=yaw))
    # A multipath GPS jump claiming 5 m accuracy and a magnetically disturbed compass reading.
    observations.append(observation(20, truthful((0, 0), 0, heading, gps_noise=(80.0, 40.0)), x=0, z=0))
    observations.append(observation(21, truthful((1, 1), 0, heading, compass_noise=120.0), x=1, z=1))
    result, _ = reference.estimate_from_samples(reference.samples_from_manifest({"observations": observations}))
    assert result["method"] == "sensor_fusion"
    assert distance_to_origin(result) < 3.0
    assert abs(reference.wrap_degrees(result["heading_degrees"] - heading)) < 3.0
    assert result["samples"]["position_outliers"] >= 1 and result["samples"]["heading_outliers"] >= 1
    assert result["samples_used"] <= 15
    assert 0 < result["horizontal_accuracy_m"] < 10
    assert result["uncertainty"]["heading_spread_degrees"] < 10


def test_yaw_correction_recovers_building_heading():
    observations = [observation(i, truthful((i, -i), yaw, 200.0), x=float(i), z=float(-i), yaw=yaw)
                    for i, yaw in enumerate((0, 45, 90, 135, -60))]
    samples = reference.samples_from_manifest({"observations": observations})
    corrected, _ = reference.estimate_from_samples(samples)
    assert corrected["heading_degrees"] == pytest.approx(200.0, abs=1e-6)
    assert distance_to_origin(corrected) < 0.01
    naive, _ = reference.estimate_from_samples(samples, yaw_correction=False)
    assert abs(reference.wrap_degrees(naive["heading_degrees"] - 200.0)) > 10


def test_circular_mean_wraps_through_north():
    mean, resultant = reference.circular_mean_degrees([358, 2, 359, 1])
    assert reference.wrap_degrees(mean) == pytest.approx(0, abs=1e-9) and resultant > 0.99
    robust = reference.robust_heading([350, 10, 355, 5, 180], [5, 5, 5, 5, 5])
    assert reference.wrap_degrees(robust["heading_degrees"]) == pytest.approx(0, abs=1e-6)
    assert robust["inliers"].tolist() == [True, True, True, True, False]


def test_accuracy_filters_follow_the_app():
    good = observation(0, truthful((0, 0), 0, 10.0, accuracy=25.0))                 # GPS too coarse
    no_heading_accuracy = observation(1, {**truthful((0, 0), 0, 10.0), "heading_accuracy_degrees": None})
    samples = reference.samples_from_manifest({"observations": [good]})
    assert reference.estimate_from_samples(samples) == (None, "no GPS fix with horizontal accuracy <= 20 m")
    samples = reference.samples_from_manifest({"observations": [no_heading_accuracy]})
    result, reason = reference.estimate_from_samples(samples)
    assert result is None and "compass heading" in reason
    assert reference.estimate_from_samples([])[0] is None


def test_origin_altitude_subtracts_camera_height():
    env = truthful((0, 0), 0, 0.0, altitude_m=301.4, vertical_accuracy_m=4.0)
    result, _ = reference.estimate_from_samples(reference.samples_from_manifest(
        {"observations": [observation(0, env, y=1.4)]}))
    assert result["altitude_m"] == pytest.approx(300.0)


@pytest.mark.parametrize("altitudes,expected_levels,floor_height", [
    ([0.0, 0.1, -0.1, 3.9, 4.0, 7.8, 7.7], [0, 1, 2], 3.9),
    ([0.0, 0.2, -0.1, 0.3], [0], None),
    ([4.1, 0.0, 0.1], [-1, 0], 4.0),             # capture started upstairs: level 0 is the first sample
])
def test_level_hints_from_barometer(altitudes, expected_levels, floor_height):
    observations = [observation(i, {"recorded_at_unix_seconds": 100.0 + i, "relative_altitude_m": a})
                    for i, a in enumerate(altitudes)]
    hints = reference.level_hints(reference.samples_from_manifest({"observations": observations}))
    assert [level["index"] for level in hints["levels"]] == expected_levels
    assert hints["multi_level"] == (len(expected_levels) > 1)
    if floor_height is None:
        assert hints["floor_height_m"] is None
    else:
        assert hints["floor_height_m"] == pytest.approx(floor_height, abs=0.15)
    assert sum(level["samples"] for level in hints["levels"]) == len(altitudes)


def test_repeated_cached_fix_counts_once():
    # The phone stamps its latest cached fix on every frame; 200 copies are still one 10 m fix.
    env = truthful((0.0, 0.0), 0.0, 15.0, accuracy=10.0, heading_accuracy=15.0)
    observations = [observation(i, {**env, "recorded_at_unix_seconds": 100.0 + i}) for i in range(200)]
    result, _ = reference.estimate_from_samples(reference.samples_from_manifest({"observations": observations}))
    assert result["samples_used"] == 1 and result["method"] == "single_fix"
    assert result["horizontal_accuracy_m"] == pytest.approx(10.0, abs=0.5)
    assert result["heading_accuracy_degrees"] == pytest.approx(15.0)
    assert result["samples"]["distinct_fixes"] == 1 and result["samples"]["distinct_headings"] == 1


def test_stale_fix_uses_the_camera_where_it_first_appeared():
    # One fix taken at (0, 0); the user then walks 15 m along -Z without a new fix.
    env = truthful((0.0, 0.0), 0.0, 0.0)
    observations = [observation(i, {**env, "recorded_at_unix_seconds": 100.0 + i}, x=0.0, z=-float(i))
                    for i in range(16)][::-1]                                   # manifest order is irrelevant
    result, _ = reference.estimate_from_samples(reference.samples_from_manifest({"observations": observations}))
    assert distance_to_origin(result) < 0.01


def test_level_hints_survive_stair_transits():
    # Dwell on the ground floor, climb the stairs (samples every 10 cm), dwell upstairs.
    altitudes = [0.0] * 30 + [i * 0.1 for i in range(1, 38)] + [3.8] * 30
    observations = [observation(i, {"recorded_at_unix_seconds": 100.0 + i, "relative_altitude_m": a})
                    for i, a in enumerate(altitudes)]
    hints = reference.level_hints(reference.samples_from_manifest({"observations": observations}))
    assert [level["index"] for level in hints["levels"]] == [0, 1]
    assert hints["floor_height_m"] == pytest.approx(3.8, abs=0.2)
    # A steady 5 m climb with no dwell at all is still recognised as more than one level.
    ramp = [observation(i, {"recorded_at_unix_seconds": 100.0 + i, "relative_altitude_m": i * 0.05}) for i in range(101)]
    assert reference.level_hints(reference.samples_from_manifest({"observations": ramp}))["multi_level"]


def test_level_hints_need_two_samples():
    single = reference.samples_from_manifest({"observations": [observation(0, {"relative_altitude_m": 0.0})]})
    assert reference.level_hints(single) is None


def test_stage_prefers_device_reference_and_cross_checks():
    manifest = {"observations": [observation(0, truthful((2.0, 3.0), 0, 45.0), x=2.0, z=3.0)]}
    semantics = {"geographic_reference": {"latitude": ORIGIN[0], "longitude": ORIGIN[1] + 0.0001,
                                          "heading_degrees": 50.0, "horizontal_accuracy_m": 4.0}}
    result = GeorefStage().run(context(manifest, {"semantics.json": json.dumps(semantics).encode()}))
    georef = result.products[ProductName.GEOREF].json
    assert georef["method"] == "device_reference"
    assert georef["longitude"] == pytest.approx(ORIGIN[1] + 0.0001)
    assert georef["heading_degrees"] == 50.0 and georef["horizontal_accuracy_m"] == 4.0
    check = georef["cross_check"]
    assert check["method"] == "single_fix" and check["heading_difference_degrees"] == pytest.approx(5.0, abs=1e-6)
    assert check["distance_m"] == pytest.approx(9.26, abs=0.1)             # 0.0001 deg of longitude at 33.8 N


def test_stage_ignores_invalid_device_reference():
    manifest = {"observations": [observation(0, truthful((0, 0), 0, 45.0))]}
    semantics = {"geographic_reference": {"latitude": 91.0, "longitude": 0.0, "heading_degrees": 0.0}}
    result = GeorefStage().run(context(manifest, {"semantics.json": json.dumps(semantics).encode()}))
    assert result.products[ProductName.GEOREF].json["method"] == "single_fix"
    assert any("geographic_reference ignored" in notice for notice in result.notices)


def test_stage_without_samples_provides_nothing():
    result = GeorefStage().run(context(None))
    assert not result.products and result.summary["status"] == "unavailable"
    assert any("Geo-reference unavailable" in notice for notice in result.notices)
    analysis = runner.run(context(None), [GeorefStage()])
    assert ProductName.GEOREF not in analysis and analysis["stages"]["georef"]["status"] == "ok"


def test_synthetic_package_georef(synthetic_ctx):
    result = GeorefStage().run(synthetic_ctx)
    georef = result.products[ProductName.GEOREF].json
    # The synthetic camera sits at the origin (x = z = 0) facing local -Z, so no offset or yaw applies.
    assert georef["latitude"] == pytest.approx(33.7756, abs=1e-7)
    assert georef["longitude"] == pytest.approx(-84.3963, abs=1e-7)
    assert georef["heading_degrees"] == pytest.approx(90.0)
    assert georef["horizontal_accuracy_m"] == pytest.approx(6.0)
    assert georef["method"] == "single_fix" and georef["samples_used"] == 1

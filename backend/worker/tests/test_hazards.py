"""3D hazards and the 2.5D height map on synthetic meshes with known geometry."""
import json
import math

import numpy as np
import pytest

from inview_worker import floor_map, terrain
from inview_worker.contracts import ProductName, Thresholds
from inview_worker.core import ScanContext, runner
from inview_worker.inputs import Box, ScanInputs, Surface
from inview_worker.stages.floor_map import FloorMapStage
from inview_worker.stages.hazards import HazardsStage
from inview_worker.terrain.elevation import fill_small_holes
from inview_worker.terrain.raster import fill_nearest, gradient, nan_range, sample_triangles


def pose(x=0.0, y=0.0, z=0.0) -> np.ndarray:
    m = np.eye(4)
    m[:3, 3] = [x, y, z]
    return m


class Mesh:
    """Triangle soup builder: subdivided quads and axis-aligned boxes (like ARKit mesh patches)."""

    def __init__(self):
        self.vertices, self.faces = [], []

    def quad(self, a, b, c, d, cell=0.25):
        a, b, c, d = map(np.asarray, (a, b, c, d))
        nu = max(1, int(math.ceil(np.linalg.norm(b - a) / cell)))
        nv = max(1, int(math.ceil(np.linalg.norm(d - a) / cell)))
        base = len(self.vertices)
        for i in range(nv + 1):
            for j in range(nu + 1):
                s, t = i / nv, j / nu
                self.vertices.append((1 - s) * ((1 - t) * a + t * b) + s * ((1 - t) * d + t * c))
        for i in range(nv):
            for j in range(nu):
                k = base + i * (nu + 1) + j
                self.faces += [[k, k + 1, k + nu + 1], [k + 1, k + nu + 2, k + nu + 1]]
        return self

    def floor(self, x0, x1, z0, z1, y=0.0):
        return self.quad((x0, y, z0), (x1, y, z0), (x1, y, z1), (x0, y, z1))

    def box(self, lo, hi, bottom=True):
        (x0, y0, z0), (x1, y1, z1) = lo, hi
        self.floor(x0, x1, z0, z1, y1)
        if bottom:
            self.floor(x0, x1, z0, z1, y0)
        self.quad((x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0))
        self.quad((x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1))
        self.quad((x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0))
        return self.quad((x1, y0, z0), (x1, y0, z1), (x1, y1, z1), (x1, y1, z0))

    def walls(self, x0, x1, z0, z1, height=2.6, ceiling=True):
        for a, b in (((x0, z0), (x1, z0)), ((x1, z0), (x1, z1)), ((x1, z1), (x0, z1)), ((x0, z1), (x0, z0))):
            self.quad((a[0], 0, a[1]), (b[0], 0, b[1]), (b[0], height, b[1]), (a[0], height, a[1]))
        if ceiling:
            self.floor(x0, x1, z0, z1, height)
        return self

    def inputs(self, cameras, objects=(), name="mesh") -> ScanInputs:
        return ScanInputs(name, surfaces=[Surface("floor", "floor", pose(), [0.5, 0, 0.5])], objects=list(objects),
                          mesh_vertices=np.asarray(self.vertices, float), mesh_triangles=np.asarray(self.faces),
                          camera_positions=np.asarray(cameras, float))


def run(inputs: ScanInputs):
    fm = floor_map.build(inputs)
    hm = terrain.build(inputs, fm.grid, fm.floor_height)
    return fm, hm, terrain.detect(hm, inputs.objects)


def kinds(hazards):
    return sorted(h["kind"] for h in hazards)


def flat_room():
    return Mesh().floor(-2, 2, -2, 2).walls(-2, 2, -2, 2)


ROOM_TRACK = [[x, 1.4, 0.0] for x in np.linspace(-1.5, 1.5, 7)]


# --- raster primitives -----------------------------------------------------------------------------

def test_lattice_samples_cover_every_cell_on_the_plane():
    vertices = np.array([[0, 0, 0], [1, 0.5, 0], [0, 0, 1]], float)
    points, owners = sample_triangles(vertices, np.array([[0, 1, 2]]), 0.025)
    assert (owners == 0).all() and len(points) > 600
    # Every sample lies on the triangle plane y = 0.5 x.
    assert np.allclose(points[:, 1], 0.5 * points[:, 0])


def test_gradient_is_rise_over_run_and_range_marks_steps():
    res = 0.05
    cols = np.arange(40, dtype=np.float32)
    plane = np.tile(cols * res * 0.1, (30, 1))  # Slope 1:10 along +X.
    gx, gz = gradient(plane, res)
    assert np.allclose(gx[5:-5, 5:-5], 0.1, atol=1e-4) and np.allclose(gz[5:-5, 5:-5], 0, atol=1e-4)
    step = np.zeros((10, 10), np.float32)
    step[:, 5:] = 0.15
    step[0, 0] = np.nan
    edge = nan_range(step, 3)
    assert edge[5, 4] == pytest.approx(0.15) and edge[5, 5] == pytest.approx(0.15) and edge[5, 1] == 0
    assert edge[0, 0] == 0 and np.isfinite(fill_nearest(step)).all()


def test_hole_fill_stays_within_the_rim_and_skips_large_or_open_gaps():
    surface = np.zeros((20, 20), np.float32)
    surface[:, 10:] = 0.15
    surface[8, 9:12] = np.nan     # Small hole straddling the step.
    surface[2:8, 2:8] = np.nan    # 36 cells: too large.
    surface[15, 0] = np.nan       # Touches the border: not enclosed.
    filled = fill_small_holes(surface, 10)
    assert filled.sum() == 3 and np.isfinite(surface[8, 9:12]).all()
    assert surface[8, 9:12].min() >= 0 and surface[8, 9:12].max() <= 0.15
    assert np.isnan(surface[4, 4]) and np.isnan(surface[15, 0])


# --- height map --------------------------------------------------------------------------------------

def test_flat_room_has_full_coverage_zero_elevation_and_no_hazards():
    inputs = flat_room().inputs(ROOM_TRACK)
    fm, hm, hazards = run(inputs)
    assert hm.elevation.shape == fm.floor.shape and hm.elevation.dtype == np.float32
    assert hm.slope.shape == hm.clearance.shape == fm.floor.shape
    info = terrain.summary(hm, np.maximum(fm.floor, fm.walked))
    assert info["grid"] == fm.result["grid"] and info["source"] == "mesh" and info["measured"]
    assert info["coverage"] > 0.95
    assert abs(info["min_elevation_m"]) < 1e-3 and abs(info["max_elevation_m"]) < 1e-3
    assert np.nanmax(hm.slope) < 0.01
    centre = hm.sample(hm.clearance, [[0.0, 0.0]])[0]
    assert centre == pytest.approx(2.6, abs=0.01)
    assert hazards == []


def test_table_tops_are_not_walking_surfaces():
    # A solid block standing on the floor: the floor under it is never seen.
    mesh = Mesh().floor(-2, 2, -2, -0.4).floor(-2, 2, 0.4, 2).floor(-2, -0.5, -0.4, 0.4).floor(0.5, 2, -0.4, 0.4)
    mesh.walls(-2, 2, -2, 2).box((-0.5, 0.0, -0.4), (0.5, 0.74, 0.4), bottom=False)
    fm, hm, hazards = run(mesh.inputs(ROOM_TRACK))
    top = hm.sample(hm.elevation, [[0.0, 0.0]])[0]
    assert math.isnan(top)  # Unreachable by a step: an obstacle, not a drop-off.
    assert not [h for h in hazards if h["kind"] in ("drop_off", "step", "level_change")]


# --- level changes -----------------------------------------------------------------------------------

def test_raised_platform_step_is_detected_with_its_rise():
    mesh = Mesh().floor(-2, 0.5, -2, 2).floor(0.5, 2, -2, 2, 0.15).walls(-2, 2, -2, 2)
    mesh.quad((0.5, 0, -2), (0.5, 0, 2), (0.5, 0.15, 2), (0.5, 0.15, -2))
    fm, hm, hazards = run(mesh.inputs(ROOM_TRACK))
    assert kinds(hazards) == ["step"]
    step = hazards[0]
    assert step["id"] == "step-1" and step["severity"] == "barrier"
    assert step["measure"]["rise_m"] == pytest.approx(0.15, abs=0.01)
    assert step["measure"]["length_m"] == pytest.approx(4.0, abs=0.4)
    assert step["position_m"][0] == pytest.approx(0.5, abs=0.1)
    assert step["down_direction_xz"][0] < -0.9  # Lower side is -X.
    assert hm.sample(hm.elevation, [[1.2, 0.0]])[0] == pytest.approx(0.15, abs=1e-3)
    profile = terrain.segment_profile(hm, [-1.0, 0.0], [1.5, 0.0])
    assert profile["step_free"] is False and profile["max_level_change_m"] == pytest.approx(0.15, abs=0.01)
    assert terrain.segment_profile(hm, [-1.5, -1.0], [-0.5, 1.0])["step_free"] is True


def test_small_lip_is_a_level_change_and_deep_pit_is_a_drop_off():
    lip = Mesh().floor(-2, 0.0, -2, 2).floor(0.0, 2, -2, 2, 0.035).walls(-2, 2, -2, 2)
    _, _, hazards = run(lip.inputs(ROOM_TRACK))
    assert kinds(hazards) == ["level_change"] and hazards[0]["severity"] == "warning"
    assert hazards[0]["measure"]["rise_m"] == pytest.approx(0.035, abs=0.01)

    # A sunken area 0.5 m down, reached by the camera walking inside it: a drop-off edge.
    pit = Mesh().floor(-2, 0.0, -2, 2).floor(0.0, 2, -2, 2, -0.5).walls(-2, 2, -2, 2)
    track = [[-1.0, 1.4, 0.0], [1.0, 0.9, 0.0]]
    _, _, hazards = run(pit.inputs(track))
    assert kinds(hazards) == ["drop_off"]
    assert hazards[0]["measure"]["rise_m"] == pytest.approx(0.5, abs=0.02)
    assert hazards[0]["down_direction_xz"][0] > 0.9


# --- ramps -------------------------------------------------------------------------------------------

def ramp_corridor(slope: float, rise: float = 0.2) -> Mesh:
    run_m = rise / slope
    mesh = Mesh().floor(-0.6, 0.6, -3, -1)
    mesh.quad((-0.6, 0, -1), (0.6, 0, -1), (0.6, rise, -1 + run_m), (-0.6, rise, -1 + run_m))
    mesh.floor(-0.6, 0.6, -1 + run_m, run_m + 0.5, rise)
    return mesh.walls(-0.6, 0.6, -3, run_m + 0.5)


@pytest.mark.parametrize("slope,barrier", [(1 / 10, True), (1 / 15, False)])
def test_ramp_slope_is_measured_and_screened_against_1_12(slope, barrier):
    track = [[0, 1.4, -2.5], [0, 1.4 + 0.2, (0.2 / slope) - 0.5]]
    fm, hm, hazards = run(ramp_corridor(slope).inputs(track))
    assert kinds(hazards) == ["ramp"]
    ramp = hazards[0]
    assert ramp["measure"]["running_slope"] == pytest.approx(slope, rel=0.08)
    assert ramp["measure"]["cross_slope"] < Thresholds.CROSS_SLOPE_MAX
    assert ramp["measure"]["rise_m"] == pytest.approx(0.2, abs=0.05)
    assert ramp["ascending_direction_xz"][1] > 0.99
    assert (ramp["severity"] == "barrier") is barrier
    assert ("running_slope_exceeds_1_12" in ramp["issues"]) is barrier
    profile = terrain.segment_profile(hm, [0, -2.5], [0, -1 + 0.2 / slope + 0.3])
    assert profile["step_free"] is True and profile["meets_ramp_slope"] is (not barrier)


# --- stairs ------------------------------------------------------------------------------------------

def stair_corridor(risers=3, rise=0.17, tread=0.3) -> Mesh:
    mesh = Mesh().floor(-0.6, 0.6, -2.5, 0)
    for i in range(risers):
        z0, top = i * tread, (i + 1) * rise
        mesh.quad((-0.6, i * rise, z0), (0.6, i * rise, z0), (0.6, top, z0), (-0.6, top, z0))
        end = z0 + tread if i < risers - 1 else 2.0
        mesh.floor(-0.6, 0.6, z0, end, top)
    return mesh.walls(-0.6, 0.6, -2.5, 2.0)


def test_three_step_stair_is_one_stairs_hazard():
    track = [[0, 1.4, -2.0], [0, 1.4 + 0.51, 1.5]]
    fm, hm, hazards = run(stair_corridor().inputs(track))
    assert kinds(hazards) == ["stairs"], hazards
    stair = hazards[0]
    assert stair["measure"]["risers"] == 3
    assert stair["measure"]["rise_m"] == pytest.approx(0.17, abs=0.015)
    assert stair["measure"]["tread_depth_m"] == pytest.approx(0.3, abs=0.06)
    assert stair["measure"]["total_rise_m"] == pytest.approx(0.51, abs=0.03)
    assert stair["measure"]["width_m"] == pytest.approx(1.2, abs=0.25)
    assert stair["ascending_direction_xz"][1] > 0.99 and stair["severity"] == "barrier"
    assert stair["method"] == "hough_parallel_risers"


def test_roomplan_stairs_object_is_reported_and_merged():
    track = [[0, 1.4, -2.0], [0, 1.4 + 0.51, 1.5]]
    stairs_box = Box("s1", "stairs", pose(0, 0.255, 0.45), [1.2, 0.51, 0.9])
    _, _, hazards = run(stair_corridor().inputs(track, [stairs_box]))
    assert kinds(hazards) == ["stairs"] and hazards[0]["sources"] == ["roomplan:object:s1"]

    # RoomPlan only (no mesh or depth): the object alone becomes a stairs hazard.
    inputs = ScanInputs("plan", surfaces=[Surface("floor", "floor", pose(), [4, 0, 4])], objects=[stairs_box])
    fm, hm, hazards = run(inputs)
    assert not hm.measured and hm.source == "roomplan_floor"
    assert kinds(hazards) == ["stairs"] and hazards[0]["method"] == "roomplan_object"
    assert hazards[0]["measure"]["total_rise_m"] == pytest.approx(0.51)


# --- overhead ----------------------------------------------------------------------------------------

def test_shelf_protruding_30cm_at_1_2m_is_a_protruding_object():
    mesh = flat_room().box((-0.4, 1.2, -2.0), (0.4, 1.25, -1.7))
    _, hm, hazards = run(mesh.inputs(ROOM_TRACK))
    assert kinds(hazards) == ["protruding_object"]
    shelf = hazards[0]
    assert shelf["measure"]["protrusion_m"] == pytest.approx(0.3, abs=0.06)
    assert shelf["measure"]["leading_edge_height_m"] == pytest.approx(1.2, abs=0.01)
    assert shelf["position_m"][1] == pytest.approx(1.2, abs=0.01)
    assert shelf["position_m"][2] == pytest.approx(-1.85, abs=0.1)
    assert shelf["severity"] == "warning"


def test_shallow_wall_fixture_is_within_the_4_inch_allowance():
    mesh = flat_room().box((-0.4, 1.2, -2.0), (0.4, 1.25, -1.93))
    _, _, hazards = run(mesh.inputs(ROOM_TRACK))
    assert hazards == []


def test_low_beam_at_1_9m_is_low_headroom():
    mesh = flat_room().box((-2.0, 1.9, -0.1), (2.0, 2.0, 0.1))
    _, hm, hazards = run(mesh.inputs(ROOM_TRACK))
    assert kinds(hazards) == ["low_headroom"]
    beam = hazards[0]
    assert beam["measure"]["clearance_min_m"] == pytest.approx(1.9, abs=0.01)
    assert beam["position_m"][2] == pytest.approx(0.0, abs=0.1)
    assert hm.sample(hm.clearance, [[1.0, 0.0]])[0] == pytest.approx(1.9, abs=0.01)


# --- stage -------------------------------------------------------------------------------------------

def test_stage_products_follow_the_contract(synthetic_ctx):
    result = runner.run(synthetic_ctx, [FloorMapStage(), HazardsStage()])
    assert result["stages"]["hazards"]["status"] == "ok"
    height = result[ProductName.HEIGHT_MAP]
    fm = synthetic_ctx.data(ProductName.FLOOR_MAP)
    hm = synthetic_ctx.data(ProductName.HEIGHT_MAP)
    assert height["grid"] == result["floor_map"]["grid"]
    assert hm.elevation.shape == (fm.grid.height, fm.grid.width)
    assert height["coverage"] > 0.9 and abs(height["max_relative_m"]) < 0.01 and abs(height["min_relative_m"]) < 0.01
    assert result[ProductName.HAZARDS] == []
    assert result["summary"]["hazards"]["hazards"] == 0


def test_stage_degrades_on_roomplan_only_scans():
    inputs = ScanInputs("plan", surfaces=[Surface("floor", "floor", pose(), [4, 0, 4])],
                        camera_positions=np.array([[0, 1.4, 0.0]]))
    ctx = ScanContext("plan", inputs)
    result = runner.run(ctx, [FloorMapStage(), HazardsStage()])
    assert result["height_map"]["source"] == "roomplan_floor" and result["hazards"] == []
    assert any("RoomPlan floor planes only" in n for n in result["notices"])


def test_output_is_deterministic_and_json_serialisable():
    mesh = stair_corridor()
    track = [[0, 1.4, -2.0], [0, 1.4 + 0.51, 1.5]]
    first = run(mesh.inputs(track))[2]
    assert first == run(mesh.inputs(track))[2]
    assert json.loads(json.dumps(first)) == first


# --- robustness --------------------------------------------------------------------------------------

def noisy(inputs: ScanInputs, sigma: float, seed: int) -> ScanInputs:
    inputs.mesh_vertices = inputs.mesh_vertices + np.random.default_rng(seed).normal(0, sigma, inputs.mesh_vertices.shape)
    return inputs


def test_noisy_fine_mesh_keeps_only_the_real_step():
    # 5 cm facets with 1 cm per-vertex noise: tilted wall facets must not become steps.
    flat = Mesh()
    flat.quad((-2, 0, -2), (2, 0, -2), (2, 0, 2), (-2, 0, 2), cell=0.05)
    for a, b in (((-2, -2), (2, -2)), ((2, -2), (2, 2)), ((2, 2), (-2, 2)), ((-2, 2), (-2, -2))):
        flat.quad((a[0], 0, a[1]), (b[0], 0, b[1]), (b[0], 2.6, b[1]), (a[0], 2.6, a[1]), cell=0.05)
    assert run(noisy(flat.inputs(ROOM_TRACK), 0.01, 7))[2] == []

    step = Mesh()
    step.quad((-2, 0, -2), (0.5, 0, -2), (0.5, 0, 2), (-2, 0, 2), cell=0.05)
    step.quad((0.5, 0.15, -2), (2, 0.15, -2), (2, 0.15, 2), (0.5, 0.15, 2), cell=0.05)
    step.quad((0.5, 0, -2), (0.5, 0, 2), (0.5, 0.15, 2), (0.5, 0.15, -2), cell=0.05)
    hazards = run(noisy(step.walls(-2, 2, -2, 2, ceiling=False).inputs(ROOM_TRACK), 0.01, 8))[2]
    assert kinds(hazards) == ["step"] and hazards[0]["measure"]["rise_m"] == pytest.approx(0.15, abs=0.02)


def test_depth_points_alone_build_the_surface_and_ignore_wall_sides():
    rng = np.random.default_rng(3)
    xs, zs = rng.uniform(-2, 2, 40000), rng.uniform(-2, 2, 40000)
    ys = np.where(xs > 0.5, 0.15, 0.0) + rng.normal(0, 0.003, xs.size)
    walls = np.column_stack((np.full(8000, 2.0), rng.uniform(0, 2.6, 8000), rng.uniform(-2, 2, 8000)))
    points = np.vstack((np.column_stack((xs, ys, zs)), walls))
    inputs = ScanInputs("depth", surfaces=[Surface("floor", "floor", pose(), [0.5, 0, 0.5])], points=points,
                        camera_positions=np.asarray(ROOM_TRACK, float))
    fm, hm, hazards = run(inputs)
    assert hm.source == "depth"
    assert kinds(hazards) == ["step"] and hazards[0]["measure"]["rise_m"] == pytest.approx(0.15, abs=0.02)
    assert terrain.summary(hm, fm.floor)["coverage"] > 0.8


# --- regressions from review ---------------------------------------------------------------------------

def floor_around(x0, x1, z0, z1) -> Mesh:
    """Room floor with a rectangular unscanned patch (the footprint of something standing on it)."""
    mesh = Mesh().floor(-2, 2, -2, z0).floor(-2, 2, z1, 2).floor(-2, x0, z0, z1).floor(x1, 2, z0, z1)
    return mesh.walls(-2, 2, -2, 2)


def test_phone_held_over_a_table_does_not_make_it_walkable():
    mesh = floor_around(-0.5, 0.5, -0.4, 0.4).box((-0.5, 0.0, -0.4), (0.5, 0.74, 0.4), bottom=False)
    track = [[-1.5, 1.4, 0.0], [0.0, 1.35, 0.0], [1.5, 1.4, 0.0]]
    _, hm, hazards = run(mesh.inputs(track))
    assert math.isnan(hm.sample(hm.elevation, [[0.0, 0.0]])[0])
    assert hazards == []


def test_solid_objects_are_not_protrusions_or_walking_floor():
    pedestal = floor_around(-0.15, 0.15, -0.15, 0.15).box((-0.15, 0.0, -0.15), (0.15, 1.0, 0.15), bottom=False)
    _, hm, hazards = run(pedestal.inputs(ROOM_TRACK))
    assert hazards == [] and math.isnan(hm.sample(hm.elevation, [[0.0, 0.0]])[0])
    # A closed box on a scanned floor (mesh only, no RoomPlan object): its measured sides enclose it.
    _, _, hazards = run(flat_room().box((-0.5, 0.0, -0.4), (0.5, 0.74, 0.4)).inputs(ROOM_TRACK))
    assert hazards == []


@pytest.mark.parametrize("slope", [0.2, 0.28])
def test_steep_planar_ramps_are_ramps_not_steps(slope):
    track = [[0, 1.4, -2.5], [0, 1.6, (0.2 / slope) - 0.5]]
    _, _, hazards = run(ramp_corridor(slope).inputs(track))
    assert kinds(hazards) == ["ramp"] and hazards[0]["measure"]["running_slope"] == pytest.approx(slope, rel=0.1)


def test_ramp_on_a_coarse_grid_is_still_a_ramp():
    inputs = ramp_corridor(0.1).inputs([[0, 1.4, -2.5], [0, 1.6, 1.5]])
    fm = floor_map.build(inputs, resolution=0.1)
    hm = terrain.build(inputs, fm.grid, fm.floor_height)
    hazards = terrain.detect(hm)
    assert kinds(hazards) == ["ramp"] and hazards[0]["measure"]["running_slope"] == pytest.approx(0.1, rel=0.1)


def test_parallel_edge_elsewhere_does_not_break_the_stair_chain():
    mesh = Mesh().floor(-0.6, 0.6, -2.5, 0)
    rise, tread = 0.17, 0.3
    for i in range(3):
        z0, top = i * tread, (i + 1) * rise
        mesh.quad((-0.6, i * rise, z0), (0.6, i * rise, z0), (0.6, top, z0), (-0.6, top, z0))
        mesh.floor(-0.6, 0.6, z0, z0 + tread if i < 2 else 2.0, top)
    # A separate 15 cm platform edge at z = 0.15, two metres to the side (its own walled bay).
    mesh.floor(1.4, 3.4, -2.5, 0.15).floor(1.4, 3.4, 0.15, 2.0, 0.15)
    mesh.quad((1.4, 0, 0.15), (3.4, 0, 0.15), (3.4, 0.15, 0.15), (1.4, 0.15, 0.15))
    mesh.walls(-0.6, 0.6, -2.5, 2.0, ceiling=False).walls(1.4, 3.4, -2.5, 2.0, ceiling=False)
    track = [[0, 1.4, -2.0], [0, 1.91, 1.5], [2.4, 1.4, -2.0]]
    _, _, hazards = run(mesh.inputs(track))
    stairs = [h for h in hazards if h["kind"] == "stairs"]
    assert len(stairs) == 1 and stairs[0]["measure"]["risers"] == 3
    assert kinds(hazards) == ["stairs", "step"]


def test_profile_over_unmeasured_gap_is_not_step_free():
    mesh = Mesh().floor(-2, -1.2, -2, 2).floor(1.2, 2, -2, 2).walls(-2, 2, -2, 2)
    track = [[-1.6, 1.4, 0.0], [1.6, 1.4, 0.0]]
    _, hm, _ = run(mesh.inputs(track))
    profile = terrain.segment_profile(hm, [-1.8, 0.0], [1.8, 0.0])
    assert profile["known_fraction"] < 0.5 and profile["step_free"] is None and profile["meets_ramp_slope"] is None
    assert profile["max_level_change_m"] == 0


def test_inpainted_surface_is_not_measured_route_evidence():
    # No measured ceiling in the gap: there is simply a small patch the scan missed.
    mesh = (Mesh().floor(-2, 2, -2, -0.1).floor(-2, 2, 0.1, 2)
            .floor(-2, -0.1, -0.1, 0.1).floor(0.1, 2, -0.1, 0.1))
    _, hm, _ = run(mesh.inputs(ROOM_TRACK))
    assert np.isfinite(hm.sample(hm.elevation, [[0, 0]])[0])  # Useful for the screening visualization.
    assert np.isnan(hm.sample(hm.measured_elevation(), [[0, 0]])[0])
    profile = terrain.segment_profile(hm, [-1, 0], [1, 0])
    assert 0.8 < profile["known_fraction"] < 1
    assert profile["step_free"] is None and profile["meets_ramp_slope"] is None

import numpy as np
import pytest

from inview_worker.contracts import RESERVED_KEYS, PlaceCategory, access_point_kind
from inview_worker.core import Product, ScanContext, Stage, StageResult, register, registry, runner
from inview_worker.inputs import ScanInputs
from inview_worker.pipeline import analyze
from inview_worker.synthetic import package


def make(name, requires=(), optional=(), provides=(), action=None):
    def run(self, ctx):
        if action:
            return action(ctx)
        return StageResult({p: Product({"from": name}) for p in provides}, {"ran": True})
    return type(f"S_{name}", (Stage,), {"name": name, "requires": requires, "optional": optional,
                                         "provides": provides, "run": run})()


def ctx():
    return ScanContext("scan", ScanInputs("scan"))


def test_order_follows_requirements_and_optional_inputs():
    stages = [make("c", requires=("b",), provides=("c",)), make("a", provides=("a",)),
              make("b", optional=("a",), provides=("b",))]
    assert [s.name for s in runner.order(stages)] == ["a", "b", "c"]


def test_cycles_are_rejected():
    with pytest.raises(ValueError, match="cycle"):
        runner.order([make("x", requires=("y",), provides=("x",)), make("y", requires=("x",), provides=("y",))])


def test_missing_requirement_skips_and_failures_are_isolated():
    def boom(ctx):
        raise RuntimeError("bad input")
    stages = [make("needs", requires=("absent",), provides=("n",)), make("fails", provides=("f",), action=boom),
              make("works", provides=("w",))]
    result = runner.run(ctx(), stages)
    assert result["stages"]["needs"] == {"status": "skipped", "missing": ["absent"]}
    assert result["stages"]["fails"]["status"] == "failed" and "bad input" in result["stages"]["fails"]["error"]
    assert result["stages"]["works"]["status"] == "ok" and result["w"] == {"from": "works"}
    assert result["summary"] == {"works": {"ran": True}}
    assert any("fails failed" in n for n in result["notices"])


def test_undeclared_products_are_rejected():
    sneaky = make("sneaky", provides=("ok",), action=lambda c: StageResult({"other": Product(1)}))
    result = runner.run(ctx(), [sneaky])
    assert result["stages"]["sneaky"]["status"] == "failed" and "other" not in result


def test_internal_data_is_not_published():
    stage = make("raster", provides=("grid",), action=lambda c: StageResult({"grid": Product({"cells": 4}, np.zeros(4))}))
    c = ctx()
    result = runner.run(c, [stage])
    assert result["grid"] == {"cells": 4} and c.data("grid").shape == (4,)


def test_registration_enforces_the_contract():
    registry.discover()  # Real stages first, so the duplicate below is caught, never registered.
    with pytest.raises(ValueError, match="reserved"):
        register(type("Bad", (Stage,), {"name": "bad-reserved", "provides": (next(iter(RESERVED_KEYS)),)}))
    with pytest.raises(ValueError, match="both provide"):
        register(type("Dup", (Stage,), {"name": "dup-floor", "provides": ("floor_map",)}))
    names = {s.name for s in registry.stages()}
    assert {"floor_map", "doors", "signs"} <= names


def test_place_categories_map_onto_ios_access_point_kinds():
    assert access_point_kind(PlaceCategory.ELEVATOR) == "elevator"
    assert access_point_kind("ramp") == "ramp"
    assert access_point_kind(PlaceCategory.RESTROOM) == "destination"


def test_context_caches_read_only_images(synthetic_ctx):
    image = synthetic_ctx.image("f0.color.jpg")
    assert image.shape == (640, 480, 3) and synthetic_ctx.image("f0.color.jpg") is image
    assert not image.flags.writeable
    assert synthetic_ctx.image("missing.jpg") is None
    assert synthetic_ctx.manifest()["capture_id"] == package.SCAN_ID


def test_full_pipeline_on_the_synthetic_package_matches_ground_truth(synthetic_ctx):
    result = analyze(synthetic_ctx)
    # A stage may only be skipped when no registered stage provides what it requires yet.
    provided = {product for stage in registry.stages() for product in stage.provides}
    assert all(s["status"] == "ok" or (s["status"] == "skipped" and not set(s["missing"]) & provided)
               for s in result["stages"].values()), result["stages"]
    assert result["floor_map"]["floor_height_m"] == pytest.approx(package.TRUTH["floor_y_m"], abs=0.02)
    assert result["floor_map"]["outlines"][0]["area_m2"] == pytest.approx(package.TRUTH["room_area_m2"], rel=0.08)
    door = result["doors"][0]
    assert door["nominal_width_m"] == pytest.approx(package.TRUTH["door"]["width_m"], abs=0.01)
    assert not door["meets_headroom"]  # 2.0 m door < 2.03 m
    exit_signs = [s for s in result["signs"] if s["kind"] == "exit_sign_candidate"]
    assert exit_signs and np.linalg.norm(np.subtract(exit_signs[0]["position_m"], package.TRUTH["sign_center_m"])) < 0.1

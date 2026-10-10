"""Dependency-ordered, failure-isolated execution of stages into one analysis document."""
from __future__ import annotations

import logging
import time
import traceback
from datetime import datetime, timezone

import cv2

from .. import __version__
from ..contracts import ANALYSIS_SCHEMA_VERSION, FRAME, NOTICE
from .context import ScanContext
from .registry import stages as registered_stages
from .stage import Stage

log = logging.getLogger(__name__)


def order(stages: list[Stage]) -> list[Stage]:
    """Topological order: a stage runs after every stage providing what it requires or uses."""
    providers = {product: stage.name for stage in stages for product in stage.provides}
    by_name = {stage.name: stage for stage in stages}
    edges = {stage.name: sorted({providers[p] for p in (*stage.requires, *stage.optional)
                                 if p in providers and providers[p] != stage.name}) for stage in stages}
    ordered, state = [], {}

    def visit(name: str, path: tuple[str, ...]) -> None:
        if state.get(name) == "done":
            return
        if state.get(name) == "active":
            raise ValueError(f"Stage dependency cycle: {' -> '.join((*path, name))}")
        state[name] = "active"
        for dependency in edges[name]:
            visit(dependency, (*path, name))
        state[name] = "done"
        ordered.append(by_name[name])

    for name in sorted(by_name):
        visit(name, ())
    return ordered


def run(ctx: ScanContext, stages: list[Stage] | None = None) -> dict:
    stages = order(registered_stages() if stages is None else stages)
    status, summary, notices = {}, {}, [NOTICE]
    for stage in stages:
        missing = [name for name in stage.requires if name not in ctx.products]
        if missing:
            status[stage.name] = {"status": "skipped", "missing": missing}
            continue
        started = time.perf_counter()
        try:
            result = stage.run(ctx)
            unexpected = set(result.products) - set(stage.provides)
            if unexpected:
                raise ValueError(f"returned undeclared products {sorted(unexpected)}")
            ctx.products.update(result.products)
            if result.summary:
                summary[stage.name] = result.summary
            notices.extend(result.notices)
            status[stage.name] = {"status": "ok", "seconds": round(time.perf_counter() - started, 3),
                                  "provided": sorted(result.products)}
        except Exception as error:  # noqa: BLE001 - one stage must never sink the others
            log.error("stage %s failed\n%s", stage.name, traceback.format_exc())
            status[stage.name] = {"status": "failed", "seconds": round(time.perf_counter() - started, 3),
                                  "error": f"{type(error).__name__}: {error}"}
            notices.append(f"Stage {stage.name} failed: {type(error).__name__}: {error}")
    analysis = {
        "schema_version": ANALYSIS_SCHEMA_VERSION,
        "scan_id": ctx.scan_id,
        "frame": FRAME,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "worker": {"name": "inview-worker", "version": __version__, "opencv": cv2.__version__},
        "sources": ctx.inputs.sources,
        "stages": status,
        "summary": summary,
        "notices": notices,
    }
    for name, product in ctx.products.items():
        if product.json is not None and name not in analysis:
            analysis[name] = product.json
    return analysis

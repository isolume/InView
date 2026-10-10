"""Accessibility routing profiles: hard requirements (backend semantics) plus optional soft costs.

Hard requirements are filters and are never relaxed. Soft costs only reorder eligible edges (a
multiplier >= 1 on travel seconds), so `estimated_seconds` always reports unpenalised travel time.
Screening language only: a profile describes what was measured, not a certified accessible route.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from ..contracts import Thresholds
from .graph import Edge, Requirements


@dataclass(frozen=True)
class EdgeContext:
    """Features near an edge, computed once per graph from optional upstream products."""
    landmarks: int = 0                  # signs / places / doors within reach of the path
    hazard_severity: str | None = None  # worst hazard within reach: "barrier" | "warning"


@dataclass(frozen=True)
class Profile:
    name: str
    requirements: Requirements
    speed_mps: float
    description: str
    soft_costs: dict[str, float] = field(default_factory=dict)

    def multiplier(self, edge: Edge, context: EdgeContext) -> float:
        costs = self.soft_costs
        if not costs:
            return 1.0
        factor = 1.0
        width = edge.clear_width_m
        preferred = costs.get("preferred_width_m", 1.5)
        if width is None:
            factor += costs.get("unknown_width", 0.0)
        elif width < preferred:
            factor += costs.get("narrow", 0.0) * (preferred - width) / preferred
        if edge.kind == "surface" and context.landmarks == 0 and edge.length_m > 2.0:
            factor += costs.get("no_landmarks", 0.0)
        if context.hazard_severity is not None:
            factor += costs.get(f"hazard_{context.hazard_severity}", 0.0)
        if edge.kind == "transition":
            factor += costs.get(f"connector_{edge.connector}", 0.0)
        return factor

    def to_json(self) -> dict[str, Any]:
        return {"requirements": self.requirements.to_json(), "movement_speed_mps": self.speed_mps,
                "description": self.description, "soft_costs": dict(sorted(self.soft_costs.items()))}


WHEELCHAIR = Profile(
    "wheelchair",
    Requirements(True, Thresholds.ROUTE_MIN_CLEAR_M, Thresholds.RAMP_MAX_SLOPE),
    0.8,
    "Measured step-free edges at least 0.915 m clear with slope at most 1:12 (screening).",
)
AMBULATORY = Profile("ambulatory", Requirements(), 1.2, "Any available edge, including stairs.")
LOW_VISION = Profile(
    "low_vision",
    Requirements(),
    1.0,
    "Any available edge; prefers wider, landmark-rich edges and avoids reported hazards.",
    {"preferred_width_m": 1.5, "narrow": 0.6, "unknown_width": 0.3, "no_landmarks": 0.25,
     "hazard_barrier": 3.0, "hazard_warning": 0.75, "connector_escalator": 1.0, "connector_stairs": 0.25},
)
DEFAULT_PROFILES: tuple[Profile, ...] = (WHEELCHAIR, AMBULATORY, LOW_VISION)

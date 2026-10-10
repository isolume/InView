"""Routing, turn-by-turn guidance and localized instructions over the navigation graph.

- `graph`: backend Graph v1 view with the backend's eligibility rules.
- `planner`: Dijkstra with backend search-order parity.
- `profiles`: wheelchair / ambulatory / low-vision requirements and soft costs.
- `endpoints`: places, region centroids or graph extremities, and bounded pair selection.
- `maneuvers`: language-neutral steps (turns, doors, hazards, landmarks, arrival side).
- `i18n` + `locales/*.json`: ICU-style messages, CLDR plurals, number formats, RTL isolation.
- `render`: neutral steps to localized text; `build`: the `routes` product.
"""
from .build import build_routes
from .graph import NavGraph, Requirements
from .planner import find_route
from .profiles import AMBULATORY, DEFAULT_PROFILES, LOW_VISION, WHEELCHAIR, Profile

__all__ = ["AMBULATORY", "DEFAULT_PROFILES", "LOW_VISION", "WHEELCHAIR", "NavGraph", "Profile", "Requirements",
           "build_routes", "find_route"]

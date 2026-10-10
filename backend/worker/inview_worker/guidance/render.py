"""Turn neutral steps into localized `RouteStep`s ({text, distance_m, maneuver, position_m, landmark})."""
from __future__ import annotations

from typing import Any

from .endpoints import Endpoint
from .i18n import Locale, Number

TURNS = frozenset({"slight_left", "left", "slight_right", "right", "u_turn", "straight"})
NO_CONTINUATION = frozenset({"arrive", "caution"})


def _localized_name(names: dict[str, str] | None, name: str | None, language: str) -> str | None:
    names = names or {}
    if names.get(language):
        return names[language]
    for key in sorted(names):
        if key.split("-")[0].lower() == language and names[key]:
            return names[key]
    return name or None


def endpoint_name(endpoint: Endpoint | None, locale: Locale) -> str | None:
    """Localized name for an origin/destination, or None when nothing meaningful is known."""
    if endpoint is None:
        return None
    name = _localized_name(endpoint.names, endpoint.name, locale.language)
    if name:
        return locale.isolate(name)
    if endpoint.category in locale.tables.get("place_phrases", {}) and endpoint.category != "unknown":
        return locale.table("place_phrases", endpoint.category)
    return None


def landmark_phrase(landmark: dict[str, Any] | None, locale: Locale) -> str | None:
    if not landmark:
        return None
    kind = landmark.get("kind")
    if kind == "sign":
        if landmark.get("text"):
            return locale.message("landmark.sign_text", text=locale.isolate(landmark["text"]))
        categories = locale.tables.get("sign_categories", {})
        if landmark.get("category") in categories:
            return locale.message("landmark.sign_category", category=categories[landmark["category"]])
        return locale.message("landmark.sign")
    if kind == "door":
        return locale.message("landmark.door")
    name = _localized_name(landmark.get("names"), landmark.get("name"), locale.language)
    if name:
        return locale.isolate(name)
    return locale.table("place_phrases", landmark.get("category", "other"))


def distance(locale: Locale, meters: float, key: str = "distance") -> str:
    return locale.message(key, n=Number(max(1, round(meters)), 0))


def _clause(step: dict[str, Any], locale: Locale, origin: Endpoint | None, destination: Endpoint | None,
            landmark: str | None) -> str:
    maneuver = step["maneuver"]
    if maneuver == "depart":
        name = endpoint_name(origin, locale)
        return locale.message("clause.depart", origin=name) if name else locale.message("clause.depart_plain")
    if maneuver in TURNS:
        turn = locale.message("clause.turn", maneuver=maneuver)
        if landmark:
            relation = (step.get("landmark") or {}).get("relation", "after")
            return locale.message(f"clause.turn_{relation}", turn=turn, landmark=landmark)
        return turn
    if maneuver == "pass_door":
        door = step.get("door") or {}
        width = door.get("measured_clear_width_m") or door.get("nominal_width_m")
        if door.get("meets_clear_width") is False and width:
            return locale.message("clause.door_narrow", width=locale.message("width", w=Number(width, 2)))
        return locale.message("clause.door")
    if maneuver == "caution":
        hazard = step.get("hazard") or {}
        return locale.message("clause.caution", hazard=locale.table("hazards", hazard.get("kind", "other")),
                              ahead=distance(locale, hazard.get("ahead_m", 0.0), "distance_ahead"))
    if maneuver == "arrive":
        name = endpoint_name(destination, locale) or locale.table("place_phrases", "other")
        side = step.get("side")
        if side:
            return locale.message("clause.arrive_side", destination=name, side=side)
        return locale.message("clause.arrive", destination=name)
    connector = step.get("connector") or {}
    return locale.message("clause.transition", connector=connector.get("kind") or "other",
                          direction=connector.get("direction") or "other",
                          floor=locale.isolate(str(connector.get("to_floor_id", ""))))


def localize(steps: list[dict[str, Any]], locale: Locale, origin: Endpoint | None,
             destination: Endpoint | None) -> list[dict[str, Any]]:
    out = []
    for step in steps:
        landmark = landmark_phrase(step.get("landmark"), locale)
        clause = _clause(step, locale, origin, destination, landmark)
        if step["maneuver"] not in NO_CONTINUATION and step["distance_m"] >= 1.0:
            text = locale.message("sentence.continue", clause=clause, distance=distance(locale, step["distance_m"]))
        else:
            text = locale.message("sentence.plain", clause=clause)
        out.append({"text": locale.finish(text), "distance_m": step["distance_m"], "maneuver": step["maneuver"],
                    "position_m": step["position_m"], "landmark": landmark})
    return out

"""Sign semantics and accessibility screening: category, i18n, mounting, legibility, contrast.

All checks are screening of image/depth evidence against published rules of thumb (2010 ADA
Standards §703, WCAG 2.x contrast); they are not certification.
"""
from __future__ import annotations

from ..contracts import PlaceCategory, Thresholds
from .legend import CONTRAST_GRAPHICS_MIN

INCH, FOOT = 0.0254, 0.3048
VISUAL_CHAR_MIN_HEIGHT_M = 40 * INCH        # §703.5.6: visual characters ≥ 40 in above the floor
# Categories for which ADA §216 expects a tactile (raised + braille) sign at the door/room.
TACTILE_EXPECTED = {PlaceCategory.EXIT.value, PlaceCategory.EMERGENCY_EXIT.value, PlaceCategory.RESTROOM.value,
                    PlaceCategory.ACCESSIBLE_RESTROOM.value, PlaceCategory.STAIRS.value}
RESTROOM_PICTOGRAMS = {"man", "woman", "all_gender"}
PICTOGRAM_CATEGORY = (  # priority order
    ("exit_running_person", PlaceCategory.EMERGENCY_EXIT.value),
    ("first_aid", PlaceCategory.FIRST_AID.value),
    ("fire_extinguisher", PlaceCategory.FIRE_EXTINGUISHER.value),
    ("elevator", PlaceCategory.ELEVATOR.value),
    ("stairs", PlaceCategory.STAIRS.value),
    ("information", PlaceCategory.INFORMATION.value),
)
TEXT_PRIORITY = ("emergency_exit", "exit", "first_aid", "fire_extinguisher", "accessible_restroom", "restroom",
                 "elevator", "escalator", "stairs", "ramp", "entrance", "information", "reception", "water_fountain")
DIRECTIONAL, INFORMATIONAL = "directional", "informational"


def resolve_pictograms(names, arrow_directions) -> list[str]:
    """Template names -> reported pictograms (stairs gain up/down from an accompanying arrow)."""
    out = set(names)
    if "stairs" in out:
        ups = any(d.startswith("up") for d in arrow_directions)
        downs = any(d.startswith("down") for d in arrow_directions)
        if ups != downs:
            out.discard("stairs")
            out.add("stairs_up" if ups else "stairs_down")
    return sorted(out)


def infer_category(pictograms, arrow_directions, color: str | None, text_categories, has_text: bool):
    """Returns (category, confidence, evidence)."""
    pictos = {("stairs" if p.startswith("stairs") else p) for p in pictograms}
    evidence = [f"pictogram:{p}" for p in sorted(pictograms)]
    evidence += [f"text:{c}" for c in sorted(set(text_categories))]
    if color:
        evidence.append(f"plate_color:{color}")
    if arrow_directions:
        evidence.append(f"arrows:{len(arrow_directions)}")
    for name, category in PICTOGRAM_CATEGORY:
        if name in pictos:
            return category, 0.9 if category in text_categories else 0.8, evidence
    if pictos & RESTROOM_PICTOGRAMS:
        accessible = "wheelchair" in pictos or "accessible_restroom" in text_categories
        return (PlaceCategory.ACCESSIBLE_RESTROOM.value if accessible else PlaceCategory.RESTROOM.value), 0.85, evidence
    for category in TEXT_PRIORITY:
        if category in text_categories:
            if category == "restroom" and "wheelchair" in pictos:
                return PlaceCategory.ACCESSIBLE_RESTROOM.value, 0.75, evidence
            return category, 0.7, evidence
    if arrow_directions:
        return DIRECTIONAL, 0.7, evidence
    if color in {"red", "green"} and not pictos:
        # Legacy plate heuristic: a red/green plate with a legend is most often an exit sign.
        return PlaceCategory.EXIT.value, 0.5 if has_text else 0.35, evidence
    return INFORMATIONAL, 0.4 if (has_text or pictos) else 0.2, evidence


def min_character_height_m(baseline_height_m: float, viewing_distance_m: float) -> float:
    """ADA 2010 §703.5.5 Table 703.5.5 minimum visual character height (uppercase "I")."""
    if baseline_height_m <= 70 * INCH:
        base, start = 5 / 8 * INCH, 6 * FOOT
    elif baseline_height_m <= 120 * INCH:
        base, start = 2 * INCH, 15 * FOOT
    else:
        base, start = 3 * INCH, 21 * FOOT
    return base + max(0.0, viewing_distance_m - start) / FOOT * (INCH / 8)


def tactile_range_issues(low_baseline: float | None, high_baseline: float | None, mounting: float | None,
                         basis: str) -> list[str]:
    low_limit, high_limit = Thresholds.TACTILE_SIGN_BASELINE_M
    issues = []
    if high_baseline is not None and high_baseline > high_limit:
        where = f"mounted {mounting:.2f} m" if mounting is not None else "mounted"
        issues.append(f"{where} ({basis} {high_baseline:.2f} m), above the {low_limit:.2f}–{high_limit:.2f} m "
                      f"tactile range (ADA 703.4.1)")
    if low_baseline is not None and low_baseline < low_limit:
        issues.append(f"{basis} {low_baseline:.2f} m, below the {low_limit:.2f}–{high_limit:.2f} m tactile range "
                      f"(ADA 703.4.1)")
    return issues


def assess(sign: dict) -> tuple[list[str], list[str]]:
    """Issues (measured problems) and notes (unverifiable or advisory) for a merged sign."""
    issues, notes = [], []
    if sign.get("kind") == "text_region":
        return issues, ["Free-standing text line, not a sign plate: not screened as a sign."]
    category = sign.get("category")
    pictos = sign.get("pictograms") or []
    has_text = bool(sign.get("text_lines") or sign.get("text_ids") or sign.get("text"))
    contrast = sign.get("contrast_ratio")
    if contrast is not None and contrast < CONTRAST_GRAPHICS_MIN:
        issues.append(f"low contrast {contrast:.1f}:1 < {CONTRAST_GRAPHICS_MIN:.0f}:1 (WCAG 2.x minimum for "
                      f"graphics and large text)")
    if has_text and not pictos and category != DIRECTIONAL:
        issues.append("text-only sign, no pictogram (not language-independent)")
    if set(pictos) & RESTROOM_PICTOGRAMS and not has_text:
        issues.append("pictogram without a text descriptor (ADA 703.6.3 requires one directly below)")

    heights = sign.get("heights_m") or {}
    mounting = sign.get("mounting_height_m")
    if mounting is None:
        notes.append("Mounting height unknown (no floor height or depth under the sign).")
    elif category in TACTILE_EXPECTED or sign.get("braille"):
        if heights.get("text_baseline_low") is not None:
            low, high, basis = heights["text_baseline_low"], heights["text_baseline_high"], "text baseline"
        else:
            low, high, basis = heights.get("bottom"), heights.get("bottom"), "bottom edge"
        tactile = tactile_range_issues(low, high, mounting, basis)
        bottom = heights.get("bottom")
        overhead = bottom is not None and bottom >= Thresholds.HEADROOM_MIN_M
        if sign.get("braille") or not overhead:
            # Braille, or a sign within reach of a standing person (below 2.03 m): it is acting as a
            # tactile/door sign, so the 703.4.1 range applies.
            issues += tactile
        else:
            notes += [f"Overhead sign: {t}; overhead visual signs are exempt." for t in tactile]
        if tactile and not sign.get("braille"):
            notes.append("Exit doors, restrooms and stairs also need a tactile sign with braille at "
                         "1.22-1.52 m (ADA 216, 703.4.1); verify on site.")
    if heights.get("text_baseline_low") is not None and heights["text_baseline_low"] < VISUAL_CHAR_MIN_HEIGHT_M \
            and not sign.get("braille"):
        issues.append(f"visual characters {heights['text_baseline_low']:.2f} m above the floor, below "
                      f"{VISUAL_CHAR_MIN_HEIGHT_M:.2f} m (ADA 703.5.6)")

    legibility = sign.get("legibility")
    if legibility and legibility.get("meets") is False:
        issues.append(f"characters ~{legibility['char_height_m'] * 100:.1f} cm tall, below "
                      f"~{legibility['required_min_char_height_m'] * 100:.1f} cm for viewing at "
                      f"{legibility['viewing_distance_m']:.1f} m (ADA 703.5.5)")
    if category in TACTILE_EXPECTED and not sign.get("braille"):
        notes.append("Braille not detected in imagery (often invisible in photos); verify by touch.")
    return issues, notes

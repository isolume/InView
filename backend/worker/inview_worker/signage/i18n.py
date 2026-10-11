"""Script and language evidence for sign text (deterministic, offline, no models).

Scripts come from Unicode code-point ranges (ISO 15924 codes). Languages come from the upstream text
observation when it carries one, otherwise from a small multilingual wayfinding lexicon that also
gives a category hint ("SALIDA" -> exit, es). Unknown words yield no language rather than a guess.
"""
from __future__ import annotations

import unicodedata

from ..semantics.place_lexicon import load

SCRIPT_RANGES = (
    ("Latn", [(0x0041, 0x024F), (0x1E00, 0x1EFF)]),
    ("Grek", [(0x0370, 0x03FF)]),
    ("Cyrl", [(0x0400, 0x04FF)]),
    ("Hebr", [(0x0590, 0x05FF)]),
    ("Arab", [(0x0600, 0x06FF), (0x0750, 0x077F), (0xFB50, 0xFDFF), (0xFE70, 0xFEFF)]),
    ("Deva", [(0x0900, 0x097F)]),
    ("Thai", [(0x0E00, 0x0E7F)]),
    ("Hang", [(0x1100, 0x11FF), (0x3130, 0x318F), (0xAC00, 0xD7AF)]),
    ("Hira", [(0x3040, 0x309F)]),
    ("Kana", [(0x30A0, 0x30FF)]),
    ("Hani", [(0x4E00, 0x9FFF), (0x3400, 0x4DBF)]),
)

# Script-only language hints (when the lexicon has no entry and no upstream language is given).
SCRIPT_LANGUAGE = {"Hang": "ko", "Hira": "ja", "Kana": "ja", "Thai": "th", "Hebr": "he", "Grek": "el"}


def scripts(text: str) -> list[str]:
    found = set()
    for char in text:
        code = ord(char)
        for name, ranges in SCRIPT_RANGES:
            if any(low <= code <= high for low, high in ranges) and unicodedata.category(char).startswith("L"):
                found.add(name)
                break
    return sorted(found)


def lexicon_hits(text: str) -> list[tuple[str, str, str | None]]:
    """Non-negated readings from the same vocabulary used to create places."""
    lexicon = load()
    hits = {}
    for match in lexicon.match_terms(text):
        languages = lexicon.languages_of(match.term)
        hits[(match.term, match.category)] = (
            match.term, match.category, languages[0] if len(languages) == 1 else None)
    return sorted(hits.values(), key=lambda h: (-len(h[0]), h[0], h[1]))


def excluded_categories(text: str) -> set[str]:
    """Negative text also vetoes pictogram/color hints for that sign's category."""
    return load().vetoes(text)


def languages(text: str, declared: str | None = None) -> list[str]:
    if declared:
        return [declared.split("-")[0].lower()]
    found = {language for _, _, language in lexicon_hits(text) if language}
    if not found:
        found = {SCRIPT_LANGUAGE[s] for s in scripts(text) if s in SCRIPT_LANGUAGE}
    return sorted(found)

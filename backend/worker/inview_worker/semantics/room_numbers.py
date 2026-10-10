"""Room numbers in sign/label text: "Room 214", "Rm 3.12", "B-204", "Salle 12", "301号室", "غرفة ٢١٤".

Prefixed and suffixed forms come from the lexicon (`room.prefixes` / `room.suffixes`). A bare
code must be the whole text, follow `^[A-Z]{0,2}-?\\d{1,4}[A-Z]?$` and carry at least two digits,
so floor indicators ("B1", "L2") and stray single digits are not mistaken for rooms.
"""
from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from functools import lru_cache

from .place_lexicon import Lexicon, load, normalize

_NUMBER = r"[a-z]{0,2}-?\d{1,4}(?:[.-]\d{1,3})?[a-z]?"
_BARE = re.compile(r"[a-z]{0,2}-?\d{1,4}[a-z]?")
_LEAD = r"(?:no\.?|nr\.?|n°|nº|#|numero|num\.?)?"

PREFIXED_CONFIDENCE = 0.9
SUFFIXED_CONFIDENCE = 0.9
BARE_CONFIDENCE = 0.55


@dataclass(frozen=True)
class RoomNumber:
    number: str             # canonical, upper case: "214", "3.12", "B-204"
    confidence: float       # lexical confidence that this is a room identifier
    language: str | None    # language of the prefix/suffix word, if any


def _ascii_digits(text: str) -> str:
    return "".join(str(unicodedata.decimal(c)) if c.isdecimal() and not c.isascii() else c for c in text)


@lru_cache(maxsize=1)
def _patterns() -> tuple[list[tuple[str, re.Pattern]], list[tuple[str, re.Pattern]]]:
    lexicon: Lexicon = load()
    prefixed, suffixed = [], []
    for language, words in sorted(lexicon.room_prefixes.items()):
        alternatives = "|".join(re.escape(w) for w in sorted(set(words), key=len, reverse=True))
        prefixed.append((language, re.compile(
            rf"(?<![a-z0-9])({alternatives})\.?\s*{_LEAD}\s*({_NUMBER})(?![a-z0-9])")))
    for language, words in sorted(lexicon.room_suffixes.items()):
        alternatives = "|".join(re.escape(w) for w in sorted(set(words), key=len, reverse=True))
        suffixed.append((language, re.compile(rf"(?<![a-z0-9.-])第?\s*({_NUMBER})\s*({alternatives})(?![\uac00-\ud7af\u3040-\u30ff\u4e00-\u9fff])")))
    return prefixed, suffixed


def _unique(language: str, word: str, table: dict[str, tuple[str, ...]]) -> str | None:
    """`language` only when `word` belongs to no other language ("sala" is es and pt, "室" zh and ja)."""
    owners = [lang for lang, words in table.items() if word in words]
    return language if owners == [language] else None


def _canonical(number: str) -> str:
    return number.upper()


def parse(text: str) -> RoomNumber | None:
    """The room number named by `text`, or None."""
    normalized = _ascii_digits(normalize(text))
    if not normalized:
        return None
    prefixed, suffixed = _patterns()
    lexicon = load()
    for language, pattern in prefixed:
        found = pattern.search(normalized)
        if found:
            language = _unique(language, found.group(1), lexicon.room_prefixes)
            return RoomNumber(_canonical(found.group(2)), PREFIXED_CONFIDENCE, language)
    for language, pattern in suffixed:
        found = pattern.search(normalized)
        if found:
            language = _unique(language, found.group(2), lexicon.room_suffixes)
            return RoomNumber(_canonical(found.group(1)), SUFFIXED_CONFIDENCE, language)
    # Whole text only: "10:30" / "12/24" normalise to "10 30" / "12 24" and must not glue together.
    if _BARE.fullmatch(normalized) and sum(c.isdigit() for c in normalized) >= 2:
        return RoomNumber(_canonical(normalized), BARE_CONFIDENCE, None)
    return None


def display_names(number: str) -> dict[str, str]:
    """Per-language names for a numbered room ("Room 214", "Salle 214", "214号室", ...)."""
    return {language: template.format(n=number) for language, template in load().room_names.items()}

"""Multilingual place vocabulary: normalise sign/label text and match it to place categories.

The vocabulary itself is data (`place_lexicon.json`). Matching is deterministic and offline:
- Latin-script terms match on word boundaries after accents are stripped and case folded, so
  "BAÑOS", "Baños" and "banos" agree, while "exit" does not fire inside "exiting".
- CJK, kana, Hangul, Arabic and Devanagari terms match as substrings (no spaces between words or
  attached particles), except one-character terms, which must be the whole text.
- Longer matches shadow the shorter matches they contain ("emergency exit" beats "exit").
- Negations ("NOT AN EXIT", "sin salida", "立入禁止") veto their category.
"""
from __future__ import annotations

import json
import re
import unicodedata
from dataclasses import dataclass
from functools import lru_cache
from importlib import resources

_ARABIC_DIACRITICS = re.compile("[ؐ-ًؚ-ٰٟۖ-ۭـ]")
_ARABIC_LETTERS = str.maketrans({"أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا", "ة": "ه", "ى": "ي"})
_SPACES = re.compile(r"[\s_/|·•:;,!?()\[\]{}\"“”«»]+")
_LATIN_WORD = "a-z0-9"


@dataclass(frozen=True)
class LexiconMatch:
    category: str
    language: str        # BCP-47 language of the matched term
    term: str            # normalised term
    weight: float        # 0..1 lexical specificity (1 = unambiguous)
    exact: bool          # the whole text is the term


def _strip_latin_accents(text: str) -> str:
    out = []
    for char in unicodedata.normalize("NFD", text):
        if unicodedata.combining(char) and out and out[-1].isascii():
            continue  # accent on a Latin base letter
        out.append(char)
    return unicodedata.normalize("NFC", "".join(out))


def normalize(text: str) -> str:
    """Comparable form: NFKC (full-width → ASCII), case folded, Latin accents removed (ß → ss),
    Arabic diacritics/tatweel removed and letter variants unified, punctuation collapsed to spaces."""
    text = unicodedata.normalize("NFKC", text or "").casefold()
    text = _strip_latin_accents(text)
    text = _ARABIC_DIACRITICS.sub("", text).translate(_ARABIC_LETTERS)
    text = text.replace("’", "'").replace("‘", "'")
    return _SPACES.sub(" ", text).strip(" .-")


def script(text: str) -> str | None:
    """Dominant ISO 15924 script of the letters in `text` (Jpan when any kana is present)."""
    counts: dict[str, int] = {}
    for char in text or "":
        code = ord(char)
        if 0x3040 <= code <= 0x30FF or 0x31F0 <= code <= 0x31FF:
            name = "Kana"
        elif 0x4E00 <= code <= 0x9FFF or 0x3400 <= code <= 0x4DBF or 0xF900 <= code <= 0xFAFF:
            name = "Hani"
        elif 0xAC00 <= code <= 0xD7AF or 0x1100 <= code <= 0x11FF or 0x3130 <= code <= 0x318F:
            name = "Hang"
        elif 0x0600 <= code <= 0x06FF or 0x0750 <= code <= 0x077F or 0xFB50 <= code <= 0xFEFF:
            name = "Arab"
        elif 0x0900 <= code <= 0x097F:
            name = "Deva"
        elif 0x0400 <= code <= 0x04FF:
            name = "Cyrl"
        elif char.isalpha():
            name = "Latn"
        else:
            continue
        counts[name] = counts.get(name, 0) + 1
    if not counts:
        return None
    if counts.get("Kana"):
        return "Jpan"
    return max(sorted(counts), key=counts.get)


def _is_latin(term: str) -> bool:
    return all(c.isascii() for c in term)


def _pattern(term: str) -> re.Pattern:
    escaped = re.escape(term).replace(r"\ ", r"\s+")
    if _is_latin(term):
        return re.compile(rf"(?<![{_LATIN_WORD}]){escaped}(?![{_LATIN_WORD}])")
    return re.compile(escaped)


@dataclass(frozen=True)
class _Term:
    category: str
    language: str
    term: str
    weight: float
    pattern: re.Pattern


@dataclass(frozen=True)
class Lexicon:
    languages: tuple[str, ...]
    terms: tuple[_Term, ...]
    negations: tuple[_Term, ...]
    names: dict[str, dict[str, str]]       # category -> language -> display name
    room_names: dict[str, str]             # language -> "Room {n}" template
    room_prefixes: dict[str, tuple[str, ...]]
    room_suffixes: dict[str, tuple[str, ...]]
    room_labels: dict[str, str | None]

    def vetoes(self, text: str) -> set[str]:
        """Categories explicitly denied by the text, including their more general/specific forms."""
        normalized = normalize(text)
        vetoed = {n.category for n in self.negations if n.pattern.search(normalized)}
        for family in ({"exit", "emergency_exit"}, {"restroom", "accessible_restroom"}):
            if vetoed & family:
                vetoed.update(family)
        return vetoed

    def match_terms(self, text: str) -> list[LexiconMatch]:
        """Non-vetoed term readings, retaining bilingual evidence for the same category."""
        normalized = normalize(text)
        if not normalized:
            return []
        vetoed = self.vetoes(text)
        hits: list[tuple[int, int, _Term]] = []
        for term in self.terms:
            if term.category in vetoed:
                continue
            if len(term.term) == 1:
                if normalized == term.term:
                    hits.append((0, len(normalized), term))
                continue
            for found in term.pattern.finditer(normalized):
                hits.append((found.start(), found.end(), term))
        # Drop matches strictly inside a longer match of another category or term.
        kept = [h for h in hits if not any(o[0] <= h[0] and h[1] <= o[1] and (o[1] - o[0]) > (h[1] - h[0])
                                           for o in hits)]
        order = {language: index for index, language in enumerate(self.languages)}
        matches: dict[tuple[str, str, str], LexiconMatch] = {}
        for start, end, term in sorted(kept, key=lambda h: (-h[2].weight, order.get(h[2].language, 99), h[0])):
            exact = start == 0 and end == len(normalized)
            candidate = LexiconMatch(term.category, term.language, term.term, term.weight, exact)
            key = (term.category, term.language, term.term)
            current = matches.get(key)
            if current is None or (candidate.weight, candidate.exact) > (current.weight, current.exact):
                matches[key] = candidate
        return list(matches.values())

    def match(self, text: str) -> list[LexiconMatch]:
        """Non-vetoed category matches, strongest first; one match per category."""
        best: dict[str, LexiconMatch] = {}
        for candidate in self.match_terms(text):
            category = candidate.category
            current = best.get(category)
            if current is None or (candidate.weight, candidate.exact) > (current.weight, current.exact):
                best[category] = candidate
        return sorted(best.values(), key=lambda m: (-m.weight, -m.exact, m.category))

    def languages_of(self, normalized_term: str) -> list[str]:
        """Languages whose vocabulary contains the term, in lexicon order."""
        found = {t.language for t in self.terms if t.term == normalized_term}
        return [language for language in self.languages if language in found] + sorted(found - set(self.languages))

    def display_names(self, category: str) -> dict[str, str]:
        return dict(self.names.get(category, {}))


def _entries(raw: dict, category: str) -> list[tuple[str, str, float]]:
    out = []
    for language, words in sorted(raw.items()):
        for word in words:
            term, weight = (word, 1.0) if isinstance(word, str) else (word[0], float(word[1]))
            out.append((language, normalize(term), weight))
    return out


@lru_cache(maxsize=1)
def load() -> Lexicon:
    raw = json.loads(resources.files(__package__).joinpath("place_lexicon.json").read_text("utf-8"))
    terms, negations, names = [], [], {}
    for category, spec in raw["categories"].items():
        names[category] = dict(spec.get("names", {}))
        for language, term, weight in _entries(spec.get("terms", {}), category):
            terms.append(_Term(category, language, term, weight, _pattern(term)))
        for language, term, weight in _entries(spec.get("negations", {}), category):
            negations.append(_Term(category, language, term, weight, _pattern(term)))
    room = raw["room"]
    return Lexicon(
        languages=tuple(raw["languages"]),
        terms=tuple(terms),
        negations=tuple(negations),
        names=names,
        room_names=dict(room["names"]),
        room_prefixes={k: tuple(normalize(p) for p in v) for k, v in room["prefixes"].items()},
        room_suffixes={k: tuple(normalize(s) for s in v) for k, v in room["suffixes"].items()},
        room_labels={k: v for k, v in raw["room_labels"].items() if not k.startswith("_")},
    )

"""Script and language evidence for sign text (deterministic, offline, no models).

Scripts come from Unicode code-point ranges (ISO 15924 codes). Languages come from the upstream text
observation when it carries one, otherwise from a small multilingual wayfinding lexicon that also
gives a category hint ("SALIDA" -> exit, es). Unknown words yield no language rather than a guess.
"""
from __future__ import annotations

import re
import unicodedata

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

# word/phrase (casefolded, accents kept) -> (category, BCP-47 language or None when shared)
LEXICON: dict[str, tuple[str, str | None]] = {
    "exit": ("exit", "en"), "way out": ("exit", "en"), "emergency exit": ("emergency_exit", "en"),
    "fire exit": ("emergency_exit", "en"), "salida": ("exit", "es"), "salida de emergencia": ("emergency_exit", "es"),
    "sortie": ("exit", "fr"), "sortie de secours": ("emergency_exit", "fr"), "ausgang": ("exit", "de"),
    "notausgang": ("emergency_exit", "de"), "uscita": ("exit", "it"), "saída": ("exit", "pt"), "uitgang": ("exit", "nl"),
    "выход": ("exit", "ru"), "出口": ("exit", None), "非常口": ("emergency_exit", "ja"), "安全出口": ("emergency_exit", "zh"),
    "비상구": ("emergency_exit", "ko"), "출구": ("exit", "ko"), "مخرج": ("exit", "ar"), "יציאה": ("exit", "he"),
    "entrance": ("entrance", "en"), "entrada": ("entrance", None), "entrée": ("entrance", "fr"), "eingang": ("entrance", "de"),
    "入口": ("entrance", None),
    "restroom": ("restroom", "en"), "restrooms": ("restroom", "en"), "toilet": ("restroom", "en"),
    "toilets": ("restroom", "en"), "washroom": ("restroom", "en"), "men": ("restroom", "en"), "women": ("restroom", "en"),
    "ladies": ("restroom", "en"), "gentlemen": ("restroom", "en"), "all gender": ("restroom", "en"),
    "wc": ("restroom", None), "baño": ("restroom", "es"), "baños": ("restroom", "es"), "servicios": ("restroom", "es"),
    "aseos": ("restroom", "es"), "hombres": ("restroom", "es"), "mujeres": ("restroom", "es"), "damas": ("restroom", "es"),
    "caballeros": ("restroom", "es"), "toilettes": ("restroom", "fr"), "toiletten": ("restroom", "de"),
    "туалет": ("restroom", "ru"), "厕所": ("restroom", "zh"), "洗手间": ("restroom", "zh"), "洗手間": ("restroom", "zh"),
    "トイレ": ("restroom", "ja"), "お手洗い": ("restroom", "ja"), "화장실": ("restroom", "ko"), "دورة المياه": ("restroom", "ar"),
    "elevator": ("elevator", "en"), "elevators": ("elevator", "en"), "lift": ("elevator", "en"), "ascensor": ("elevator", "es"),
    "ascenseur": ("elevator", "fr"), "aufzug": ("elevator", "de"), "fahrstuhl": ("elevator", "de"), "лифт": ("elevator", "ru"),
    "电梯": ("elevator", "zh"), "電梯": ("elevator", "zh"), "エレベーター": ("elevator", "ja"), "엘리베이터": ("elevator", "ko"),
    "stairs": ("stairs", "en"), "stairway": ("stairs", "en"), "stair": ("stairs", "en"), "escalera": ("stairs", "es"),
    "escaleras": ("stairs", "es"), "escalier": ("stairs", "fr"), "escaliers": ("stairs", "fr"), "treppe": ("stairs", "de"),
    "лестница": ("stairs", "ru"), "楼梯": ("stairs", "zh"), "樓梯": ("stairs", "zh"), "階段": ("stairs", "ja"), "계단": ("stairs", "ko"),
    "escalator": ("escalator", "en"), "escalera mecánica": ("escalator", "es"),
    "information": ("information", None), "info": ("information", None), "información": ("information", "es"),
    "auskunft": ("information", "de"), "问讯处": ("information", "zh"), "案内所": ("information", "ja"), "안내": ("information", "ko"),
    "reception": ("reception", "en"), "recepción": ("reception", "es"), "réception": ("reception", "fr"),
    "first aid": ("first_aid", "en"), "primeros auxilios": ("first_aid", "es"), "premiers secours": ("first_aid", "fr"),
    "erste hilfe": ("first_aid", "de"), "急救": ("first_aid", "zh"), "救急": ("first_aid", "ja"),
    "fire extinguisher": ("fire_extinguisher", "en"), "extintor": ("fire_extinguisher", None),
    "extincteur": ("fire_extinguisher", "fr"), "feuerlöscher": ("fire_extinguisher", "de"), "消火器": ("fire_extinguisher", "ja"),
    "灭火器": ("fire_extinguisher", "zh"),
    "ramp": ("ramp", "en"), "rampa": ("ramp", None), "rampe": ("ramp", None),
    "water fountain": ("water_fountain", "en"), "drinking water": ("water_fountain", "en"),
}
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


def _normalize(text: str) -> str:
    return " ".join(re.sub(r"[^\w\s]", " ", text.casefold()).split())


def lexicon_hits(text: str) -> list[tuple[str, str, str | None]]:
    """(phrase, category, language) for every lexicon phrase present as whole words (CJK: substring)."""
    norm = _normalize(text)
    padded = f" {norm} "
    hits = []
    for phrase, (category, language) in LEXICON.items():
        cjk = any(s in {"Hani", "Hira", "Kana", "Hang"} for s in scripts(phrase))
        if (phrase in norm) if cjk else (f" {phrase} " in padded):
            hits.append((phrase, category, language))
    # Prefer the longest phrase when one contains another ("emergency exit" over "exit").
    hits.sort(key=lambda h: (-len(h[0]), h[0]))
    kept: list[tuple[str, str, str | None]] = []
    for hit in hits:
        if not any(hit[0] in longer[0] for longer in kept):
            kept.append(hit)
    return kept


def languages(text: str, declared: str | None = None) -> list[str]:
    if declared:
        return [declared.split("-")[0].lower()]
    found = {language for _, _, language in lexicon_hits(text) if language}
    if not found:
        found = {SCRIPT_LANGUAGE[s] for s in scripts(text) if s in SCRIPT_LANGUAGE}
    return sorted(found)

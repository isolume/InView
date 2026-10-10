"""Script (ISO 15924) and language (BCP-47) heuristics from Unicode ranges and a sign lexicon."""
from __future__ import annotations

import re
import unicodedata

# (ISO 15924 code, inclusive code-point ranges)
SCRIPT_RANGES: tuple[tuple[str, tuple[tuple[int, int], ...]], ...] = (
    ("Latn", ((0x0041, 0x005A), (0x0061, 0x007A), (0x00C0, 0x024F), (0x1E00, 0x1EFF))),
    ("Grek", ((0x0370, 0x03FF),)),
    ("Cyrl", ((0x0400, 0x052F),)),
    ("Hebr", ((0x0590, 0x05FF),)),
    ("Arab", ((0x0600, 0x06FF), (0x0750, 0x077F), (0x08A0, 0x08FF), (0xFB50, 0xFDFF), (0xFE70, 0xFEFF))),
    ("Deva", ((0x0900, 0x097F), (0xA8E0, 0xA8FF))),
    ("Thai", ((0x0E00, 0x0E7F),)),
    ("Hang", ((0x1100, 0x11FF), (0x3130, 0x318F), (0xAC00, 0xD7AF))),
    ("Kana", ((0x3040, 0x30FF), (0x31F0, 0x31FF), (0xFF66, 0xFF9F))),
    ("Hani", ((0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xF900, 0xFAFF), (0x20000, 0x2FA1F))),
)

# Default language for scripts that (on signage) almost always mean one language.
SCRIPT_LANGUAGE = {"Grek": "el", "Hebr": "he", "Thai": "th", "Hang": "ko", "Kana": "ja", "Deva": "hi",
                   "Arab": "ar", "Cyrl": "ru", "Hani": "zh"}

# Small wayfinding lexicon: distinctive sign words per language (lowercase, accents kept).
SIGN_WORDS: dict[str, frozenset[str]] = {
    "en": frozenset("exit entrance emergency restroom restrooms toilet toilets men women elevator elevators lift "
                    "stairs stair ramp room floor push pull way out in information reception office no only "
                    "fire extinguisher first aid danger caution keep clear accessible open closed staff private "
                    "this that door level hall corridor lobby kitchen bathroom gate parking".split()),
    "es": frozenset("salida entrada emergencia baño baños servicios ascensor escaleras rampa sala piso planta "
                    "empuje empujar tire jalar información recepción oficina prohibido solo peligro "
                    "precaución abierto cerrado puerta extintor primeros auxilios hombres mujeres".split()),
    "fr": frozenset("sortie entrée secours urgence toilettes ascenseur escalier escaliers rampe salle étage "
                    "poussez tirez accueil bureau interdit danger attention ouvert fermé porte extincteur "
                    "hommes femmes issue".split()),
    "de": frozenset("ausgang eingang notausgang notfall toilette toiletten aufzug treppe treppen rampe raum "
                    "stock etage drücken ziehen information empfang büro verboten gefahr achtung offen "
                    "geschlossen tür feuerlöscher herren damen".split()),
    "it": frozenset("uscita ingresso emergenza bagno bagni ascensore scale rampa sala piano spingere tirare "
                    "informazioni ufficio vietato pericolo aperto chiuso porta estintore uomini donne".split()),
    "pt": frozenset("saída entrada emergência banheiro banheiros elevador escada escadas rampa sala andar "
                    "empurre puxe informações recepção escritório proibido perigo aberto fechado porta "
                    "extintor homens mulheres".split()),
}


def char_script(char: str) -> str | None:
    code = ord(char)
    for script, ranges in SCRIPT_RANGES:
        if any(low <= code <= high for low, high in ranges):
            return script
    return None


def detect_script(text: str) -> str | None:
    """Dominant script by letter count. Han with kana is Japanese (`Jpan`), Han with Hangul `Kore`."""
    counts: dict[str, int] = {}
    for char in text:
        script = char_script(char)
        if script:
            counts[script] = counts.get(script, 0) + 1
    if not counts:
        return None
    if "Kana" in counts and "Hani" in counts:
        counts["Jpan"] = counts.pop("Kana") + counts.pop("Hani")
    elif "Hang" in counts and "Hani" in counts:
        counts["Kore"] = counts.pop("Hang") + counts.pop("Hani")
    return max(sorted(counts), key=lambda s: counts[s])


def detect_language(text: str, script: str | None = None, hints: list[str] | None = None) -> str | None:
    """BCP-47 guess: engine hints first, then the script default, then the Latin sign lexicon."""
    script = script or detect_script(text)
    if hints:
        return hints[0].replace("_", "-")
    if script == "Jpan":
        return "ja"
    if script == "Kore":
        return "ko"
    if script in SCRIPT_LANGUAGE:
        return SCRIPT_LANGUAGE[script]
    if script != "Latn":
        return None
    words = [unicodedata.normalize("NFC", w) for w in re.findall(r"[^\W\d_]+", text.lower())]
    scores = {lang: sum(w in vocab for w in words) for lang, vocab in SIGN_WORDS.items()}
    best = max(scores, key=lambda lang: scores[lang])  # ties go to the earlier (more common) language
    return best if scores[best] > 0 else None

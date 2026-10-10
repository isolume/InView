"""Small, dependency-free subset of ICU MessageFormat for instruction text.

Supported syntax: `{name}`, `{name, number}`, `{name, select, key {..} other {..}}` and
`{name, plural, =0 {..} one {# meter} other {# meters}}` (with `#` replaced by the localized number).
Plural categories follow CLDR cardinal rules for the bundled languages. Apostrophes are literal (no
ICU quoting), so French elision like "l'ascenseur" needs no escaping.

Locale files live in `locales/<lang>.json`:
  {"locale", "name", "direction": "ltr"|"rtl", "number": {"decimal", "group", "digits", "min_grouping"},
   "messages": {key: pattern}, "place_phrases": {category: phrase}, "sign_categories": {...},
   "hazards": {kind: phrase}}
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any

LOCALE_DIR = Path(__file__).with_name("locales")
RLM, FSI, PDI = "‏", "⁨", "⁩"


# --- CLDR cardinal plural rules (integer and decimal operands) -------------------------------

def plural_category(language: str, n: float, fraction_digits: int = 0) -> str:
    i = int(abs(n))
    integer = fraction_digits == 0 and float(n).is_integer()
    if language in ("en", "de"):
        return "one" if i == 1 and fraction_digits == 0 else "other"
    if language == "es":
        return "one" if n == 1 and fraction_digits == 0 else "other"
    if language == "fr":
        return "one" if i in (0, 1) else "other"
    if language == "hi":
        return "one" if i == 0 or n == 1 else "other"
    if language == "ar":
        if not integer:
            return "other"
        mod100 = i % 100
        if i == 0:
            return "zero"
        if i == 1:
            return "one"
        if i == 2:
            return "two"
        if 3 <= mod100 <= 10:
            return "few"
        if 11 <= mod100 <= 99:
            return "many"
        return "other"
    return "other"  # zh and unknown languages


# --- Pattern parsing -------------------------------------------------------------------------

def _parse(pattern: str, pos: int = 0, in_plural: bool = False, depth: int = 0) -> tuple[list, int]:
    nodes: list[Any] = []
    text: list[str] = []
    while pos < len(pattern):
        char = pattern[pos]
        if char == "}" and depth > 0:
            break
        if char == "#" and in_plural:
            if text:
                nodes.append("".join(text))
                text = []
            nodes.append(("#",))
            pos += 1
            continue
        if char == "{":
            if text:
                nodes.append("".join(text))
                text = []
            node, pos = _parse_argument(pattern, pos + 1, depth)
            nodes.append(node)
            continue
        text.append(char)
        pos += 1
    if text:
        nodes.append("".join(text))
    return nodes, pos


def _parse_argument(pattern: str, pos: int, depth: int) -> tuple[tuple, int]:
    end = pos
    while end < len(pattern) and pattern[end] not in ",}":
        end += 1
    if end >= len(pattern):
        raise ValueError(f"Unterminated argument in {pattern!r}")
    name = pattern[pos:end].strip()
    if pattern[end] == "}":
        return ("arg", name), end + 1
    comma = pattern.find(",", end + 1)
    close = pattern.find("}", end + 1)
    if comma == -1 or (close != -1 and close < comma):
        kind = pattern[end + 1:close].strip()
        if kind != "number":
            raise ValueError(f"Unsupported argument type {kind!r} in {pattern!r}")
        return ("number", name), close + 1
    kind = pattern[end + 1:comma].strip()
    if kind not in ("select", "plural"):
        raise ValueError(f"Unsupported argument type {kind!r} in {pattern!r}")
    pos, options = comma + 1, {}
    while True:
        while pos < len(pattern) and pattern[pos].isspace():
            pos += 1
        if pos >= len(pattern):
            raise ValueError(f"Unterminated {kind} in {pattern!r}")
        if pattern[pos] == "}":
            break
        brace = pattern.find("{", pos)
        if brace == -1:
            raise ValueError(f"Missing option body in {pattern!r}")
        key = pattern[pos:brace].strip()
        body, pos = _parse(pattern, brace + 1, kind == "plural", depth + 1)
        if pos >= len(pattern) or pattern[pos] != "}":
            raise ValueError(f"Unterminated option {key!r} in {pattern!r}")
        options[key] = body
        pos += 1
    if "other" not in options:
        raise ValueError(f"{kind} needs an 'other' option in {pattern!r}")
    return (kind, name, options), pos + 1


@lru_cache(maxsize=1024)
def parse(pattern: str) -> tuple:
    nodes, pos = _parse(pattern)
    if pos != len(pattern):
        raise ValueError(f"Unbalanced braces in {pattern!r}")
    return tuple(nodes)


# --- Locale ----------------------------------------------------------------------------------

@dataclass(frozen=True)
class Number:
    """A numeric argument with explicit fraction digits (drives both formatting and plurals)."""
    value: float
    digits: int = 0


@dataclass
class Locale:
    language: str
    direction: str
    number: dict[str, Any]
    messages: dict[str, str]
    tables: dict[str, dict[str, str]] = field(default_factory=dict)

    @property
    def rtl(self) -> bool:
        return self.direction == "rtl"

    def format_number(self, value: float, digits: int = 0) -> str:
        decimal, group = self.number.get("decimal", "."), self.number.get("group", ",")
        min_grouping = int(self.number.get("min_grouping", 1))
        text = f"{abs(value):.{digits}f}"
        whole, _, fraction = text.partition(".")
        if len(whole) >= 3 + min_grouping:
            chunks = []
            while len(whole) > 3:
                chunks.insert(0, whole[-3:])
                whole = whole[:-3]
            whole = group.join([whole, *chunks])
        out = ("-" if value < 0 and float(text) != 0 else "") + whole + (decimal + fraction if fraction else "")
        native = self.number.get("digits")
        if native:
            out = out.translate(str.maketrans("0123456789", native))
        return out

    def isolate(self, text: str) -> str:
        """Bidi-isolate embedded names (e.g. Latin sign text inside Arabic) so punctuation stays put."""
        return f"{FSI}{text}{PDI}" if self.rtl and text else text

    def table(self, name: str, key: str, default: str | None = None) -> str:
        values = self.tables.get(name, {})
        return values.get(key, values.get("other", default if default is not None else key))

    def message(self, key: str, **args: Any) -> str:
        pattern = self.messages.get(key)
        if pattern is None:
            raise KeyError(f"{self.language}: missing message {key!r}")
        return self._render(parse(pattern), args, None)

    def _render(self, nodes: tuple | list, args: dict[str, Any], plural_value: Number | None) -> str:
        out = []
        for node in nodes:
            if isinstance(node, str):
                out.append(node)
            elif node[0] == "#":
                out.append(self.format_number(plural_value.value, plural_value.digits) if plural_value else "#")
            elif node[0] == "arg":
                value = args[node[1]]
                out.append(self.format_number(value.value, value.digits) if isinstance(value, Number) else str(value))
            elif node[0] == "number":
                value = args[node[1]]
                value = value if isinstance(value, Number) else Number(float(value), 0)
                out.append(self.format_number(value.value, value.digits))
            elif node[0] == "select":
                options = node[2]
                out.append(self._render(options.get(str(args[node[1]]), options["other"]), args, plural_value))
            else:  # plural
                value = args[node[1]]
                value = value if isinstance(value, Number) else Number(float(value), 0)
                options = node[2]
                exact = f"={value.value:g}" if value.digits == 0 else None
                body = options.get(exact) if exact in options else options.get(
                    plural_category(self.language, value.value, value.digits), options["other"])
                out.append(self._render(body, args, value))
        return "".join(out)

    def finish(self, text: str) -> str:
        """Final sentence: RTL text gets a leading right-to-left mark for correct base direction."""
        return RLM + text if self.rtl else text


@lru_cache(maxsize=None)
def available_languages() -> tuple[str, ...]:
    return tuple(sorted(path.stem for path in LOCALE_DIR.glob("*.json")))


@lru_cache(maxsize=None)
def load(language: str) -> Locale:
    path = LOCALE_DIR / f"{language}.json"
    if not path.is_file():
        raise KeyError(f"No locale {language!r}; available: {available_languages()}")
    data = json.loads(path.read_text(encoding="utf-8"))
    tables = {key: value for key, value in data.items() if key in ("place_phrases", "sign_categories", "hazards")}
    locale = Locale(language, data.get("direction", "ltr"), data.get("number", {}), data["messages"], tables)
    for pattern in locale.messages.values():
        parse(pattern)  # Fail fast on malformed locale files.
    return locale

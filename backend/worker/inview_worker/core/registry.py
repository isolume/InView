"""Stage and publisher registration with automatic discovery.

Adding a stage means adding a module under `inview_worker/stages/` whose Stage subclass is decorated
with `@register`; adding a publisher means a module under `inview_worker/publishers/` with a function
decorated by `@publisher`. No central list needs editing.
"""
from __future__ import annotations

import importlib
import pkgutil
from typing import Callable

from ..contracts import RESERVED_KEYS
from .stage import Stage

_STAGES: dict[str, type[Stage]] = {}
_PUBLISHERS: dict[str, Callable] = {}


def register(cls: type[Stage]) -> type[Stage]:
    if not cls.name:
        raise ValueError(f"{cls.__qualname__} needs a non-empty `name`")
    reserved = set(cls.provides) & RESERVED_KEYS
    if reserved:
        raise ValueError(f"{cls.name!r} provides reserved analysis keys {sorted(reserved)}")
    existing = _STAGES.get(cls.name)
    if existing is not None and (existing.__module__, existing.__qualname__) != (cls.__module__, cls.__qualname__):
        raise ValueError(f"Stage name {cls.name!r} is already registered by {existing.__module__}.{existing.__qualname__}")
    for other in _STAGES.values():
        if other.name != cls.name and set(other.provides) & set(cls.provides):
            raise ValueError(f"{cls.name!r} and {other.name!r} both provide {set(other.provides) & set(cls.provides)}")
    _STAGES[cls.name] = cls
    return cls


def publisher(function: Callable) -> Callable:
    """`function(backend, scan_id, analysis, products)`; runs after the analysis is stored."""
    _PUBLISHERS[f"{function.__module__}.{function.__qualname__}"] = function
    return function


def _import_all(package: str) -> None:
    module = importlib.import_module(package)
    for info in sorted(pkgutil.iter_modules(module.__path__), key=lambda i: i.name):
        if not info.name.startswith("_"):
            importlib.import_module(f"{package}.{info.name}")


def discover() -> None:
    _import_all("inview_worker.stages")
    _import_all("inview_worker.publishers")


def stages() -> list[Stage]:
    discover()
    return [_STAGES[name]() for name in sorted(_STAGES)]


def publishers() -> list[Callable]:
    discover()
    return [_PUBLISHERS[key] for key in sorted(_PUBLISHERS)]

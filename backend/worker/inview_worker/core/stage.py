"""The unit of work in the pipeline: a Stage consumes named products and provides new ones."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any, ClassVar

if TYPE_CHECKING:
    from .context import ScanContext


@dataclass
class Product:
    """A named stage output.

    `json` is published in the analysis document (must be JSON-serialisable). `data` stays inside
    the worker process for downstream stages: rasters, graphs, model outputs.
    """
    json: Any
    data: Any = None


@dataclass
class StageResult:
    products: dict[str, Product] = field(default_factory=dict)
    summary: dict[str, Any] = field(default_factory=dict)
    notices: list[str] = field(default_factory=list)


class Stage:
    """Subclass, set the class attributes, implement `run`, and decorate with `@register`.

    - `requires`: products that must exist, otherwise the stage is skipped with a notice.
    - `optional`: products used when present; they only influence ordering.
    - `provides`: the products this stage may return (others are rejected).
    Stages must be deterministic for the same inputs and must not mutate other products.
    """

    name: ClassVar[str] = ""
    requires: ClassVar[tuple[str, ...]] = ()
    optional: ClassVar[tuple[str, ...]] = ()
    provides: ClassVar[tuple[str, ...]] = ()

    def run(self, ctx: ScanContext) -> StageResult:  # pragma: no cover - interface
        raise NotImplementedError

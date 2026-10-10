"""RoomPlan semantics: decode Apple's `CapturedRoom` JSON and derive labelled rooms, doors and more.

`parse.load` turns any accepted export shape into a normalised `Capture`; `parse.from_portable`
does the same for the portable capture records; `semantics.build` produces the `roomplan` product.
"""
from .parse import Capture, from_portable, load
from .semantics import build, summarize

__all__ = ["Capture", "build", "from_portable", "load", "summarize"]

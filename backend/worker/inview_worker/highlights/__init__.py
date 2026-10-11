"""Key-aspect highlights: what matters in a scan, ranked, and drawn on its floor plan."""
from .rank import Highlight, Options, collect
from .render import render_scene

__all__ = ["Highlight", "Options", "collect", "render_scene"]

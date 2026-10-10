"""3D terrain screening: 2.5D walking-surface height map and hazards (steps, stairs, ramps, drop-offs,
low headroom, protruding objects). Pure functions; `stages/hazards.py` is the pipeline adapter."""
from .detect import HazardParams, detect
from .elevation import HeightMap, TerrainParams, build, summary
from .profile import segment_profile

__all__ = ["HazardParams", "HeightMap", "TerrainParams", "build", "detect", "segment_profile", "summary"]

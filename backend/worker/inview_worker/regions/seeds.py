"""Watershed markers from the persistence of distance-transform maxima.

Rooms are the wide basins of the free-space distance map; doorways and other constrictions are
its saddles. Sweeping a threshold down the distance map (superlevel sets, `cv2.connectedComponents`
per level) builds a merge tree: whenever two components meet, the younger one (lower peak) is kept
as a separate seed only if it is *persistent* - it rose at least `min_persistence_m` above the saddle
and the saddle is clearly narrower than the younger space (`saddle <= saddle_ratio * peak`).
Otherwise it is a bump of the same space (a furniture notch) and is absorbed by the elder.

Scale-free by construction: a 2.4 m hallway and a 10 m hall both survive behind a 0.9 m doorway,
which a single global threshold cannot achieve.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import cv2
import numpy as np

MAX_LEVELS = 120


@dataclass
class _Seed:
    peak: float
    pixel: int                      # flat index of the maximum
    marker: np.ndarray | None = None  # flat indices of the frozen marker component


@dataclass
class _Group:
    seeds: list[int] = field(default_factory=list)
    peak: float = 0.0


def persistent_markers(dt: np.ndarray, resolution: float, min_level_m: float, min_persistence_m: float,
                       saddle_ratio: float, min_marker_px: int) -> np.ndarray:
    """int32 marker image: 0 = unknown, 1.. = seeds (ordered by descending peak, then position)."""
    markers = np.zeros(dt.shape, np.int32)
    top = float(dt.max()) if dt.size else 0.0
    if top < min_level_m:
        return markers
    # Never coarser than half the persistence: a component born at one level cannot be persistent.
    step = min(max(resolution / 2, (top - min_level_m) / MAX_LEVELS), min_persistence_m / 2)
    levels = np.arange(top - step, min_level_m - 1e-9, -step)
    if not len(levels) or levels[-1] > min_level_m + 1e-9:
        levels = np.append(levels, min_level_m)

    width = dt.shape[1]
    seeds: list[_Seed] = []
    groups: list[_Group] = []
    previous: np.ndarray | None = None
    for level in levels:
        count, labels, stats, _ = cv2.connectedComponentsWithStats((dt >= level).astype(np.uint8), connectivity=8)
        flat_labels = labels.ravel()
        by_component: dict[int, list[int]] = {}
        for g, group in enumerate(groups):
            by_component.setdefault(int(flat_labels[seeds[group.seeds[0]].pixel]), []).append(g)

        # Components without a group are born at this level; their maximum is the new seed
        # (first maximum in row-major order, so ties resolve deterministically).
        for component in range(1, count):
            if component in by_component:
                continue
            x, y, w, h, _ = stats[component]
            crop = np.where(labels[y:y + h, x:x + w] == component, dt[y:y + h, x:x + w], -1.0)
            row, col = np.unravel_index(int(np.argmax(crop)), crop.shape)
            peak = float(crop[row, col])
            seeds.append(_Seed(peak, int((y + row) * width + x + col)))
            groups.append(_Group([len(seeds) - 1], peak))
            by_component[component] = [len(groups) - 1]

        survivors: list[_Group] = []
        for component in sorted(by_component):
            members = sorted((groups[g] for g in by_component[component]), key=lambda g: (-g.peak, g.seeds[0]))
            elder = members[0]
            persistent = [elder] + [g for g in members[1:]
                                    if g.peak - level >= min_persistence_m and level <= saddle_ratio * g.peak]
            if len(persistent) > 1 and previous is not None:
                for group in persistent:   # Freeze markers at the last level before the merge.
                    for s in group.seeds:
                        if seeds[s].marker is None and previous.ravel()[seeds[s].pixel]:
                            seeds[s].marker = np.flatnonzero(previous == previous.ravel()[seeds[s].pixel])
            merged = _Group([s for g in persistent for s in g.seeds], elder.peak)
            survivors.append(merged)
        groups = survivors
        previous = labels

    order_ids = sorted((s for g in groups for s in g.seeds), key=lambda s: (-seeds[s].peak, seeds[s].pixel))
    label = 0
    for s in order_ids:
        seed = seeds[s]
        if seed.marker is not None:
            mask = np.zeros(dt.shape, bool)
            mask.ravel()[seed.marker] = True
        else:
            mask = previous == previous.ravel()[seed.pixel]
        mask &= markers == 0
        if int(mask.sum()) < min_marker_px:
            continue
        label += 1
        markers[mask] = label
    return markers

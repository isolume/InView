#!/usr/bin/env python3
"""Retain compact, reproducible geometry from the supplied Floor 1 scans.

The large camera/depth recordings stay outside the repository. This step does
not register independent AR sessions or turn visual completion into navigation.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "models/walkthrough-building/floor-1-reconstruction"
CAPTURES = [
    "7714E8C3-1C81-47F7-ADBF-A8CD2350FAEC",
    "611423DC-EDB2-4FCE-91B1-F47573C20F8B",
    "081DA781-19B1-4A3F-91BE-8DF0094E5032",
    "785D48F6-4754-46A8-B07D-D001BCAAC621",
    "92ED4CB7-BBE5-45C6-801D-93DDDC72CAEF",
    "3F8FE86D-8F9E-47A8-A010-49417284BD8E",
    "D598D846-F87F-491F-B446-19BA52295D4D",
]
ROOM_FIELDS = ("walls", "doors", "openings", "windows", "floors", "objects")
GEOMETRY_FIELDS = ("identifier", "parentIdentifier", "category", "confidence",
                   "transform", "dimensions", "polygonCorners", "curve", "story")


def read(path):
    return json.loads(path.read_text())


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path.home() / "Downloads")
    parser.add_argument("--output", type=Path, default=OUTPUT)
    args = parser.parse_args()
    manifest = {"schema_version": 1, "display_floor": 1,
                "display_name": "Floor 1", "units": "meters", "up_axis": "y",
                "raised_area": "Auditorium access remains part of Floor 1",
                "connections": "Steps or elevator; no ramp between lower and raised areas",
                "visual_completion_is_routing_coverage": False,
                "captures": []}
    for capture_id in CAPTURES:
        folder = args.source_root / (capture_id + " 2")
        video = read(folder / "video-manifest.json")
        assert video["capture_id"] == capture_id
        rooms = read(folder / "roomplan.json")
        if isinstance(rooms, dict):
            rooms = [rooms]
        raw = read(folder / "raw-snapshot.json")
        capture = read(folder / "capture.json") if (folder / "capture.json").exists() else None
        compact = {
            "capture_id": capture_id, "floor_id": video["floor_id"],
            "metadata": capture.get("metadata", {}) if capture else {},
            "native_rooms": [{key: [{field: item[field] for field in GEOMETRY_FIELDS if field in item}
                                     for item in room.get(key, [])]
                              for key in ROOM_FIELDS} for room in rooms],
            "captured_surfaces": capture.get("surfaces", []) if capture else [],
            "captured_objects": capture.get("objects", []) if capture else [],
            "observed_footprints": raw.get("observedFootprints", []),
            "walk_trace": raw.get("walkTrace"),
            "text_observations": read(folder / "text-observations.json").get("observations", []),
            "native_roomplan_only": capture is None,
        }
        output = args.output / "sources" / (capture_id + ".json")
        write(output, compact)
        sources = {}
        for filename in ("capture.json", "raw-snapshot.json", "roomplan.json", "video-manifest.json",
                         "package-manifest.json", "text-observations.json"):
            path = folder / filename
            if path.exists():
                sources[filename] = {"bytes": path.stat().st_size, "sha256": digest(path)}
        manifest["captures"].append({
            "capture_id": capture_id, "folder": folder.name,
            "floor_id": video["floor_id"], "source_files": sources,
            "video_segments": len(video["segments"]),
            "video_frames": sum(item["frame_count"] for item in video["segments"]),
            "recording_status": video["status"],
            "native_room_counts": {key: sum(len(room.get(key, [])) for room in rooms)
                                   for key in ROOM_FIELDS},
            "compact_source": str(output.relative_to(args.output)),
            "compact_source_sha256": digest(output),
        })
    write(args.output / "source-manifest.json", manifest)
    print(json.dumps({"captures": len(manifest["captures"]),
                      "video_segments": sum(item["video_segments"] for item in manifest["captures"]),
                      "video_frames": sum(item["video_frames"] for item in manifest["captures"]),
                      "output": str(args.output)}, indent=2))


if __name__ == "__main__":
    main()

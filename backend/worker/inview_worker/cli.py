"""inview-worker: process scans from the InView backend with OpenCV.

    inview-worker process <scan-id> [--out analysis.json] [--no-publish]
    inview-worker process --all [--force]
    inview-worker watch [--interval 15]

Configuration: INVIEW_BACKEND_URL (default http://127.0.0.1:3000) and INVIEW_API_TOKEN, or the
token file at backend/.secrets/api-token. The token is never printed.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

from .client import Backend, BackendError
from .pipeline import process

DEFAULT_TOKEN_FILE = Path(__file__).resolve().parents[2] / ".secrets" / "api-token"


def backend_from(args) -> Backend:
    token = os.environ.get("INVIEW_API_TOKEN")
    token_file = Path(args.token_file)
    if not token and token_file.is_file():
        token = token_file.read_text().strip()
    return Backend(args.url, token or None)


def summarize(result: dict) -> str:
    s = result["summary"]
    return (f"{result['scan_id']}: walkable {s['walkable_area_m2']} m², {s['narrow_passages']} narrow passages, "
            f"{s['doors_checked']} doors ({s['doors_below_min_width']} below minimum), "
            f"{s['sign_candidates']} sign + {s['text_regions']} text candidates from {s['keyframes_examined']} keyframes")


def pending(backend: Backend, force: bool) -> list[str]:
    ids = [scan["id"] for scan in backend.get_json("/scans")]
    return ids if force else [i for i in ids if backend.optional_json(f"/scans/{Backend.segment(i)}/analysis") is None]


def run_one(backend: Backend, scan_id: str, publish: bool = True, out: str | None = None) -> bool:
    try:
        result = process(backend, scan_id, publish=publish)
    except (BackendError, ValueError, KeyError) as error:
        print(f"{scan_id}: failed: {error}", file=sys.stderr)
        return False
    if out:
        Path(out).write_text(json.dumps(result, indent=2))
    print(summarize(result) + ("" if publish else " (not published)"))
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="inview-worker", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default=os.environ.get("INVIEW_BACKEND_URL", "http://127.0.0.1:3000"))
    parser.add_argument("--token-file", default=str(DEFAULT_TOKEN_FILE))
    commands = parser.add_subparsers(dest="command", required=True)
    one = commands.add_parser("process", help="analyse one scan, or every scan with --all")
    one.add_argument("scan_id", nargs="?")
    one.add_argument("--all", action="store_true")
    one.add_argument("--force", action="store_true", help="re-run scans that already have an analysis")
    one.add_argument("--no-publish", action="store_true", help="do not upload the result to the backend")
    one.add_argument("--out", help="also write the analysis JSON to this file")
    watch = commands.add_parser("watch", help="poll for new scans and analyse them")
    watch.add_argument("--interval", type=float, default=15)
    args = parser.parse_args(argv)
    backend = backend_from(args)

    if args.command == "process":
        if args.all == bool(args.scan_id):
            parser.error("give a scan id or --all")
        if args.scan_id:
            return 0 if run_one(backend, args.scan_id, not args.no_publish, args.out) else 1
        results = [run_one(backend, i, not args.no_publish) for i in pending(backend, args.force)]
        print(f"processed {sum(results)}/{len(results)} scans")
        return 0 if all(results) else 1

    failed: dict[str, float] = {}
    print(f"watching {backend.base_url} every {args.interval:g}s (Ctrl-C to stop)")
    while True:
        try:
            for scan_id in pending(backend, False):
                if time.time() - failed.get(scan_id, 0) < 300:
                    continue  # Back off five minutes after a failure.
                if not run_one(backend, scan_id):
                    failed[scan_id] = time.time()
        except (BackendError, OSError) as error:
            print(f"backend unavailable: {error}", file=sys.stderr)
        except KeyboardInterrupt:
            return 0
        try:
            time.sleep(args.interval)
        except KeyboardInterrupt:
            return 0


if __name__ == "__main__":
    raise SystemExit(main())

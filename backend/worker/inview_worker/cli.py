"""inview-worker: process scans from the InView backend with OpenCV.

    inview-worker process <scan-id> [--out analysis.json] [--no-publish]
    inview-worker process --all [--force]
    inview-worker watch [--interval 15]
    inview-worker report analysis.json [...]
    inview-worker evaluate [--seed N] [--scenarios K] [--out report.json] [--keep DIR]

Configuration: INVIEW_BACKEND_URL (default http://127.0.0.1:3000) and INVIEW_API_TOKEN, or the
token file at backend/.secrets/api-token. The token is never printed.
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
from pathlib import Path

from .client import Backend, BackendError
from .contracts import RESERVED_KEYS
from .pipeline import process

DEFAULT_TOKEN_FILE = Path(__file__).resolve().parents[2] / ".secrets" / "api-token"


def backend_from(args) -> Backend:
    token = os.environ.get("INVIEW_API_TOKEN")
    token_file = Path(args.token_file)
    if not token and token_file.is_file():
        token = token_file.read_text().strip()
    return Backend(args.url, token or None)


def summarize(result: dict) -> str:
    stages = result.get("stages", {})
    states = {state: sum(s["status"] == state for s in stages.values()) for state in ("ok", "skipped", "failed")}
    products = [key for key in result if key not in RESERVED_KEYS]
    return (f"{result['scan_id']}: {states['ok']} stages ok, {states['skipped']} skipped, {states['failed']} failed; "
            f"products: {', '.join(sorted(products)) or 'none'}")


def report(paths: list[str]) -> int:
    """Human-readable stage/product table for saved analysis files."""
    for path in paths:
        result = json.loads(Path(path).read_text())
        print(f"== {result['scan_id']} ({path})")
        for name, stage in sorted(result.get("stages", {}).items()):
            detail = stage.get("error") or ", ".join(stage.get("missing", []) or stage.get("provided", []))
            print(f"  {stage['status']:<8} {name:<16} {stage.get('seconds', '')!s:<7} {detail}")
        for key in sorted(k for k in result if k not in RESERVED_KEYS):
            value = result[key]
            size = len(value) if isinstance(value, (list, dict)) else 1
            print(f"  product  {key:<16} {type(value).__name__}[{size}]")
        for notice in result.get("notices", [])[1:]:
            print(f"  notice   {notice}")
    return 0


def evaluate(args) -> int:
    """Score every stage offline against synthetic buildings with ground truth (no backend)."""
    from . import evaluate as harness  # deferred: generating buildings is only needed here

    result = harness.run(args.seed, args.scenarios, args.max_observations, args.keep)
    if args.out:
        Path(args.out).write_text(json.dumps(result, indent=2))
    print(harness.table(result))
    return 0


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
    show = commands.add_parser("report", help="print stage/product tables for saved analysis JSON files")
    show.add_argument("paths", nargs="+")
    score = commands.add_parser("evaluate", help="run every stage on synthetic buildings and score it against ground truth")
    score.add_argument("--seed", type=int, default=0, help="first building seed (scenario i uses seed + i)")
    score.add_argument("--scenarios", type=int, default=3)
    score.add_argument("--max-observations", type=int, default=32, help="depth/RGB observations per building")
    score.add_argument("--out", help="write the full JSON report to this file")
    score.add_argument("--keep", help="also save each package, ground truth and analysis in this directory")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.WARNING, format="%(levelname)s %(name)s: %(message)s")
    if args.command == "report":
        return report(args.paths)
    if args.command == "evaluate":
        if args.scenarios < 1:
            parser.error("--scenarios must be at least 1")
        return evaluate(args)
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

#!/usr/bin/env bash
# End-to-end check: build the Rust backend, run it on loopback with a throwaway scan directory
# (no token), upload the demo RoomPlan scan and the synthetic iPhone package, run every pipeline
# stage through the real API, then print the stage/product report.
#
#   scripts/e2e.sh <port> [output-dir]
#
# Never point this at the live server or the user's scan directory.
set -euo pipefail
port="${1:?usage: scripts/e2e.sh <port> [output-dir]}"
worker="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backend="$(cd "$worker/.." && pwd)"
out="${2:-$(mktemp -d /tmp/inview-e2e.XXXXXX)}"
url="http://127.0.0.1:$port"
python="$worker/.venv/bin/python"
mkdir -p "$out/scans"
# The repository path contains ':', which breaks in-repo Cargo target directories.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/inview-e2e-target}"

[[ -x "$python" ]] || { echo "Run 'uv sync --python 3.12' in $worker first." >&2; exit 1; }
if curl -s -o /dev/null "$url/health"; then echo "Port $port is already in use." >&2; exit 1; fi

cargo build --quiet --manifest-path "$backend/Cargo.toml"
INVIEW_BIND="127.0.0.1:$port" INVIEW_SCAN_DIR="$out/scans" \
  "$CARGO_TARGET_DIR/debug/inview-backend" > "$out/server.log" 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT
for _ in $(seq 1 100); do curl -sf -o /dev/null "$url/health" && break; sleep 0.2; done
curl -sf -o /dev/null "$url/health" || { cat "$out/server.log" >&2; exit 1; }

curl -sf -o /dev/null -X POST -H 'content-type: application/json' \
  --data-binary @"$backend/examples/demo-living-room.json" "$url/scans"
"$python" -m inview_worker.synthetic.package "$out/synthetic.inviewscan.tar"
curl -sf -o /dev/null -X POST -H 'content-type: application/x-tar' \
  --data-binary @"$out/synthetic.inviewscan.tar" "$url/scan-packages"

INVIEW_API_TOKEN= "$python" -m inview_worker --url "$url" --token-file /dev/null process --all --force
for id in demo-room synthetic-walk; do
  curl -sf "$url/scans/$id/analysis" > "$out/$id.analysis.json"
done
"$python" -m inview_worker report "$out"/*.analysis.json
echo "E2E_OUT=$out"

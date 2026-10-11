#!/usr/bin/env bash
# Run the backend on this Mac for the phone on the same Wi-Fi.
#
# Binds every interface with the same bearer token the app was built with
# (INVIEW_BACKEND_TOKEN in Config/Secrets.xcconfig, or backend/.secrets/api-token), and prints
# the address to put in INVIEW_LOCAL_BACKEND_URL. The app sends its token over plain HTTP only to
# private-network addresses like this one. Maps/buildings endpoints stay off without PostgreSQL.
set -euo pipefail
backend_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(dirname "$backend_dir")"
secrets="$repo_dir/Config/Secrets.xcconfig"

token="${INVIEW_API_TOKEN:-}"
if [[ -z "$token" && -f "$secrets" ]]; then
  token="$(sed -nE 's/^[[:space:]]*INVIEW_BACKEND_TOKEN[[:space:]]*=[[:space:]]*([^[:space:]]+).*$/\1/p' "$secrets" | head -1)"
fi
if [[ -z "$token" && -s "$backend_dir/.secrets/api-token" ]]; then
  token="$(< "$backend_dir/.secrets/api-token")"
fi
if [[ ${#token} -lt 32 ]]; then
  echo "No backend token. Set INVIEW_BACKEND_TOKEN in Config/Secrets.xcconfig (openssl rand -hex 32)." >&2
  exit 1
fi
export INVIEW_API_TOKEN="$token"

port="${INVIEW_PORT:-3000}"
export INVIEW_BIND="0.0.0.0:$port"
data_dir="${INVIEW_DATA_DIR:-$HOME/Library/Application Support/InView}"
export INVIEW_SCAN_DIR="${INVIEW_SCAN_DIR:-$data_dir/scans}"
export INVIEW_STREAM_DIR="${INVIEW_STREAM_DIR:-$data_dir/streams}"
export INVIEW_PRODUCT_DIR="${INVIEW_PRODUCT_DIR:-$data_dir/product}"
mkdir -p "$INVIEW_SCAN_DIR" "$INVIEW_STREAM_DIR" "$INVIEW_PRODUCT_DIR"
export RUST_LOG="${RUST_LOG:-inview_backend=info,tower_http=info}"

echo "Phone-reachable addresses on this Mac (put one in Config/Secrets.xcconfig as INVIEW_LOCAL_BACKEND_URL):"
for ip in $(ipconfig getiflist 2>/dev/null | xargs -n1 ipconfig getifaddr 2>/dev/null); do
  echo "  INVIEW_LOCAL_BACKEND_URL = http:/\$()/$ip:$port"
done
echo "Data: $data_dir"
echo "Check from the phone's network: curl -H 'Authorization: Bearer <token>' http://<ip>:$port/health"
echo

exec cargo run --release --locked --manifest-path "$backend_dir/Cargo.toml"

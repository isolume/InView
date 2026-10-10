#!/usr/bin/env bash
# Start the authenticated Rust backend on loopback. Put an HTTPS reverse proxy/tunnel in front.
set -euo pipefail
backend_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
secrets_dir="$backend_dir/.secrets"
if [[ ! -s "$secrets_dir/api-token" ]]; then
  echo "Missing $secrets_dir/api-token (generate with: openssl rand -hex 32 > '$secrets_dir/api-token')" >&2
  exit 1
fi
export INVIEW_API_TOKEN="$(< "$secrets_dir/api-token")"
if [[ -z "${INVIEW_DATABASE_URL:-}" ]]; then
  if [[ -s "$secrets_dir/tigerdata-url" ]]; then
    export INVIEW_DATABASE_URL="$(< "$secrets_dir/tigerdata-url")"
    export INVIEW_REQUIRE_TIMESCALE=1
    echo "Starting against TigerData (TimescaleDB required)."
  elif [[ "${INVIEW_ALLOW_LOCAL_POSTGRES:-}" == "1" ]]; then
    export INVIEW_DATABASE_URL='postgresql://localhost/inview_dev'
    echo "Starting against local PostgreSQL; NOT TigerData."
  else
    echo "Missing TigerData URL. Set INVIEW_ALLOW_LOCAL_POSTGRES=1 for explicitly local development." >&2
    exit 1
  fi
fi
export INVIEW_SCAN_DIR="${INVIEW_SCAN_DIR:-$HOME/Library/Application Support/InView/scans}"
export INVIEW_BIND="${INVIEW_BIND:-127.0.0.1:3000}"
mkdir -p "$INVIEW_SCAN_DIR"
chmod 700 "$INVIEW_SCAN_DIR"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/inview-actual-rust-build}"
cargo build --locked --quiet --manifest-path "$backend_dir/Cargo.toml"
exec "$CARGO_TARGET_DIR/debug/inview-backend"

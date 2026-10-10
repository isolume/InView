#!/usr/bin/env bash
set -euo pipefail
recognition_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
recognition_python="${INVIEW_RECOGNITION_SETUP_PYTHON:-}"
if [[ -z "$recognition_python" ]]; then
    for candidate in python3.12 python3.13 python3.14 python3; do
        if command -v "$candidate" >/dev/null 2>&1; then
            recognition_python="$(command -v "$candidate")"
            break
        fi
    done
fi
if [[ -z "$recognition_python" ]]; then
    echo "Install Python 3.12+ or set INVIEW_RECOGNITION_SETUP_PYTHON." >&2
    exit 1
fi
export INVIEW_RECOGNITION_CACHE="${INVIEW_RECOGNITION_CACHE:-$recognition_dir/cache}"
export PIP_CACHE_DIR="$INVIEW_RECOGNITION_CACHE/pip"
export UV_CACHE_DIR="$INVIEW_RECOGNITION_CACHE/uv"
mkdir -p "$INVIEW_RECOGNITION_CACHE"
"$recognition_python" -m venv "$recognition_dir/.venv"
if command -v uv >/dev/null 2>&1; then
    uv pip install --python "$recognition_dir/.venv/bin/python" -r "$recognition_dir/requirements.txt"
else
    "$recognition_dir/.venv/bin/python" -m pip install -r "$recognition_dir/requirements.txt"
fi
"$recognition_dir/.venv/bin/python" -u "$recognition_dir/worker.py" --setup

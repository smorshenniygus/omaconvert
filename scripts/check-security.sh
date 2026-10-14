#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONDONTWRITEBYTECODE=1
python3 -m unittest tests.security.test_cgroup -v
python3 -m unittest tests.test_worker_lifecycle -v
python3 -m unittest tests.security.test_png_bomb -v

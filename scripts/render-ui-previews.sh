#!/bin/bash
# Local WindowServer required. Synthetic data only; release builds ignore preview flags.
set -euo pipefail
RILL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RILL_ROOT"
RILL_MODE="${1:-}"
if [[ "$RILL_MODE" != "" && "$RILL_MODE" != "--screenshots" ]]; then
  echo 'Usage: bash scripts/render-ui-previews.sh [--screenshots]' >&2
  exit 2
fi
swift build --product Rill
RILL_BIN="$(swift build --show-bin-path)/Rill"
python3 - "$RILL_BIN" "$RILL_ROOT" "$RILL_MODE" <<'PY'
import subprocess
import sys
from pathlib import Path

executable, root, mode = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
destination = root / ("docs/images" if mode == "--screenshots" else "dist/ui-review")
destination.mkdir(parents=True, exist_ok=True)
states = [
    ("environment-empty", "dark", 1440),
    ("environment-editor", "light", 1440),
    ("copy-request", "dark", 1440),
    ("collection-transfer", "dark", 1440),
    ("move-request", "light", 1440),
    ("empty", "dark", 1440),
    ("empty", "light", 1050),
    ("blank", "light", 1050),
    ("body", "dark", 1440),
    ("auth", "dark", 1440),
    ("workflow", "light", 1050),
    ("loading", "dark", 1440),
    ("intro", "light", 1050),
    ("response-failed", "dark", 1440),
    ("response-passed", "light", 1050),
    ("response-unchecked", "dark", 1050),
    ("tabs-close", "dark", 1440),
    ("tabs-menu-close", "dark", 1440),
]
if mode == "--screenshots":
    states = [("response-passed", "dark", 1440), ("empty", "light", 1050)]
for state, theme, width in states:
    name = (
        {"response-passed": "workbench-dark", "empty": "welcome-light"}[state]
        if mode == "--screenshots"
        else f"{state}-{theme}"
    )
    target = destination / (name + ".png")
    subprocess.run(
        [
            executable,
            "--ui-state",
            state,
            "--ui-appearance",
            theme,
            "--ui-width",
            str(width),
            "--ui-snapshot",
            str(target),
        ],
        check=True,
        timeout=20,
    )
    assert target.stat().st_size > 1000
    print(target)
PY

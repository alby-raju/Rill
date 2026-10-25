#!/bin/bash
# Local WindowServer required. Synthetic data only; release builds ignore preview flags.
set -euo pipefail
RILL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RILL_ROOT"
swift build --product Rill
RILL_BIN="$(swift build --show-bin-path)/Rill"
mkdir -p dist/ui-review
python3 - "$RILL_BIN" "$RILL_ROOT/dist/ui-review" <<'PY'
import subprocess,sys
from pathlib import Path
executable,root=sys.argv[1],Path(sys.argv[2])
for state,theme,width in [('empty','dark',1440),('empty','light',1050),('blank','light',1050),('body','dark',1440),('auth','dark',1440),('workflow','light',1050),('loading','dark',1440),('intro','light',1050),('response-failed','dark',1440),('response-passed','light',1050),('response-unchecked','dark',1050)]:
    target=root/f'{state}-{theme}.png'
    subprocess.run([executable,'--ui-state',state,'--ui-appearance',theme,'--ui-width',str(width),'--ui-snapshot',str(target)],check=True,timeout=20)
    assert target.stat().st_size>1000
    print(target)
PY

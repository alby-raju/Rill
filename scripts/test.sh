#!/bin/bash
# Run the full test suite with a loopback fixture, including transport tests.
set -euo pipefail
RILL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RILL_ROOT"
RILL_FIXTURE_LOG="$(mktemp -t rill-fixture)"
python3 scripts/http-fixture.py > "$RILL_FIXTURE_LOG" 2>&1 &
RILL_FIXTURE_PID=$!
trap 'kill "$RILL_FIXTURE_PID" 2>/dev/null || true' EXIT
export RILL_TEST_BASE_URL=http://127.0.0.1:18749
# Wait for readiness and check ownership so an occupied port cannot hide a
# failed fixture startup.
if ! python3 - "$RILL_FIXTURE_PID" <<'PY'
import os
import sys
import time
import urllib.request

pid = int(sys.argv[1])
for attempt in range(50):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        sys.exit('The HTTP fixture exited before becoming ready.')
    try:
        with urllib.request.urlopen('http://127.0.0.1:18749/json', timeout=0.2) as response:
            if response.headers.get('X-Fixture') == 'Rill':
                time.sleep(0.1)
                os.kill(pid, 0)
                break
    except (OSError, ValueError):
        pass
    time.sleep(0.1)
else:
    sys.exit('The HTTP fixture did not become ready within five seconds.')
PY
then
  cat "$RILL_FIXTURE_LOG"
  exit 1
fi
swift test "$@"

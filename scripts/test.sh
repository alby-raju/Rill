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
import http.client

pid = int(sys.argv[1])
deadline = time.monotonic() + 30
last_error = "No response yet"
while time.monotonic() < deadline:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        sys.exit('The HTTP fixture exited before becoming ready.')
    try:
        connection = http.client.HTTPConnection('127.0.0.1', 18749, timeout=0.5)
        try:
            connection.request('GET', '/json')
            response = connection.getresponse()
            if response.status == 200 and response.getheader('X-Fixture') == 'Rill':
                time.sleep(0.1)
                os.kill(pid, 0)
                break
        finally:
            connection.close()
    except (OSError, ValueError, http.client.HTTPException) as error:
        last_error = str(error)
    time.sleep(0.1)
else:
    sys.exit(f'The HTTP fixture did not become ready within 30 seconds: {last_error}')
PY
then
  cat "$RILL_FIXTURE_LOG"
  exit 1
fi
swift test "$@"

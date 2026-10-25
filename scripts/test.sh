#!/bin/bash
# Run the full test suite with a loopback fixture, including transport tests.
set -euo pipefail
RILL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RILL_ROOT"
# Build the selected official compiler for source-loading tests; no host protoc lookup.
swift build --product protoc
export RILL_TEST_PROTOC_PATH="$(swift build --show-bin-path)/protoc"
export RILL_TEST_PROTO_INCLUDE="$RILL_ROOT/.build/checkouts/swift-protobuf/Sources/protobuf/protobuf/src"
RILL_FIXTURE_LOG="$(mktemp -t rill-fixture)"
python3 scripts/http-fixture.py > "$RILL_FIXTURE_LOG" 2>&1 &
RILL_FIXTURE_PID=$!
RILL_TLS_DIRECTORY="$(mktemp -d -t rill-tls)"
RILL_TLS_LOG="$(mktemp -t rill-tls-log)"
python3 scripts/tls-fixture.py "$RILL_TLS_DIRECTORY" > "$RILL_TLS_LOG" 2>&1 &
RILL_TLS_PID=$!
RILL_LIVE_LOG="$(mktemp -t rill-live-log)"
python3 scripts/live-fixture.py > "$RILL_LIVE_LOG" 2>&1 &
RILL_LIVE_PID=$!
RILL_MQTT_LOG="$(mktemp -t rill-mqtt-log)"
python3 scripts/mqtt_fixture.py > "$RILL_MQTT_LOG" 2>&1 &
RILL_MQTT_PID=$!
RILL_AMQP_LOG="$(mktemp -t rill-amqp-log)"
python3 scripts/amqp_fixture.py > "$RILL_AMQP_LOG" 2>&1 &
RILL_AMQP_PID=$!
cleanup() {
  RILL_EXIT_STATUS=$?
  trap - EXIT
  kill "$RILL_FIXTURE_PID" 2>/dev/null || true
  kill "$RILL_TLS_PID" 2>/dev/null || true
  kill "$RILL_LIVE_PID" 2>/dev/null || true
  kill "$RILL_MQTT_PID" 2>/dev/null || true
  kill "$RILL_AMQP_PID" 2>/dev/null || true
  python3 - "$RILL_TLS_DIRECTORY" <<'PY_CLEANUP'
import shutil
import sys
shutil.rmtree(sys.argv[1], ignore_errors=True)
PY_CLEANUP
  if [ "$RILL_EXIT_STATUS" -ne 0 ]; then
    cat "$RILL_FIXTURE_LOG"
    cat "$RILL_TLS_LOG"
    cat "$RILL_LIVE_LOG"
    cat "$RILL_MQTT_LOG"
    cat "$RILL_AMQP_LOG"
  fi
  exit "$RILL_EXIT_STATUS"
}
trap cleanup EXIT
export RILL_TEST_AMQP_URL=amqp://127.0.0.1:18757
export RILL_TEST_MQTT_URL=mqtt://127.0.0.1:18756
export RILL_TEST_LIVE_URL=http://127.0.0.1:18755
export RILL_TEST_BASE_URL=http://127.0.0.1:18749
python3 - "$RILL_AMQP_PID" <<'PY_AMQP'
import os, socket, sys, time
pid = int(sys.argv[1])
for attempt in range(100):
    os.kill(pid, 0)
    try:
        with socket.create_connection(('127.0.0.1', 18757), timeout=0.5) as connection:
            connection.sendall(b'AMQP\0\0\x09\x01')
            if connection.recv(1) == b'\x01':
                time.sleep(0.1); os.kill(pid, 0); break
    except OSError: pass
    time.sleep(0.1)
else: raise SystemExit('AMQP fixture failed to start.')
PY_AMQP
python3 - "$RILL_MQTT_PID" <<'PY_MQTT'
import os, socket, sys, time
pid = int(sys.argv[1])
for attempt in range(100):
    os.kill(pid, 0)
    try:
        with socket.create_connection(('127.0.0.1', 18756), timeout=0.5) as connection:
            connection.sendall(bytes.fromhex('100e00044d5154540402001e00027264'))
            if connection.recv(4) == bytes.fromhex('20020000'):
                time.sleep(0.1); os.kill(pid, 0); break
    except OSError: pass
    time.sleep(0.1)
else: raise SystemExit('MQTT fixture failed to start.')
PY_MQTT
# Verify the live fixture owns its endpoint before tests can use it.
python3 - "$RILL_LIVE_PID" <<'PY_LIVE'
import http.client, os, sys, time
pid = int(sys.argv[1])
for attempt in range(100):
    os.kill(pid, 0)
    try:
        connection = http.client.HTTPConnection('127.0.0.1', 18755, timeout=0.5)
        connection.request('GET', '/health')
        response = connection.getresponse()
        body = response.read(); connection.close()
        if response.status == 200 and b'RillLive' in body:
            time.sleep(0.1); os.kill(pid, 0); break
    except (OSError, http.client.HTTPException): pass
    time.sleep(0.1)
else: raise SystemExit('Live fixture failed to start.')
PY_LIVE
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
export RILL_TEST_TLS_DIR="$RILL_TLS_DIRECTORY"
export RILL_TEST_TLS_URL=https://localhost:18750
export RILL_TEST_MTLS_URL=https://localhost:18751
python3 - "$RILL_TLS_PID" <<'PY_TLS_READY'
import http.client
import os
import ssl
import sys
import time
pid = int(sys.argv[1])
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    os.kill(pid, 0)
    try:
        # This readiness probe connects only to our disposable loopback fixture.
        connection = http.client.HTTPSConnection('127.0.0.1', 18750, timeout=0.5, context=ssl._create_unverified_context())
        try:
            connection.request('GET', '/json')
            response = connection.getresponse()
            if response.getheader('X-Fixture') == 'RillTLS':
                time.sleep(0.1)
                os.kill(pid, 0)
                break
        finally:
            connection.close()
    except OSError:
        pass
    time.sleep(0.1)
else:
    sys.exit('The TLS fixture did not become ready within 30 seconds.')
PY_TLS_READY
swift test "$@"

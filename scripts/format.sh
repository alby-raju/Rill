#!/bin/bash
# Format only first-party source. Tool setup is documented in CONTRIBUTING.md.
set -euo pipefail
RILL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RILL_ROOT"
RILL_MODE="${1:-}"
if [[ "$RILL_MODE" != "" && "$RILL_MODE" != "--check" ]]; then
  echo 'Usage: bash scripts/format.sh [--check]' >&2
  exit 2
fi
RILL_RUFF="${RILL_RUFF:-ruff}"
RILL_SHFMT="${RILL_SHFMT:-shfmt}"
command -v "$RILL_RUFF" >/dev/null || {
  echo 'Install requirements-dev.txt and activate .venv first.' >&2
  exit 2
}
command -v "$RILL_SHFMT" >/dev/null || {
  echo 'Install shfmt 3.14.1 or set RILL_SHFMT to its executable.' >&2
  exit 2
}
[[ "$("$RILL_RUFF" --version)" == 'ruff 0.17.2' ]] || {
  echo 'Expected Ruff 0.17.2.' >&2
  exit 2
}
[[ "$("$RILL_SHFMT" --version)" == 'v3.14.1' ]] || {
  echo 'Expected shfmt v3.14.1.' >&2
  exit 2
}
if [[ "$RILL_MODE" == '--check' ]]; then
  swift format lint --strict --recursive --configuration .swift-format Sources Tests Package.swift scripts/make-icon.swift
  "$RILL_RUFF" format --check scripts verification
  "$RILL_RUFF" check scripts verification
  xcrun clang-format --dry-run --Werror Tests/BrokerSupport/KafkaFixture.c Tests/BrokerSupport/include/RillBrokerTestSupport.h verification/materials/echo.proto
else
  swift format format --in-place --recursive --configuration .swift-format Sources Tests Package.swift scripts/make-icon.swift
  "$RILL_RUFF" format scripts verification
  "$RILL_RUFF" check --fix scripts verification
  xcrun clang-format -i Tests/BrokerSupport/KafkaFixture.c Tests/BrokerSupport/include/RillBrokerTestSupport.h verification/materials/echo.proto
fi
for RILL_SCRIPT in scripts/*.sh; do
  if [[ "$(head -1 "$RILL_SCRIPT")" == '#!/bin/zsh' ]]; then
    zsh -n "$RILL_SCRIPT"
  elif [[ "$RILL_MODE" == '--check' ]]; then
    "$RILL_SHFMT" -d -i 2 -ci "$RILL_SCRIPT"
    bash -n "$RILL_SCRIPT"
  else
    "$RILL_SHFMT" -w -i 2 -ci "$RILL_SCRIPT"
    bash -n "$RILL_SCRIPT"
  fi
done

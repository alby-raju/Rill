#!/bin/bash
# Build only upstream targets before CodeQL init. Never build/cache first-party
# targets here: the subsequent traced build must compile all Rill Swift source.
set -euo pipefail
# CodeQL tracing runs through Rosetta. Match its host and pin the target so
# SwiftPM does not discard this preparation for a different architecture.
RILL_SWIFT=(/usr/bin/arch -x86_64 /usr/bin/swift)
"${RILL_SWIFT[@]}" package resolve
for RILL_UPSTREAM_TARGET in Yams ZIPFoundation GRPCNIOTransportHTTP2TransportServices SwiftProtobuf Kafka Logging; do
  "${RILL_SWIFT[@]}" build --configuration debug --arch arm64 --target "$RILL_UPSTREAM_TARGET"
done
# Fail rather than silently analyzing a reused first-party module if this script
# is accidentally changed to build the root products in future.
if find .build -type f \( -name Rill.swiftmodule -o -name RillCore.swiftmodule -o -name RillCLI.swiftmodule \) -print -quit | grep -q .; then
  echo 'First-party build output exists before CodeQL extraction.' >&2
  exit 1
fi

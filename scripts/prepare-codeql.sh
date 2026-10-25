#!/bin/bash
# Build only upstream targets before CodeQL init. Never build/cache first-party
# targets here: the subsequent traced build must compile all Rill Swift source.
set -euo pipefail
swift package resolve
for RILL_UPSTREAM_TARGET in Yams ZIPFoundation GRPCNIOTransportHTTP2TransportServices SwiftProtobuf Kafka Logging; do
  swift build --configuration debug --target "$RILL_UPSTREAM_TARGET"
done
# Fail rather than silently analyzing a reused first-party module if this script
# is accidentally changed to build the root products in future.
if find .build -type d \( -name Rill.build -o -name RillCore.build -o -name RillCLI.build \) -print -quit | grep -q .; then
  echo 'First-party build output exists before CodeQL extraction.' >&2
  exit 1
fi

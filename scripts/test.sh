#!/bin/bash
# Canonical test runner for pastaperfection (oracle.md baseline gate).
# CLT-only machines lack XCTest and don't auto-wire Swift Testing's framework,
# macro plugin, or runtime dylib paths — these flags supply them (ledger 0005).
set -euo pipefail
cd "$(dirname "$0")/.."
CLT="$(xcode-select -p)"
exec swift test --disable-xctest \
  -Xswiftc -F -Xswiftc "$CLT/Library/Developer/Frameworks" \
  -Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib" \
  "$@"

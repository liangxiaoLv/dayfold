#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
toolchain="$(dirname "$(xcrun --find swiftc)")/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
options=()
if [[ -f "$toolchain" ]]; then
    options=(-Xswiftc -load-plugin-library -Xswiftc "$toolchain")
fi
swift test --disable-xctest "${options[@]}"

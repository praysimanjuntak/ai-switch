#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
cd "$PROJECT_DIR"

# The Command Line Tools keep Testing.framework outside the SDK. SwiftPM's
# generated runner also needs this search path or canImport(Testing) is false
# and `swift test` can finish successfully without executing any tests.
TESTING_FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
swift test --enable-swift-testing \
    -Xswiftc -F -Xswiftc "$TESTING_FRAMEWORKS" "$@"

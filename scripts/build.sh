#!/bin/bash
# Genera el proyecto con XcodeGen y compila VMBox (Debug) en ./build.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-guest-agent.sh
xcodegen generate --quiet
xcodebuild -project VMBox.xcodeproj -scheme VMBox -configuration Debug \
  -derivedDataPath build -skipMacroValidation -skipPackagePluginValidation build \
  | grep -E "error:|warning: .*VMBox|BUILD (SUCCEEDED|FAILED)" || true
test -d build/Build/Products/Debug/VMBox.app
echo "OK: build/Build/Products/Debug/VMBox.app"

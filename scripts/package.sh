#!/bin/bash
# Compila VMBox en Release (firma ad hoc) y lo empaqueta en dist/VMBox.zip.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-guest-agent.sh
xcodegen generate --quiet
xcodebuild -project VMBox.xcodeproj -scheme VMBox -configuration Release ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  -derivedDataPath build -skipMacroValidation -skipPackagePluginValidation build \
  | grep -E "error:|warning: .*VMBox|BUILD (SUCCEEDED|FAILED)" || true
APP=build/Build/Products/Release/VMBox.app
test -d "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p dist
rm -f dist/VMBox.zip
ditto -c -k --keepParent "$APP" dist/VMBox.zip
echo "OK: dist/VMBox.zip"

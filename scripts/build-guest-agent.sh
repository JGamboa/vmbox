#!/bin/bash
# Compila vmbox-guest-agent para Ubuntu (linux/arm64) y macOS (darwin/arm64) y arma GuestTools/.
set -euo pipefail
cd "$(dirname "$0")/../guest-agent"
export PATH="/opt/homebrew/bin:$PATH"
OUT=dist/GuestTools
rm -rf dist
mkdir -p "$OUT/linux-arm64" "$OUT/darwin-arm64"
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o "$OUT/linux-arm64/vmbox-guest-agent" .
# El linker de Go firma ad hoc los binarios darwin/arm64 (obligatorio en Apple silicon).
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o "$OUT/darwin-arm64/vmbox-guest-agent" .
cp install/* "$OUT/"
chmod +x "$OUT"/*.sh
echo "OK: guest-agent/$OUT"

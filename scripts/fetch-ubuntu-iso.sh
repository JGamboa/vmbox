#!/bin/bash
# Descarga (reanudable) el ISO de escritorio arm64 de la última LTS y verifica su SHA256.
set -euo pipefail
VER=26.04.1
BASE=https://cdimage.ubuntu.com/releases/26.04/release
FILE="ubuntu-$VER-desktop-arm64.iso"
DEST_DIR="$HOME/Library/Application Support/VMBox/Cache"
mkdir -p "$DEST_DIR"
cd "$DEST_DIR"
EXPECTED=$(curl -fsSL "$BASE/SHA256SUMS" | grep " \*$FILE\$" | cut -d' ' -f1)
if [ -f "$FILE" ] && [ "$(shasum -a 256 "$FILE" | cut -d' ' -f1)" = "$EXPECTED" ]; then
  echo "$DEST_DIR/$FILE"; exit 0
fi
curl -fL -C - -o "$FILE.part" "$BASE/$FILE"
ACTUAL=$(shasum -a 256 "$FILE.part" | cut -d' ' -f1)
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "SHA256 no coincide (esperado $EXPECTED, obtenido $ACTUAL)" >&2
  rm -f "$FILE.part"; exit 1
fi
mv "$FILE.part" "$FILE"
echo "$DEST_DIR/$FILE"

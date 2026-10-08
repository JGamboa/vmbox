#!/bin/bash
# Uso: spike/run.sh "/ruta/al/ubuntu-26.04.1-desktop-arm64.iso"
set -euo pipefail
cd "$(dirname "$0")"
ISO="${1:?uso: spike/run.sh /ruta/al/ubuntu.iso}"
swift build -c debug
codesign --force --sign - --entitlements Spike.entitlements .build/debug/Spike
mkdir -p /tmp/vmbox-spike
exec .build/debug/Spike "$ISO"

#!/bin/bash
# Instala vmbox-guest-agent en macOS como LaunchAgent (sesión del usuario, para el portapapeles).
# Uso: sudo "/Volumes/My Shared Files/GuestTools/install-macos.sh"
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Ejecuta con sudo"; exit 1; }
USER_NAME="${SUDO_USER:?Ejecuta con sudo desde tu usuario}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PLIST=/Library/LaunchAgents/cl.multiapi.vmbox.guest-agent.plist

mkdir -p /usr/local/bin
install -m 0755 "$HERE/darwin-arm64/vmbox-guest-agent" /usr/local/bin/vmbox-guest-agent
install -m 0644 "$HERE/cl.multiapi.vmbox.guest-agent.plist" "$PLIST"

# run_command con as_root usa «sudo -n»: sudo sin contraseña para este usuario (VM desechable).
SUDOERS_TMP=$(mktemp)
trap 'rm -f "$SUDOERS_TMP"' EXIT
echo "$USER_NAME ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_TMP"
visudo -cf "$SUDOERS_TMP"
install -m 0440 -o root -g wheel "$SUDOERS_TMP" /etc/sudoers.d/vmbox-guest-agent

USER_ID=$(id -u "$USER_NAME")
launchctl bootout "gui/$USER_ID" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$USER_ID" "$PLIST"
echo "vmbox-guest-agent instalado y en marcha (vsock:7000)."

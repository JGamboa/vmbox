#!/bin/bash
# Instala vmbox-guest-agent en Ubuntu arm64 como servicio de usuario (necesita la sesión gráfica para el portapapeles).
# Uso, desde la cuenta del usuario de escritorio: sudo /mnt/vmbox/GuestTools/install-linux.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Ejecuta con sudo"; exit 1; }
USER_NAME="${SUDO_USER:?Ejecuta con sudo desde tu usuario de escritorio}"
HERE="$(cd "$(dirname "$0")" && pwd)"

install -m 0755 "$HERE/linux-arm64/vmbox-guest-agent" /usr/local/bin/vmbox-guest-agent
apt-get install -y wl-clipboard xclip >/dev/null 2>&1 || echo "Aviso: no se pudo instalar wl-clipboard/xclip; el portapapeles no funcionará."
install -m 0644 "$HERE/vmbox-guest-agent.service" /etc/systemd/user/vmbox-guest-agent.service
systemctl --global enable vmbox-guest-agent.service

# run_command con as_root usa «sudo -n»: sudo sin contraseña para este usuario.
# La VM es un entorno desechable para el agente; no instales esto en máquinas que no lo sean.
SUDOERS_TMP=$(mktemp)
trap 'rm -f "$SUDOERS_TMP"' EXIT
echo "$USER_NAME ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_TMP"
visudo -cf "$SUDOERS_TMP"
install -m 0440 -o root -g root "$SUDOERS_TMP" /etc/sudoers.d/vmbox-guest-agent

USER_ID=$(id -u "$USER_NAME")
sudo -u "$USER_NAME" XDG_RUNTIME_DIR="/run/user/$USER_ID" systemctl --user daemon-reload
sudo -u "$USER_NAME" XDG_RUNTIME_DIR="/run/user/$USER_ID" systemctl --user restart vmbox-guest-agent.service
echo "vmbox-guest-agent instalado y en marcha (vsock:7000)."

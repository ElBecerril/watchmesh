#!/bin/bash
# =============================================================================
# RPi5 - Deshabilitar HW Watchdog (idempotente)
# =============================================================================
# Contexto: el RPi5 visor entro en reboot loop con ciclos de ~70s.
# Causa raiz: dtparam=watchdog=on (firmware) + RuntimeWatchdogSec=1m en
# /usr/lib/systemd/system.conf.d/40-rpi-enable-watchdog.conf (paquete oficial)
# activan el HW watchdog del BCM2835 con timeout 60s. Si systemd PID 1 se
# bloquea >60s (thermal throttle severo, IO hang SD, etc.), el SoC se resetea.
#
# Este script:
#   1. Crea override /etc/systemd/system.conf.d/99-disable-watchdog.conf
#   2. systemctl daemon-reexec para aplicar
#   3. Detiene y deshabilita el daemon /usr/sbin/watchdog (segunda capa)
#   4. Habilita journal persistente (/var/log/journal/) para capturar logs
#      de reboots futuros
#   5. Verifica el estado final
#
# Uso: sudo bash rpi5_disable_hw_watchdog.sh
# =============================================================================

set -e

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: ejecutar con sudo"
    exit 1
fi

echo "=== Aplicando fix HW watchdog RPi5 ==="

# 1. Override RuntimeWatchdogSec
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-disable-watchdog.conf <<'EOF'
[Manager]
RuntimeWatchdogSec=0
EOF
echo "[OK] Override creado: /etc/systemd/system.conf.d/99-disable-watchdog.conf"

# 2. Aplicar sin reboot
systemctl daemon-reexec
echo "[OK] systemd daemon-reexec aplicado"

# 3. Detener daemon watchdog (defensa en profundidad)
if systemctl is-enabled watchdog &>/dev/null; then
    systemctl stop watchdog 2>/dev/null || true
    systemctl disable watchdog 2>/dev/null || true
    echo "[OK] Daemon watchdog detenido y deshabilitado"
else
    echo "[SKIP] Daemon watchdog no estaba habilitado"
fi

# 4. Journal persistente
if [ ! -d /var/log/journal ] || [ -z "$(ls -A /var/log/journal 2>/dev/null)" ]; then
    mkdir -p /var/log/journal
    systemd-tmpfiles --create --prefix /var/log/journal
    systemctl restart systemd-journald
    echo "[OK] Journal persistente habilitado"
else
    echo "[SKIP] Journal ya persistente"
fi

# 5. Verificacion
echo ""
echo "=== Verificacion ==="
echo -n "RuntimeWatchdogUSec: "
systemctl show --property=RuntimeWatchdogUSec --value
echo -n "/sys/class/watchdog/watchdog0/state: "
cat /sys/class/watchdog/watchdog0/state 2>/dev/null || echo "NA"
echo -n "Daemon watchdog activo: "
systemctl is-active watchdog 2>/dev/null || echo "inactive"
echo -n "Journal persistente: "
[ -d /var/log/journal ] && echo "yes" || echo "no"

echo ""
echo "=== Listo ==="
echo "El HW watchdog ya no resetea el sistema bajo carga."
echo "Si hay un reboot inesperado, revisa: sudo journalctl -b -1 -p err"

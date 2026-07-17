#!/bin/bash
# Wrapper para autostart - espera compositor + red antes de iniciar cámaras
# v2.1 - Fix: esperar labwc para evitar ventanas encimadas

LOG=/tmp/matrix_autostart.log
echo "[$(date)] Autostart iniciado" > $LOG

# ============================================
# 1. ESPERAR COMPOSITOR (labwc) - CRÍTICO
# ============================================
echo "[$(date)] Esperando compositor labwc..." >> $LOG
for i in {1..60}; do
    if pgrep -x labwc > /dev/null 2>&1; then
        echo "[$(date)] Compositor labwc detectado (intento $i)" >> $LOG
        break
    fi
    if [ $i -eq 60 ]; then
        echo "[$(date)] ERROR: labwc no inició después de 60 intentos" >> $LOG
        exit 1
    fi
    sleep 1
done

# Esperar 5 segundos adicionales para que labwc se estabilice completamente
echo "[$(date)] Esperando estabilización del compositor..." >> $LOG
sleep 5

# ============================================
# 2. VERIFICAR DISPLAY
# ============================================
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/$(id -u)

if [ -z "$WAYLAND_DISPLAY" ]; then
    export WAYLAND_DISPLAY=wayland-0
fi

echo "[$(date)] DISPLAY=$DISPLAY, WAYLAND_DISPLAY=$WAYLAND_DISPLAY" >> $LOG

# ============================================
# 3. ESPERAR RED
# ============================================
echo "[$(date)] Esperando red..." >> $LOG
for i in {1..30}; do
    if ping -c 1 -W 2 198.51.100.1 > /dev/null 2>&1; then  # Cambiar a tu router
        echo "[$(date)] Red local disponible (intento $i)" >> $LOG
        break
    fi
    echo "[$(date)] Esperando red... intento $i" >> $LOG
    sleep 2
done

# ============================================
# 4. ESPERAR TAILSCALE (para cámaras remotas)
# ============================================
echo "[$(date)] Esperando Tailscale..." >> $LOG
for i in {1..15}; do
    if tailscale status > /dev/null 2>&1; then
        echo "[$(date)] Tailscale conectado (intento $i)" >> $LOG
        break
    fi
    sleep 2
done

# ============================================
# 5. INICIAR CÁMARAS
# ============================================
echo "[$(date)] Iniciando matrix_camaras.sh" >> $LOG
exec "$HOME/matrix_camaras.sh"  # Ajustar path si es necesario

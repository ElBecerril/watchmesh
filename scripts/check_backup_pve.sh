#!/usr/bin/env bash
# check_backup_pve.sh — Verifica el resultado del backup diario a pve y avisa por
# Telegram. Corre en el HOST proxmox-lugar1 (cron/timer 07:00). Creado (s5) para
# confirmar que el disparo automatico de backup-to-pve.timer (02:30) funciona en
# frio tras el fix del warmup. Doble como heartbeat diario del backup.
#
# Senal primaria: el LOG LOCAL (lectura local, nunca depende de la red). La
# verificacion independiente en pve es un EXTRA (con warmup), tolerante a ruta fria.
set -uo pipefail

ENV_FILE="${VIGILANCIA_ENV:-/etc/vigilancia/vigilancia.env}"
[[ -f "$ENV_FILE" ]] && { set -a; . "$ENV_FILE"; set +a; }

LOG_FILE="${BACKUP_LOG_FILE:-/var/log/backup_to_pve.log}"
PVE_HOST="${PVE_HOST:-100.64.10.6}"
PVE_USER="${PVE_USER:-root}"
PVE_DEST_DIR="${PVE_DEST_DIR:-/var/backups/vigilancia}"
ALERT_NOTIFY="${ALERT_NOTIFY:-$(dirname "$0")/alert_notify.sh}"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
STAMP="$(date '+%Y-%m-%d')"

notify() {
    local level="$1" text="$2"
    if [[ -x "$ALERT_NOTIFY" ]]; then
        "$ALERT_NOTIFY" "$level" "$text" >/dev/null 2>&1 && return 0
    fi
    # Fallback directo (sin jq) si alert_notify no esta o fallo.
    [[ "${TELEGRAM_TOKEN:-SET_}" == SET_* ]] && return 0
    curl -s --max-time 15 \
        "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID:-}" \
        --data-urlencode "text=[$level] $text" >/dev/null 2>&1 || true
}

# --- 1) Veredicto desde el LOG LOCAL: ultima linea decisiva de HOY gana ---
RESULT="UNKNOWN"
LAST_DECISIVE="$(grep -E "^\[${STAMP} .*\] (OK: promovido|FATAL:)" "$LOG_FILE" 2>/dev/null | tail -1)"
case "$LAST_DECISIVE" in
    *"OK: promovido"*) RESULT="OK" ;;
    *"FATAL:"*)        RESULT="FAIL" ;;
    *)                 RESULT="UNKNOWN" ;;
esac

# --- 2) Verificacion independiente en pve (EXTRA, con warmup, tolerante) ---
if command -v tailscale >/dev/null 2>&1; then
    for w in 1 2 3 4 5; do
        tailscale ping --c 3 --timeout 5s "$PVE_HOST" >/dev/null 2>&1 && break
        sleep 2
    done
fi
PVE_VERIFY="no-comprobado"
if ssh $SSH_OPTS "${PVE_USER}@${PVE_HOST}" \
     "cd '${PVE_DEST_DIR}/${STAMP}' 2>/dev/null && sha256sum -c manifest.sha256 >/dev/null 2>&1"; then
    PVE_VERIFY="sha256sum -c OK"
elif ssh $SSH_OPTS "${PVE_USER}@${PVE_HOST}" "test -d '${PVE_DEST_DIR}/${STAMP}'" 2>/dev/null; then
    PVE_VERIFY="carpeta existe pero checksum NO verifica"
else
    PVE_VERIFY="sin carpeta de hoy en pve (o ruta fria)"
fi

# --- 3) Avisar ---
case "$RESULT" in
    OK)
        notify OK "✅ Backup automatico ${STAMP} OK. Log: ${LAST_DECISIVE#*] }. pve: ${PVE_VERIFY}."
        ;;
    FAIL)
        notify SOS "❌ Backup automatico ${STAMP} FALLO. ${LAST_DECISIVE#*] }. pve: ${PVE_VERIFY}. Revisar ${LOG_FILE} en proxmox-lugar1."
        ;;
    *)
        notify ALERT "⚠️ Backup automatico ${STAMP}: SIN resultado decisivo en ${LOG_FILE} (¿el timer no disparo?). pve: ${PVE_VERIFY}."
        ;;
esac

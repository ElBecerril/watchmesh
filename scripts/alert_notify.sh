#!/bin/bash
# ============================================================
# alert_notify.sh  (RES-8) — Notificacion multi-canal con respaldo
#
# Hoy TODO el alerting depende de un unico bot de Telegram. Si Telegram
# (o su token) cae, no llega nada. Este helper manda la misma alerta por
# DOS vias independientes y devuelve 0 si AL MENOS UNA tuvo exito:
#   1) ntfy  (push self-host o ntfy.sh, sin cuenta) — via primaria de respaldo
#   2) Telegram — la via historica
#
# Reutilizable desde cualquier script (backup_to_pve.sh, emergency_watchdog,
# nightly_backup). Lee toda la config de env / EnvironmentFile (SEC-7).
#
# Uso:   alert_notify.sh <LEVEL> <mensaje...>
#   LEVEL = OK | WARN | SOS   (mapea a prioridad/emoji ntfy)
#
# Config (env):
#   NTFY_URL        p.ej. https://ntfy.sh/mi-canal-secreto-vigilancia   (vacio = off)
#   NTFY_TOKEN      opcional (Bearer) si el server ntfy requiere auth
#   TELEGRAM_TOKEN / TELEGRAM_CHAT_ID
# ============================================================

set -uo pipefail

LEVEL="${1:-WARN}"
shift || true
MSG="${*:-(sin mensaje)}"

NTFY_URL="${NTFY_URL:-}"
NTFY_TOKEN="${NTFY_TOKEN:-}"
TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-SET_TELEGRAM_TOKEN_IN_ENV}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-SET_TELEGRAM_CHAT_ID_IN_ENV}"
HOSTTAG="${ALERT_HOSTTAG:-$(hostname 2>/dev/null || echo host)}"

case "$LEVEL" in
    OK)   PRIO="default"; TAG="white_check_mark" ;;
    WARN) PRIO="high";    TAG="warning" ;;
    SOS)  PRIO="urgent";  TAG="rotating_light" ;;
    *)    PRIO="default"; TAG="information_source" ;;
esac

ok=1  # 1 = aun ningun envio exitoso

# --- Canal 1: ntfy ---
if [[ -n "$NTFY_URL" ]]; then
    auth=()
    [[ -n "$NTFY_TOKEN" ]] && auth=(-H "Authorization: Bearer ${NTFY_TOKEN}")
    if curl -s --max-time 12 "${auth[@]}" \
        -H "Title: Vigilancia [${LEVEL}] ${HOSTTAG}" \
        -H "Priority: ${PRIO}" \
        -H "Tags: ${TAG}" \
        -d "$MSG" "$NTFY_URL" >/dev/null 2>&1; then
        ok=0
    fi
fi

# --- Canal 2: Telegram ---
# NO depender de jq (no esta en el host proxmox-lugar1 -> el canal moria en silencio).
# curl --data-urlencode arma el form sin jq y escapa texto/emoji correctamente.
if [[ "$TELEGRAM_TOKEN" != SET_* ]]; then
    if curl -s --max-time 15 \
        "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=[$LEVEL] $MSG" >/dev/null 2>&1; then
        ok=0
    fi
fi

exit $ok

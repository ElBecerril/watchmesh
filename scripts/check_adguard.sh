#!/bin/bash
# ============================================================
# check_adguard.sh  (RES-10) — Watchdog del DNS de AdGuard (CT202)
#
# Vigila que el servidor DNS de AdGuard Home (LXC 202, .50:53) este
# resolviendo. Si deja de responder, alerta por ntfy+Telegram via
# alert_notify.sh. Pensado para dispositivos "criticos" (familiares) que
# apuntan SOLO a .50 sin DNS secundario: si AdGuard cae se quedan sin
# internet, asi que conviene enterarse al instante.
#
# IMPORTANTE: corre en el HOST proxmox-lugar1, NO dentro del LXC 202. Si corriera
# en el propio AdGuard y el LXC cae, no podria avisar.
#
# Alerta SOLO en transicion (UP->DOWN y DOWN->UP) para no spamear.
#
# Config (env / EnvironmentFile, SEC-7):
#   ADGUARD_IP            IP del DNS (default 192.0.2.50)
#   ADGUARD_PROBE_DOMAIN  dominio de prueba (default google.com)
#   NTFY_URL / TELEGRAM_* los usa alert_notify.sh
# ============================================================
set -uo pipefail

ENV_FILE="/etc/vigilancia/vigilancia.env"
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && { set -a; . "$ENV_FILE"; set +a; }

ADGUARD_IP="${ADGUARD_IP:-192.0.2.50}"
PROBE_DOMAIN="${ADGUARD_PROBE_DOMAIN:-google.com}"
STATE_FILE="${ADGUARD_STATE_FILE:-/run/adguard_dns_state}"
NOTIFY="/usr/local/bin/alert_notify.sh"
RETRIES=3
SLEEP_BETWEEN=5

# Una sonda: exito si dig devuelve al menos una IP A para el dominio.
probe() {
    local out
    out="$(dig +tries=1 +time=3 +short @"$ADGUARD_IP" "$PROBE_DOMAIN" A 2>/dev/null)"
    grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<<"$out"
}

# Reintentos para evitar alertar por un parpadeo puntual.
healthy=1  # 1 = sano
for ((i = 1; i <= RETRIES; i++)); do
    if probe; then healthy=0; break; fi
    [[ $i -lt $RETRIES ]] && sleep "$SLEEP_BETWEEN"
done

prev="UP"
[[ -f "$STATE_FILE" ]] && prev="$(cat "$STATE_FILE" 2>/dev/null || echo UP)"

if [[ $healthy -eq 0 ]]; then
    cur="UP"
    if [[ "$prev" == "DOWN" ]]; then
        "$NOTIFY" OK "AdGuard DNS (${ADGUARD_IP}) RECUPERADO: vuelve a resolver. La red protegida esta de nuevo en linea."
    fi
else
    cur="DOWN"
    if [[ "$prev" == "UP" ]]; then
        "$NOTIFY" SOS "AdGuard DNS (${ADGUARD_IP}) NO RESPONDE tras ${RETRIES} intentos. Los dispositivos que apuntan SOLO a .50 (familiares) se quedan SIN INTERNET. Revisar LXC 202 (pct status 202 / systemctl status AdGuardHome)."
    fi
fi

echo "$cur" >"$STATE_FILE"
[[ "$cur" == "UP" ]] && exit 0 || exit 1

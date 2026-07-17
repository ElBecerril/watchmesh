#!/usr/bin/env bash
# peer_watch.sh - dead-man's-switch CAPA 1 (RPi5/Lugar 1 vigila sitios remotos)
# Vigila Lugar 2 (proxy-lugar2) y pve (sitio 3) por Tailscale.
# Alerta por Telegram SOLO en transicion. Debounce FAIL_THRESHOLD fallos seguidos.
# Anti-tormenta: si TODOS los peers caen a la vez -> 1 alerta "aislado" (problema de MI red).
set -uo pipefail

STATE_DIR=/var/lib/peerwatch
mkdir -p "$STATE_DIR"
ENV_FILE=/etc/peerwatch/peerwatch.env
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
TO="${PEER_TIMEOUT:-10}"
WATCHER="${WATCHER_NAME:-RPi5-lugar1}"

# peers: "nombre target [puerto...]"  (puertos opcionales: al menos uno debe abrir)
PEERS=(
  "Lugar 2 100.64.10.3 5541 5542"
  "pve 100.64.10.6"
)

log(){ echo "$(date '+%F %T') $*"; }

notify(){
  local text="[$WATCHER] $1"
  if [ -n "$TELEGRAM_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
    if curl -s --max-time 15 "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${text}" >/dev/null 2>&1; then
      log "NOTIFY sent: $1"
    else
      log "NOTIFY FAILED (sin internet?): $1"
    fi
  else
    log "NOTIFY (sin creds): $1"
  fi
}

reachable(){  # target -- tolerante a path frio (DERP idle entre corridas): reintenta 1 vez
  timeout "$TO" tailscale ping --c 4 "$1" 2>/dev/null | grep -q pong && return 0
  sleep 2  # el intento anterior calienta la ruta; este suele acertar
  timeout "$TO" tailscale ping --c 6 "$1" 2>/dev/null | grep -q pong
}
port_open(){ timeout "$TO" bash -c "echo > /dev/tcp/$1/$2" 2>/dev/null; }

check_peer(){  # name target [ports...]
  local name="$1" tgt="$2"; shift 2
  reachable "$tgt" || return 1
  if [ "$#" -gt 0 ]; then
    for p in "$@"; do port_open "$tgt" "$p" && return 0; done
    return 1
  fi
  return 0
}

# --- evaluar todos los peers ---
declare -A RESULT
down_count=0; total=0
for entry in "${PEERS[@]}"; do
  read -r name tgt ports <<<"$entry"
  total=$((total+1))
  if check_peer "$name" "$tgt" $ports; then RESULT[$name]=up; else RESULT[$name]=down; down_count=$((down_count+1)); fi
done

# --- regla de auto-aislamiento: todos caidos = problema mio, no de los sitios ---
ISO="$STATE_DIR/_isolation.fail"
if [ "$down_count" -eq "$total" ] && [ "$total" -gt 1 ]; then
  c=$(cat "$ISO" 2>/dev/null || echo 0); c=$((c+1)); echo "$c" > "$ISO"
  log "ALL peers down (posible aislamiento) streak=$c"
  if [ "$c" -eq "$FAIL_THRESHOLD" ]; then
    notify "AISLADO: la RPi5 no alcanza NI a Lugar 2 NI a pve. Probable caida de MI red/Tailscale en Lugar 1 (no de los sitios remotos)."
  fi
  exit 0   # en aislamiento NO disparamos alertas por-peer (evita tormenta)
fi
if [ -f "$ISO" ]; then
  prev=$(cat "$ISO" 2>/dev/null || echo 0)
  [ "$prev" -ge "$FAIL_THRESHOLD" ] && notify "RED RECUPERADA: la RPi5 ya alcanza al menos un sitio remoto."
  rm -f "$ISO"
fi

# --- debounce + transicion por peer ---
for entry in "${PEERS[@]}"; do
  read -r name tgt ports <<<"$entry"
  fstate="$STATE_DIR/$name.fail"; sstate="$STATE_DIR/$name.status"
  status=$(cat "$sstate" 2>/dev/null || echo up)
  if [ "${RESULT[$name]}" = up ]; then
    echo 0 > "$fstate"
    if [ "$status" = down ]; then notify "RECUPERADO: '$name' ($tgt) responde de nuevo."; echo up > "$sstate"; fi
    log "$name OK"
  else
    c=$(cat "$fstate" 2>/dev/null || echo 0); c=$((c+1)); echo "$c" > "$fstate"
    log "$name DOWN streak=$c/$FAIL_THRESHOLD"
    if [ "$c" -eq "$FAIL_THRESHOLD" ] && [ "$status" != down ]; then
      notify "CAIDO: '$name' ($tgt) no responde tras $FAIL_THRESHOLD chequeos (~$((FAIL_THRESHOLD*5)) min). Revisar ese sitio."
      echo down > "$sstate"
    fi
  fi
done
exit 0

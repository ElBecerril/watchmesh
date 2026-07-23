#!/bin/bash
# ============================================================
# backup_to_pve.sh  (RES-2) — Backup REAL de lo irreemplazable
#
# Corre en el HOST proxmox-lugar1 (tiene `pct exec/pull` al LXC 200 y SSH
# Tailscale al servidor pve, que tiene ~100GB libres en el mesh).
#
# Copia al servidor pve, con verificacion por CHECKSUM y SIN borrar
# el origen (a diferencia de nightly_backup.sh, que hace tiering al HDD):
#   - people_counter.db  (SQLite, snapshot consistente via .backup)
#   - frigate config.yml + frigate.db / *.db (SQLite, snapshot)
#   - este repo de documentacion (opcional)
#
# NO copia las grabaciones de video (eso es nightly_backup.sh -> HDD).
# Lo de aqui es lo que NO se puede reconstruir: historico del contador
# y la config/estado de Frigate.
#
# Despliegue (ver tambien systemd/ — RES-9):
#   1) crear /etc/vigilancia/vigilancia.env (desde .env.example, chmod 600)
#   2) probar:  ./backup_to_pve.sh --dry-run
#   3) instalar el timer:  backup-to-pve.timer (diario nocturno, Persistent=true)
#
# Verificacion: cada archivo se compara por sha256 origen-vs-destino tras
# la copia; si NO coincide, se marca FALLO y se conserva la copia previa.
#
# Uso:  ./backup_to_pve.sh [--dry-run]
# ============================================================

set -euo pipefail

# === CONFIGURACION (todo override por env / EnvironmentFile) ===
LXC_ID="${LXC_ID:-200}"

# Destino: servidor pve por Tailscale.
PVE_HOST="${PVE_HOST:-100.64.10.6}"
PVE_USER="${PVE_USER:-root}"
PVE_DEST_DIR="${PVE_DEST_DIR:-/var/backups/vigilancia}"
SSH_OPTS="${SSH_OPTS:--o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new}"

# Rutas dentro del LXC 200 (se snapshotean los .db con sqlite3 .backup).
# Verificadas en vivo: config = config/frigate.yml; db = frigate_config/frigate.db.
PC_DB="${PC_DB:-/opt/vigilancia/people_counter.db}"
FRIGATE_CONFIG="${FRIGATE_CONFIG:-/opt/vigilancia/config/frigate.yml}"
FRIGATE_DB="${FRIGATE_DB:-/opt/vigilancia/frigate_config/frigate.db}"

# Retencion en pve (dias de snapshots diarios).
PVE_RETENTION_DAYS="${PVE_RETENTION_DAYS:-14}"

# Staging temporal en el host (se limpia siempre al salir).
STAGING="$(mktemp -d /tmp/vigi-backup.XXXXXX)"
LOG_FILE="${BACKUP_LOG_FILE:-/var/log/backup_to_pve.log}"

# Telegram (alerta). Si hay alert_notify.sh (RES-8) lo usa; si no, curl directo.
TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-SET_TELEGRAM_TOKEN_IN_ENV}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-SET_TELEGRAM_CHAT_ID_IN_ENV}"
ALERT_NOTIFY="${ALERT_NOTIFY:-$(dirname "$0")/alert_notify.sh}"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# Snapshot diario por fecha (idempotente dentro del mismo dia).
STAMP="$(date '+%Y-%m-%d')"
DEST_TODAY="${PVE_DEST_DIR}/${STAMP}"

cleanup() { rm -rf "$STAGING" 2>/dev/null || true; }
trap cleanup EXIT

# === FUNCIONES ===
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

notify() {
    local level="$1" text="$2"
    # Canal de respaldo (RES-8) si existe; siempre intenta Telegram tambien.
    if [[ -x "$ALERT_NOTIFY" ]]; then
        "$ALERT_NOTIFY" "$level" "$text" >/dev/null 2>&1 || true
    fi
    if [[ "$TELEGRAM_TOKEN" == SET_* ]]; then
        return 0
    fi
    # NO depender de jq (ausente en el host proxmox-lugar1 -> una vez la alerta SOS
    # del backup fallido murio en silencio porque jq fallaba y payload quedaba
    # vacio). curl --data-urlencode arma el form sin jq y escapa texto/emoji.
    curl -s --max-time 15 \
        "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "parse_mode=HTML" >/dev/null 2>&1 || true
}

# Snapshot consistente de una SQLite dentro del LXC -> fichero en staging.
# Devuelve 0 si copio, 1 si fallo, 2 si el origen no existe (skip).
snapshot_sqlite() {
    local src_in_lxc="$1" out_name="$2"
    if ! pct exec "$LXC_ID" -- test -f "$src_in_lxc"; then
        log "SKIP: no existe en LXC $LXC_ID: $src_in_lxc"
        return 2
    fi
    local tmp_in_lxc="/tmp/$(basename "$out_name")"
    # .backup es atomico/consistente aunque haya escrituras concurrentes (WAL).
    if pct exec "$LXC_ID" -- sqlite3 "$src_in_lxc" ".backup '$tmp_in_lxc'" 2>>"$LOG_FILE"; then
        pct pull "$LXC_ID" "$tmp_in_lxc" "${STAGING}/${out_name}" 2>>"$LOG_FILE"
        pct exec "$LXC_ID" -- rm -f "$tmp_in_lxc" 2>/dev/null || true
        log "OK snapshot SQLite: $src_in_lxc -> $out_name ($(du -h "${STAGING}/${out_name}" | cut -f1))"
        return 0
    fi
    # Fallback: sqlite3 ausente -> copia en frio (menos seguro pero util).
    log "WARN: sqlite3 fallo/ausente en LXC; copia en frio de $src_in_lxc"
    pct pull "$LXC_ID" "$src_in_lxc" "${STAGING}/${out_name}" 2>>"$LOG_FILE" && return 0
    return 1
}

# Copia un fichero plano del LXC al staging. 0 ok / 2 no existe.
pull_file() {
    local src_in_lxc="$1" out_name="$2"
    if ! pct exec "$LXC_ID" -- test -f "$src_in_lxc"; then
        log "SKIP: no existe en LXC $LXC_ID: $src_in_lxc"
        return 2
    fi
    pct pull "$LXC_ID" "$src_in_lxc" "${STAGING}/${out_name}" 2>>"$LOG_FILE"
    log "OK config: $src_in_lxc -> $out_name"
}

# sha256 de un fichero local (host).
sha_local() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
# sha256 de un fichero remoto (pve).
sha_remote() {
    ssh $SSH_OPTS "${PVE_USER}@${PVE_HOST}" "sha256sum '$1' 2>/dev/null | awk '{print \$1}'"
}

# === MAIN ===
log "===== backup_to_pve START (dry_run=$DRY_RUN) ====="

# 0) Pre-flight: pct y conexion a pve.
if ! command -v pct >/dev/null 2>&1; then
    log "FATAL: 'pct' no disponible. Este script corre en el HOST proxmox-lugar1."
    notify SOS "❌ backup_to_pve: 'pct' no disponible (¿no es el host proxmox-lugar1?)"
    exit 1
fi
# El path Tailscale proxmox-lugar1->pve se enfria si esta idle (ICMP no lo despierta, un
# TCP connect si). De madrugada, sin trafico, el primer SSH da timeout: una vez
# el disparo automatico FALLO. Root cause: el warmup usaba 'tailscale ping -c1'
# pero el flag correcto es '--c <n>' (en tailscale 1.98 '-c1' da "flag provided but
# not defined" -> exit 2), asi que el warmup NUNCA corrio y la ruta relay-DERP fria
# mato el SSH. Fix: sintaxis correcta (--c / --timeout) + insistencia + preflight
# SSH mas largo (8 intentos, backoff 8s). El timer es Persistent, no
# hay prisa: preferimos tardar minutos antes que declarar fallo. 'tailscale ping'
# tira los primeros pings por DERP, lo que despierta la ruta.
if command -v tailscale >/dev/null 2>&1; then
    for w in $(seq 1 6); do
        if tailscale ping --c 3 --timeout 5s "$PVE_HOST" >/dev/null 2>&1; then
            log "warmup: ruta Tailscale a pve establecida (intento ${w}/6)"
            break
        fi
        [[ $w -eq 6 ]] && log "warmup: tailscale ping no respondio tras 6 intentos; se intenta SSH igual"
        sleep 2
    done
fi
PVE_SSH_OK=0
for attempt in 1 2 3 4 5 6 7 8; do
    if ssh $SSH_OPTS "${PVE_USER}@${PVE_HOST}" 'true' 2>>"$LOG_FILE"; then
        PVE_SSH_OK=1; break
    fi
    log "preflight SSH a pve intento ${attempt}/8 fallo; reintentando en 8s..."
    sleep 8
done
if [[ $PVE_SSH_OK -ne 1 ]]; then
    log "FATAL: no hay SSH a pve ${PVE_USER}@${PVE_HOST} tras warmup + 8 reintentos"
    notify SOS "❌ backup_to_pve: sin SSH a pve ${PVE_HOST}. Backup NO realizado."
    exit 1
fi

# 1) Reunir snapshots en staging.
declare -a COLLECTED=()
FAILED=0

if snapshot_sqlite "$PC_DB" "people_counter.db"; then COLLECTED+=("people_counter.db")
elif [[ $? -eq 1 ]]; then FAILED=1; fi

if snapshot_sqlite "$FRIGATE_DB" "frigate.db"; then COLLECTED+=("frigate.db")
elif [[ $? -eq 1 ]]; then FAILED=1; fi

if pull_file "$FRIGATE_CONFIG" "config.yml"; then COLLECTED+=("config.yml")
elif [[ $? -eq 1 ]]; then FAILED=1; fi

if [[ ${#COLLECTED[@]} -eq 0 ]]; then
    log "FATAL: no se recolecto ningun fichero. Abortando sin tocar pve."
    notify SOS "❌ backup_to_pve: 0 ficheros recolectados del LXC ${LXC_ID}."
    exit 1
fi

# 2) Manifiesto con checksums de origen (para verificar tras la copia).
( cd "$STAGING" && sha256sum "${COLLECTED[@]}" > manifest.sha256 )
log "Recolectados: ${COLLECTED[*]}"

if $DRY_RUN; then
    log "DRY-RUN: se copiarian a ${PVE_USER}@${PVE_HOST}:${DEST_TODAY}/ :"
    ( cd "$STAGING" && du -h "${COLLECTED[@]}" manifest.sha256 | tee -a "$LOG_FILE" )
    log "===== backup_to_pve END (dry-run) ====="
    exit 0
fi

# 3) Copiar a pve (a un staging remoto, luego mover atomico).
REMOTE_TMP="${DEST_TODAY}.tmp"
ssh $SSH_OPTS "${PVE_USER}@${PVE_HOST}" "rm -rf '$REMOTE_TMP' && mkdir -p '$REMOTE_TMP'" 2>>"$LOG_FILE"

if ! rsync -a -e "ssh $SSH_OPTS" \
        "${STAGING}/" "${PVE_USER}@${PVE_HOST}:${REMOTE_TMP}/" 2>>"$LOG_FILE"; then
    log "FATAL: rsync a pve fallo (exit $?). Conservando snapshot previo en pve."
    ssh $SSH_OPTS "${PVE_USER}@${PVE_HOST}" "rm -rf '$REMOTE_TMP'" 2>/dev/null || true
    notify SOS "❌ backup_to_pve: rsync a pve FALLO. Snapshot previo intacto."
    exit 1
fi

# 4) Verificar checksum origen-vs-destino ANTES de promover.
VERIFY_FAIL=0
for f in "${COLLECTED[@]}"; do
    local_sum=$(sha_local "${STAGING}/${f}")
    remote_sum=$(sha_remote "${REMOTE_TMP}/${f}")
    if [[ -z "$local_sum" || "$local_sum" != "$remote_sum" ]]; then
        log "CHECKSUM MISMATCH: $f (local=$local_sum remote=$remote_sum)"
        VERIFY_FAIL=1
    else
        log "verify OK: $f ($local_sum)"
    fi
done

if [[ $VERIFY_FAIL -ne 0 ]]; then
    log "FATAL: verificacion de checksum fallo. NO se promueve, snapshot previo intacto."
    ssh $SSH_OPTS "${PVE_USER}@${PVE_HOST}" "rm -rf '$REMOTE_TMP'" 2>/dev/null || true
    notify SOS "❌ backup_to_pve: checksum NO coincide tras copiar. Backup descartado."
    exit 1
fi

# 5) Promover atomico (reemplaza el del dia si existe) + retencion.
ssh $SSH_OPTS "${PVE_USER}@${PVE_HOST}" \
    "rm -rf '$DEST_TODAY' && mv '$REMOTE_TMP' '$DEST_TODAY' && \
     find '$PVE_DEST_DIR' -maxdepth 1 -type d -name '20*' -mtime +${PVE_RETENTION_DAYS} -exec rm -rf {} +" \
    2>>"$LOG_FILE"

SIZE=$(ssh $SSH_OPTS "${PVE_USER}@${PVE_HOST}" "du -sh '$DEST_TODAY' | cut -f1" 2>/dev/null || echo "?")
MSG="✅ <b>Backup vigilancia → pve</b> OK
Fecha: ${STAMP}
Ficheros: ${COLLECTED[*]}
Tamaño: ${SIZE}
Retención: ${PVE_RETENTION_DAYS}d en ${PVE_HOST}:${PVE_DEST_DIR}"
[[ $FAILED -ne 0 ]] && MSG="⚠️ ${MSG}
(algun origen fallo la copia — revisar log)"

log "OK: promovido a ${DEST_TODAY} (${SIZE})"
notify OK "$MSG"
log "===== backup_to_pve END ====="

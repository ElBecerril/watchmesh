#!/bin/bash
# ============================================================
# Nightly Backup - Mueve grabaciones del NVMe al HDD externo
# Corre en HOST proxmox-lugar1 via systemd timer (horario nocturno configurable)
#
# Flujo:
#   1. Verifica que el HDD este montado
#   2. Copia recordings del dia anterior al HDD
#   3. Verifica integridad (tamano)
#   4. Elimina originales del NVMe
#   5. Copia clips/snapshots del dia anterior
#   6. Limpia clips viejos del NVMe
#   7. Reporta resultado por Telegram
#
# Uso manual: /root/nightly_backup.sh [--dry-run]
# ============================================================

set -euo pipefail

# === CONFIGURACION ===
LXC_ID="200"
HDD_MOUNT="/mnt/backup-hdd"
# HDD: preferir montaje por LABEL/UUID (estable) sobre /dev/sdbN, que cambia con
# el orden de enumeracion USB (BUG-17). Etiquetar el disco una sola vez:
#   e2label /dev/sdX1 <ETIQUETA>            (o anotar su UUID con: blkid /dev/sdX1)
HDD_LABEL="${HDD_LABEL:-}"
HDD_UUID="${HDD_UUID:-}"
HDD_DEVICE_FALLBACK="${HDD_DEVICE:-/dev/sdb1}"  # ultimo recurso si no hay label/uuid
RECORDINGS_SRC="/opt/vigilancia/storage/recordings"
CLIPS_SRC="/opt/vigilancia/storage/clips"
RECORDINGS_DST="${HDD_MOUNT}/recordings"
CLIPS_DST="${HDD_MOUNT}/clips"
LOG_FILE="/var/log/nightly_backup.log"

# Telegram
TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-SET_TELEGRAM_TOKEN_IN_ENV}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-SET_TELEGRAM_CHAT_ID_IN_ENV}"

# Retencion en HDD (dias)
HDD_RETENTION_DAYS=20

# Dry run mode
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# === FUNCIONES ===

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

send_telegram() {
    local text="$1"
    # NO depender de jq (ausente en el host proxmox-lugar1 -> el canal moria en silencio).
    # curl --data-urlencode escapa comillas/newlines/emoji sin jq (BUG-13).
    curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "parse_mode=HTML" \
        > /dev/null 2>&1 || log "WARN: Telegram send failed"
}

pct_exec() {
    pct exec "$LXC_ID" -- bash -c "$1" 2>/dev/null
}

get_dir_size() {
    # Obtiene tamano de directorio en bytes dentro del LXC
    pct_exec "du -sb $1 2>/dev/null | cut -f1" || echo "0"
}

resolve_hdd_device() {
    # Resuelve el dispositivo del HDD priorizando UUID > LABEL > fallback (BUG-17)
    if [ -n "$HDD_UUID" ] && [ -b "/dev/disk/by-uuid/$HDD_UUID" ]; then
        readlink -f "/dev/disk/by-uuid/$HDD_UUID"; return 0
    fi
    if [ -n "$HDD_LABEL" ] && [ -b "/dev/disk/by-label/$HDD_LABEL" ]; then
        readlink -f "/dev/disk/by-label/$HDD_LABEL"; return 0
    fi
    if [ -n "$HDD_DEVICE_FALLBACK" ] && [ -b "$HDD_DEVICE_FALLBACK" ]; then
        echo "$HDD_DEVICE_FALLBACK"; return 0
    fi
    return 1
}

check_hdd() {
    if ! mountpoint -q "$HDD_MOUNT" 2>/dev/null; then
        local dev
        if ! dev=$(resolve_hdd_device); then
            log "ERROR: HDD no detectado (label=$HDD_LABEL uuid=${HDD_UUID:-none} fallback=$HDD_DEVICE_FALLBACK)"
            return 1
        fi
        log "HDD no montado, intentando montar $dev..."
        mkdir -p "$HDD_MOUNT"
        mount "$dev" "$HDD_MOUNT" || return 1
    fi
    # Verificar escritura
    if ! touch "${HDD_MOUNT}/.backup_test" 2>/dev/null; then
        log "ERROR: HDD montado pero no se puede escribir"
        return 1
    fi
    rm -f "${HDD_MOUNT}/.backup_test"
    return 0
}

backup_recordings() {
    local date_dir="$1"  # e.g., YYYY-MM-DD
    local src="${RECORDINGS_SRC}/${date_dir}"
    local dst="${RECORDINGS_DST}/${date_dir}"

    # Verificar que existe en LXC
    local exists
    exists=$(pct_exec "[ -d '$src' ] && echo yes || echo no")
    if [ "$exists" != "yes" ]; then
        log "No hay recordings para $date_dir"
        return 0
    fi

    local src_size
    src_size=$(get_dir_size "$src")
    local src_size_h
    src_size_h=$(pct_exec "du -sh '$src' 2>/dev/null | cut -f1" || echo "?")

    log "Copiando recordings $date_dir ($src_size_h)..."

    if $DRY_RUN; then
        log "[DRY-RUN] rsync $src -> $dst"
        echo "$src_size_h"
        return 0
    fi

    # Crear destino en host
    mkdir -p "$dst"

    # Copiar desde LXC al HDD via rsync
    # LXC 200 rootfs es accesible desde host en /var/lib/lxc/200/rootfs/ (privilegiado)
    # O podemos usar pct pull, pero rsync es mas eficiente
    local lxc_rootfs="/var/lib/lxc/${LXC_ID}/rootfs"
    local full_src="${lxc_rootfs}${src}"

    # Copiar y CAPTURAR el resultado de la copia antes de tocar nada.
    local method=""
    local copy_ok=false
    if [ -d "$full_src" ]; then
        method="rsync"
        if rsync -a --info=progress2 "$full_src/" "$dst/" 2>> "$LOG_FILE"; then
            copy_ok=true
        else
            log "ERROR: rsync fallo (exit $?) para $date_dir"
        fi
    else
        # Fallback: copiar via pct exec + tar
        method="tar"
        log "Rootfs no accesible, usando tar pipe..."
        if pct_exec "tar -cf - -C '$src' ." | tar -xf - -C "$dst" 2>> "$LOG_FILE"; then
            copy_ok=true
        else
            log "ERROR: tar pipe fallo para $date_dir"
        fi
    fi

    if ! $copy_ok; then
        log "ERROR: copia ($method) fallida, NO se eliminan originales de $date_dir"
        echo "ERROR"
        return 1
    fi

    # Verificar integridad por CHECKSUM, no por tamano.
    # rsync en dry-run (-n) con --checksum compara hashes de ambos lados y lista
    # cualquier archivo que difiera. Salida vacia = origen y destino identicos.
    # Solo es posible con el metodo rsync (acceso directo al rootfs del LXC).
    if [ "$method" = "rsync" ]; then
        local verify_diff
        verify_diff=$(rsync -an --checksum --out-format='%n' "$full_src/" "$dst/" 2>> "$LOG_FILE")
        if [ -n "$verify_diff" ]; then
            local ndiff
            ndiff=$(printf '%s\n' "$verify_diff" | grep -c . || true)
            log "ERROR: verificacion checksum fallo para $date_dir (${ndiff} archivos difieren), NO se eliminan originales"
            echo "ERROR"
            return 1
        fi
        log "Verificacion checksum OK: $date_dir"
        # Eliminar original del NVMe SOLO tras copia + checksum verificados.
        log "Eliminando originales de $date_dir del NVMe..."
        pct_exec "rm -rf '$src'"
        log "Originales eliminados"
    else
        # Camino tar: no hay forma de verificar por checksum localmente -> NO borrar.
        log "AVISO: copia via tar sin verificacion checksum; se CONSERVAN los originales de $date_dir (eliminar manualmente tras validar)"
    fi

    echo "$src_size_h"
    return 0
}

backup_clips() {
    local date_str="$1"  # e.g., YYYY-MM-DD

    log "Copiando clips de $date_str..."

    if $DRY_RUN; then
        log "[DRY-RUN] clips backup"
        return 0
    fi

    mkdir -p "$CLIPS_DST"

    local lxc_rootfs="/var/lib/lxc/${LXC_ID}/rootfs"
    local full_src="${lxc_rootfs}${CLIPS_SRC}"

    if [ -d "$full_src" ]; then
        # Copiar clips de la fecha preservando rutas RELATIVAS a CLIPS_SRC (BUG-14),
        # no la jerarquia absoluta del rootfs del LXC. Asi aterrizan en CLIPS_DST/
        # y cleanup_hdd los encuentra.
        ( cd "$full_src" && find . -type f -newermt "$date_str" ! -newermt "${date_str} + 1 day" \
            -exec cp --parents -t "$CLIPS_DST/" {} \; ) 2>/dev/null || true
    fi

    # Limpiar clips viejos del NVMe (>1 dia)
    pct_exec "find '$CLIPS_SRC' -type f -mtime +1 -delete 2>/dev/null" || true
    pct_exec "find '$CLIPS_SRC' -type d -empty -delete 2>/dev/null" || true

    log "Clips procesados"
}

cleanup_hdd() {
    log "Limpiando backups > ${HDD_RETENTION_DAYS} dias en HDD..."

    if $DRY_RUN; then
        log "[DRY-RUN] cleanup HDD"
        return 0
    fi

    local count=0
    for dir in "${RECORDINGS_DST}"/*/; do
        [ -d "$dir" ] || continue
        local dir_date
        dir_date=$(basename "$dir")
        local dir_epoch
        dir_epoch=$(date -d "$dir_date" +%s 2>/dev/null) || continue
        local now_epoch
        now_epoch=$(date +%s)
        local age_days=$(( (now_epoch - dir_epoch) / 86400 ))

        if [ "$age_days" -gt "$HDD_RETENTION_DAYS" ]; then
            log "  Eliminando backup $dir_date (${age_days}d)"
            rm -rf "$dir"
            count=$((count + 1))
        fi
    done

    # Tambien clips viejos
    find "$CLIPS_DST" -type f -mtime +"$HDD_RETENTION_DAYS" -delete 2>/dev/null || true
    find "$CLIPS_DST" -type d -empty -delete 2>/dev/null || true

    log "HDD cleanup: $count directorios eliminados"
    echo "$count"
}

# === MAIN ===

log "============================================================"
log "Nightly Backup iniciando (dry_run=$DRY_RUN)"

# 1. Verificar HDD
if ! check_hdd; then
    msg="<b>BACKUP FALLIDO</b>

HDD externo no disponible en $HDD_MOUNT
Verificar conexion USB del disco."
    send_telegram "$msg"
    log "ABORTADO: HDD no disponible"
    exit 1
fi

hdd_free=$(df -h "$HDD_MOUNT" | tail -1 | awk '{print $4}')
log "HDD montado OK, libre: $hdd_free"

# 2. Determinar fecha a respaldar (ayer)
yesterday=$(date -d "yesterday" +%Y-%m-%d)
log "Respaldando fecha: $yesterday"

# 3. Backup recordings (capturar exit code real, NO tragarlo con || true)
rec_status=0
rec_size=$(backup_recordings "$yesterday") || rec_status=$?

# 4. Backup clips
clips_status=0
backup_clips "$yesterday" || clips_status=$?

# 5. Cleanup HDD viejo
cleaned=$(cleanup_hdd) || true

# 6. Estado final
nvme_use=$(pct_exec "df / --output=pcent | tail -1" | tr -d ' %')
hdd_use=$(df "$HDD_MOUNT" --output=pcent 2>/dev/null | tail -1 | tr -d ' %')
hdd_free_after=$(df -h "$HDD_MOUNT" | tail -1 | awk '{print $4}')

# Determinar resultado global
backup_failed=false
if [ "$rec_status" -ne 0 ] || [ "$clips_status" -ne 0 ]; then
    backup_failed=true
fi

if $backup_failed; then
    log "Backup con ERRORES: rec_status=$rec_status clips_status=$clips_status, NVMe=${nvme_use}%, HDD=${hdd_use}%"
else
    log "Backup completado: recordings=${rec_size:-0}, NVMe=${nvme_use}%, HDD=${hdd_use}%"
fi

# 7. Telegram report (refleja el resultado real)
if ! $DRY_RUN; then
    if $backup_failed; then
        if [ "$rec_status" -ne 0 ]; then rec_line="FALLO (originales conservados)"; else rec_line="OK ${rec_size:-sin datos}"; fi
        if [ "$clips_status" -ne 0 ]; then clips_line="FALLO"; else clips_line="OK"; fi
        msg="<b>BACKUP NOCTURNO CON ERRORES</b>

Fecha: $yesterday
Recordings: $rec_line
Clips: $clips_line
HDD libre: $hdd_free_after
NVMe uso: ${nvme_use}%
HDD uso: ${hdd_use}%
Revisar log: $LOG_FILE"
    else
        msg="<b>BACKUP NOCTURNO OK</b>

Fecha: $yesterday
Recordings: ${rec_size:-sin datos}
HDD libre: $hdd_free_after
NVMe uso: ${nvme_use}%
HDD uso: ${hdd_use}%
Backups antiguos limpiados: ${cleaned:-0}"
    fi
    send_telegram "$msg"
fi

log "============================================================"

# Exit code refleja el resultado para cron/systemd
if $backup_failed; then
    exit 1
fi

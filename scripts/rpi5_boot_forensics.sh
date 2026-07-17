#!/bin/bash
# =============================================================================
# RPi5 Boot Forensics
# =============================================================================
# Se ejecuta como systemd oneshot al final del boot. Captura logs del boot
# ANTERIOR (journalctl -b -1) y del boot actual a un archivo persistente.
# Marca con SUSPECT_RESET si el uptime previo fue corto (<10 min).
#
# Output:
#   /var/log/boot-forensics/boot-<timestamp>.log
#
# Mantiene los ultimos 20 archivos.
# =============================================================================

set -u

OUT_DIR=/var/log/boot-forensics
mkdir -p "$OUT_DIR"
chmod 755 "$OUT_DIR"

TS=$(date '+%Y-%m-%d_%H%M%S')
OUT="$OUT_DIR/boot-$TS.log"

prev_uptime_secs() {
    # Estima uptime del boot anterior tomando timestamps de journalctl --list-boots
    # Si solo hay un boot, retorna -1
    local line first last
    line=$(journalctl --list-boots --no-pager 2>/dev/null | awk '$1=="-1"{print; exit}')
    [ -z "$line" ] && echo -1 && return

    # Formato: IDX BOOT_ID FIRST_DATE FIRST_TIME TZ - LAST_DATE LAST_TIME TZ
    first=$(echo "$line" | awk '{print $3" "$4" "$5}')
    last=$(echo "$line" | awk '{print $7" "$8" "$9}')
    local f l
    f=$(date -d "$first" +%s 2>/dev/null) || { echo -1; return; }
    l=$(date -d "$last"  +%s 2>/dev/null) || { echo -1; return; }
    echo $((l - f))
}

PREV_UPTIME=$(prev_uptime_secs)
SUSPECT=""
if [ "$PREV_UPTIME" -ge 0 ] && [ "$PREV_UPTIME" -lt 600 ]; then
    SUSPECT=" [SUSPECT_RESET]"
fi

{
    echo "==============================================================="
    echo "BOOT FORENSICS - $(date)$SUSPECT"
    echo "==============================================================="
    echo
    echo "[host]            $(hostname)"
    echo "[uptime now]      $(uptime -p)"
    echo "[prev boot uptime] ${PREV_UPTIME}s ($(if [ "$PREV_UPTIME" -ge 0 ]; then echo "$((PREV_UPTIME/60))m $((PREV_UPTIME%60))s"; else echo "no previous boot"; fi))"
    echo "[temp]            $(vcgencmd measure_temp 2>/dev/null)"
    echo "[throttled]       $(vcgencmd get_throttled 2>/dev/null)"
    echo "[voltajes]"
    vcgencmd pmic_read_adc 2>/dev/null | grep -E "VDD_CORE|3V3_SYS|1V8|3V7" | sed 's/^/  /'
    echo
    echo "=== journalctl --list-boots ==="
    journalctl --list-boots --no-pager 2>&1 | tail -10
    echo

    if [ "$PREV_UPTIME" -ge 0 ]; then
        echo "=== PREVIOUS BOOT (-1) errors and warnings (last 100) ==="
        journalctl -b -1 -p warning --no-pager 2>&1 | tail -100
        echo
        echo "=== PREVIOUS BOOT (-1) last 80 lines (any priority) ==="
        journalctl -b -1 --no-pager 2>&1 | tail -80
        echo
    fi

    echo "=== CURRENT BOOT dmesg anomalies ==="
    dmesg -T 2>/dev/null | grep -iE "panic|oops|bug|hung|stall|under-volt|over-volt|throttl|thermal|i/o err|firmware|reset|reboot" | tail -40
    echo

    echo "=== RAM and swap ==="
    free -h
    echo
    echo "=== EXT4 filesystem health ==="
    dmesg -T 2>/dev/null | grep -iE "ext4|mmc|sdcard" | tail -15
    echo
    echo "==============================================================="
    echo "FIN $(date)"
    echo "==============================================================="
} > "$OUT" 2>&1

chmod 644 "$OUT"

# Rotacion: mantener solo los 20 ultimos
ls -1t "$OUT_DIR"/boot-*.log 2>/dev/null | tail -n +21 | xargs -r rm -f

# Si fue SUSPECT, copia rapida con prefijo SUSPECT_ para destacar
if [ -n "$SUSPECT" ]; then
    cp "$OUT" "$OUT_DIR/SUSPECT_boot-$TS.log"
fi

exit 0

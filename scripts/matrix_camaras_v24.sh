#!/bin/bash

# =============================================================================
# MATRIX DE 6 CÁMARAS CON WATCHDOG v2.4 - CPU Check + Network Monitor + Auto-restart
# =============================================================================
# Mejoras v2.4:
#   - Detecta streams congelados via CPU usage
#   - Monitorea conectividad de red
#   - Reinicio periódico preventivo cada 4 horas
# =============================================================================

LOG_FILE="/tmp/matrix_camaras.log"
WATCHDOG_INTERVAL=30
MAX_FAILURES=3
RESTART_COOLDOWN=300
PERIODIC_RESTART=14400  # 4 horas en segundos
CPU_THRESHOLD=2.0       # Si CPU < 2.0% se considera congelado
FROZEN_CYCLES=3         # Ciclos consecutivos bajo umbral para declarar congelado (90s)
ROUTER_IP="192.0.2.1"

# --- CONFIGURACIÓN DE CÁMARAS ---
declare -A CAM_URLS CAM_TITLES CAM_X CAM_Y CAM_W CAM_H CAM_LOW_CPU_COUNT

# Cargar URLs RTSP reales desde fichero externo gitignored (SEC-7).
# En el RPi5 crear /etc/vigilancia/cam_urls.env con las CAM_URLS[n]="rtsp://..." reales.
[ -f /etc/vigilancia/cam_urls.env ] && source /etc/vigilancia/cam_urls.env

CAM_TITLES[1]="CAM1-NVR";     CAM_X[1]=0;    CAM_Y[1]=0;   CAM_W[1]=640; CAM_H[1]=540
CAM_URLS[1]="${CAM_URLS[1]:-rtsp://USER:PASS@192.0.2.40:554/cam/realmonitor?channel=1&subtype=1}"

CAM_TITLES[2]="CAM2-NVR";     CAM_X[2]=640;  CAM_Y[2]=0;   CAM_W[2]=640; CAM_H[2]=540
CAM_URLS[2]="${CAM_URLS[2]:-rtsp://USER:PASS@192.0.2.40:554/cam/realmonitor?channel=2&subtype=1}"

CAM_TITLES[3]="CAM3-NVR";     CAM_X[3]=1280; CAM_Y[3]=0;   CAM_W[3]=640; CAM_H[3]=540
CAM_URLS[3]="${CAM_URLS[3]:-rtsp://USER:PASS@192.0.2.40:554/cam/realmonitor?channel=3&subtype=1}"

CAM_TITLES[4]="CAM4-ICSEE";   CAM_X[4]=0;    CAM_Y[4]=540; CAM_W[4]=640; CAM_H[4]=540
CAM_URLS[4]="${CAM_URLS[4]:-rtsp://USER:PASS@192.0.2.40:554/cam/realmonitor?channel=4&subtype=1}"

CAM_TITLES[5]="CAM5-LUGAR2"; CAM_X[5]=1280;  CAM_Y[5]=540; CAM_W[5]=640; CAM_H[5]=540
CAM_URLS[5]="${CAM_URLS[5]:-rtsp://USER:PASS@198.51.100.30/ch0_1.h264}"

CAM_TITLES[6]="CAM6-LUGAR2"; CAM_X[6]=640; CAM_Y[6]=540; CAM_W[6]=640; CAM_H[6]=540
CAM_URLS[6]="${CAM_URLS[6]:-rtsp://USER:PASS@198.51.100.40/ch0_1.h264}"

# Inicializar contadores de CPU baja
for i in 1 2 3 4 5 6; do CAM_LOW_CPU_COUNT[$i]=0; done

MPV_ARGS="--profile=low-latency --untimed --rtsp-transport=tcp --network-timeout=20 --no-border --no-osc --no-input-default-bindings --force-window=immediate --no-keepaspect-window --autofit=640x540 --no-audio"

FAILURE_COUNT=0
LAST_FULL_RESTART=0
LAST_PERIODIC_RESTART=0
NETWORK_WAS_DOWN=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ============= NUEVA: Verificar conectividad de red =============
check_network() {
    ping -c 1 -W 2 "$ROUTER_IP" > /dev/null 2>&1
}

# ============= NUEVA: Obtener CPU de un proceso mpv =============
get_mpv_cpu() {
    local title="$1"
    local pid=$(pgrep -f "title=$title" | head -1)
    [ -z "$pid" ] && echo "0" && return
    local cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
    [ -z "$cpu" ] && echo "0" && return
    echo "$cpu"
}

# ============= NUEVA: Verificar si cámara está congelada =============
check_camera_frozen() {
    local cam_num=$1
    local title="${CAM_TITLES[$cam_num]}"
    local cpu=$(get_mpv_cpu "$title")

    # Comparar con threshold usando bc
    local is_low=$(echo "$cpu < $CPU_THRESHOLD" | bc -l 2>/dev/null || echo "0")

    if [ "$is_low" = "1" ]; then
        ((CAM_LOW_CPU_COUNT[$cam_num]++))
        if [ ${CAM_LOW_CPU_COUNT[$cam_num]} -ge $FROZEN_CYCLES ]; then
            return 0  # Congelada
        fi
    else
        CAM_LOW_CPU_COUNT[$cam_num]=0
    fi
    return 1  # No congelada
}

start_camera() {
    local cam_num=$1
    local title="${CAM_TITLES[$cam_num]}"
    local url="${CAM_URLS[$cam_num]}"
    local x="${CAM_X[$cam_num]}"
    local y="${CAM_Y[$cam_num]}"
    local w="${CAM_W[$cam_num]}"
    local h="${CAM_H[$cam_num]}"

    # Matar instancia anterior si existe
    pkill -f "title=$title" 2>/dev/null
    sleep 1

    log "Iniciando $title en ${x},${y}..."
    DISPLAY=:0 mpv $MPV_ARGS --geometry="${w}x${h}+${x}+${y}" --title="$title" "$url" &
    sleep 2
    CAM_LOW_CPU_COUNT[$cam_num]=0
}

check_camera() {
    local cam_num=$1
    local title="${CAM_TITLES[$cam_num]}"
    pgrep -f "title=$title" > /dev/null 2>&1
}

fix_window_position() {
    local cam_num=$1
    local title="${CAM_TITLES[$cam_num]}"
    local target_x="${CAM_X[$cam_num]}"
    local target_y="${CAM_Y[$cam_num]}"
    local target_w="${CAM_W[$cam_num]}"
    local target_h="${CAM_H[$cam_num]}"

    local wid=$(DISPLAY=:0 xdotool search --name "$title" 2>/dev/null | head -1)
    [ -z "$wid" ] && return 1

    local geom=$(DISPLAY=:0 xdotool getwindowgeometry "$wid" 2>/dev/null)
    [ -z "$geom" ] && return 1

    local current_x=$(echo "$geom" | awk '/Position:/ {split($2,a,","); print a[1]}')
    local current_y=$(echo "$geom" | awk '/Position:/ {split($2,a,","); print a[2]}')

    if ! [[ "$current_x" =~ ^[0-9]+$ ]] || ! [[ "$current_y" =~ ^[0-9]+$ ]]; then
        DISPLAY=:0 xdotool windowsize "$wid" "$target_w" "$target_h"
        DISPLAY=:0 xdotool windowmove "$wid" "$target_x" "$target_y"
        return 2
    fi

    local diff_x=$((current_x - target_x))
    local diff_y=$((current_y - target_y))
    [ $diff_x -lt 0 ] && diff_x=$((diff_x * -1))
    [ $diff_y -lt 0 ] && diff_y=$((diff_y * -1))

    if [ $diff_x -gt 5 ] || [ $diff_y -gt 5 ]; then
        log "Reposicionando $title: ($current_x,$current_y) -> ($target_x,$target_y)"
        DISPLAY=:0 xdotool windowsize "$wid" "$target_w" "$target_h"
        DISPLAY=:0 xdotool windowmove "$wid" "$target_x" "$target_y"
        return 2
    fi
    return 0
}

check_and_fix_positions() {
    local fixed=0
    for cam_num in 1 2 3 4 5 6; do
        if check_camera "$cam_num"; then
            fix_window_position "$cam_num"
            [ $? -eq 2 ] && ((fixed++))
        fi
    done
    [ $fixed -gt 0 ] && log "Reposicionadas $fixed ventanas"
}

stop_all_cameras() {
    log "Deteniendo cámaras..."
    pkill mpv 2>/dev/null
    sleep 2
    pkill -9 mpv 2>/dev/null
    sleep 1
}

start_all_cameras() {
    log "=== INICIANDO CÁMARAS ==="
    for cam_num in 1 2 3 4 5 6; do
        start_camera "$cam_num"
    done
    log "Cámaras iniciadas"
    sleep 3
    check_and_fix_positions
}

full_restart() {
    local now=$(date +%s)
    local since=$((now - LAST_FULL_RESTART))

    if [ $LAST_FULL_RESTART -gt 0 ] && [ $since -lt $RESTART_COOLDOWN ]; then
        log "Esperando cooldown..."
        sleep $((RESTART_COOLDOWN - since))
    fi

    log "!!! REINICIO TOTAL !!!"
    stop_all_cameras
    sleep 3
    start_all_cameras
    FAILURE_COUNT=0
    LAST_FULL_RESTART=$(date +%s)
    LAST_PERIODIC_RESTART=$(date +%s)
}

watchdog_loop() {
    log "=== WATCHDOG v2.4 ACTIVO ==="
    log "    - CPU check: <${CPU_THRESHOLD}% por ${FROZEN_CYCLES} ciclos = congelado"
    log "    - Network monitor: ping $ROUTER_IP"
    log "    - Reinicio periódico: cada $((PERIODIC_RESTART/3600))h"

    LAST_PERIODIC_RESTART=$(date +%s)

    while true; do
        sleep "$WATCHDOG_INTERVAL"

        # ============= CHECK 1: Conectividad de red =============
        if ! check_network; then
            if [ $NETWORK_WAS_DOWN -eq 0 ]; then
                log "RED CAÍDA - Esperando reconexión..."
                NETWORK_WAS_DOWN=1
            fi
            continue
        elif [ $NETWORK_WAS_DOWN -eq 1 ]; then
            log "RED RESTAURADA - Reiniciando cámaras..."
            NETWORK_WAS_DOWN=0
            sleep 5
            full_restart
            continue
        fi

        # ============= CHECK 2: Procesos caídos =============
        for cam_num in 1 2 3 4 5 6; do
            if ! check_camera "$cam_num"; then
                log "ALERTA: ${CAM_TITLES[$cam_num]} proceso caído"
                start_camera "$cam_num"
                sleep 2
                if check_camera "$cam_num"; then
                    log "OK: ${CAM_TITLES[$cam_num]} recuperada"
                    fix_window_position "$cam_num"
                else
                    log "ERROR: ${CAM_TITLES[$cam_num]} no recuperada"
                    ((FAILURE_COUNT++))
                fi
            fi
        done

        # ============= CHECK 3: Streams congelados (CPU) =============
        for cam_num in 1 2 3 4 5 6; do
            if check_camera "$cam_num" && check_camera_frozen "$cam_num"; then
                log "CONGELADA: ${CAM_TITLES[$cam_num]} (CPU baja por ${FROZEN_CYCLES} ciclos)"
                start_camera "$cam_num"
                sleep 2
                fix_window_position "$cam_num"
            fi
        done

        # ============= CHECK 4: Reinicio periódico =============
        local now=$(date +%s)
        local since_periodic=$((now - LAST_PERIODIC_RESTART))
        if [ $since_periodic -ge $PERIODIC_RESTART ]; then
            log "REINICIO PERIÓDICO (cada $((PERIODIC_RESTART/3600))h)"
            full_restart
            continue
        fi

        check_and_fix_positions

        [ $FAILURE_COUNT -ge $MAX_FAILURES ] && full_restart

        local active=$(pgrep -c mpv 2>/dev/null || echo 0)
        [ "$active" -ne 6 ] && log "Estado: $active/6 activas"
    done
}

cleanup() {
    log "Terminando..."
    stop_all_cameras
    exit 0
}

trap cleanup SIGINT SIGTERM

log "========================================"
log "MATRIX CÁMARAS v2.4 - WATCHDOG MEJORADO"
log "========================================"

stop_all_cameras
start_all_cameras

active=$(pgrep -c mpv 2>/dev/null || echo 0)
log "Inicio: $active/6 cámaras"

watchdog_loop

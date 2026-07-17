#!/bin/bash

# =============================================================================
# MATRIX DE 6 CÁMARAS CON WATCHDOG v2.5.1 - Position Check + CPU + Network
# =============================================================================
# Mejoras v2.5.1:
#   - Validación de dependencias al inicio (bc, xdotool, mpv)
#   - Ping -c 3 para evitar falsos positivos de red
# Mejoras v2.5:
#   - Detecta ventanas encimadas (overlapping) y reinicia
#   - Verificación de posiciones cada ciclo
#   - Detecta streams congelados via CPU usage
#   - Monitorea conectividad de red
#   - Reinicio periódico preventivo cada 4 horas
# =============================================================================

# --- VALIDACIÓN DE DEPENDENCIAS ---
for cmd in xdotool bc mpv ping pgrep; do
    if ! command -v $cmd &> /dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR CRÍTICO: $cmd no está instalado" >&2
        echo "Instalar con: sudo apt install $cmd"
        exit 1
    fi
done

LOG_FILE="/tmp/matrix_camaras.log"
WATCHDOG_INTERVAL=30
MAX_FAILURES=3
RESTART_COOLDOWN=300
PERIODIC_RESTART=14400  # 4 horas en segundos
CPU_THRESHOLD=2.0       # Si CPU < 2.0% se considera congelado
FROZEN_CYCLES=3         # Ciclos consecutivos bajo umbral para declarar congelado
ROUTER_IP="198.51.100.1"  # Cambiar a tu router
POSITION_TOLERANCE=10   # Tolerancia en pixels para posición

# --- CONFIGURACIÓN DE CÁMARAS ---
declare -A CAM_URLS CAM_TITLES CAM_X CAM_Y CAM_W CAM_H CAM_LOW_CPU_COUNT

# Configurar tus cámaras aquí (ejemplo con NVR de 4 canales + 2 cámaras IP)
CAM_TITLES[1]="CAM1-NVR";     CAM_X[1]=0;    CAM_Y[1]=0;   CAM_W[1]=640; CAM_H[1]=540
CAM_URLS[1]="rtsp://usuario:password@198.51.100.60:554/cam/realmonitor?channel=1&subtype=1"

CAM_TITLES[2]="CAM2-NVR";     CAM_X[2]=640;  CAM_Y[2]=0;   CAM_W[2]=640; CAM_H[2]=540
CAM_URLS[2]="rtsp://usuario:password@198.51.100.60:554/cam/realmonitor?channel=2&subtype=1"

CAM_TITLES[3]="CAM3-NVR";     CAM_X[3]=1280; CAM_Y[3]=0;   CAM_W[3]=640; CAM_H[3]=540
CAM_URLS[3]="rtsp://usuario:password@198.51.100.60:554/cam/realmonitor?channel=3&subtype=1"

CAM_TITLES[4]="CAM4-NVR";     CAM_X[4]=0;    CAM_Y[4]=540; CAM_W[4]=640; CAM_H[4]=540
CAM_URLS[4]="rtsp://usuario:password@198.51.100.60:554/cam/realmonitor?channel=4&subtype=1"

CAM_TITLES[5]="CAM5-IPCAM";   CAM_X[5]=1280; CAM_Y[5]=540; CAM_W[5]=640; CAM_H[5]=540
CAM_URLS[5]="rtsp://usuario:password@198.51.100.61/stream1"

CAM_TITLES[6]="CAM6-IPCAM";   CAM_X[6]=640;  CAM_Y[6]=540; CAM_W[6]=640; CAM_H[6]=540
CAM_URLS[6]="rtsp://usuario:password@198.51.100.62/stream1"

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

check_network() {
    # Usar -c 3 para evitar falsos positivos por packet loss ocasional
    ping -c 3 -W 2 "$ROUTER_IP" > /dev/null 2>&1
}

get_mpv_cpu() {
    local title="$1"
    local pid=$(pgrep -f "title=$title" | head -1)
    [ -z "$pid" ] && echo "0" && return
    local cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
    [ -z "$cpu" ] && echo "0" && return
    echo "$cpu"
}

check_camera_frozen() {
    local cam_num=$1
    local title="${CAM_TITLES[$cam_num]}"
    local cpu=$(get_mpv_cpu "$title")
    local is_low=$(echo "$cpu < $CPU_THRESHOLD" | bc -l 2>/dev/null || echo "0")

    if [ "$is_low" = "1" ]; then
        ((CAM_LOW_CPU_COUNT[$cam_num]++))
        if [ ${CAM_LOW_CPU_COUNT[$cam_num]} -ge $FROZEN_CYCLES ]; then
            return 0
        fi
    else
        CAM_LOW_CPU_COUNT[$cam_num]=0
    fi
    return 1
}

# ============= OBTENER POSICIÓN ACTUAL DE VENTANA =============
get_window_position() {
    local title="$1"
    local wid=$(DISPLAY=:0 xdotool search --name "$title" 2>/dev/null | head -1)
    [ -z "$wid" ] && echo "" && return

    local geom=$(DISPLAY=:0 xdotool getwindowgeometry "$wid" 2>/dev/null)
    [ -z "$geom" ] && echo "" && return

    local pos=$(echo "$geom" | grep "Position:" | awk '{print $2}' | cut -d'(' -f1)
    echo "$pos"
}

# ============= VERIFICAR SI HAY VENTANAS ENCIMADAS =============
check_overlapping() {
    declare -A positions
    local overlapped=0

    for cam_num in 1 2 3 4 5 6; do
        local title="${CAM_TITLES[$cam_num]}"
        local pos=$(get_window_position "$title")

        if [ -n "$pos" ]; then
            # Redondear a grupos de 100 pixels para detectar encimamiento
            local x=$(echo "$pos" | cut -d',' -f1)
            local y=$(echo "$pos" | cut -d',' -f2)

            # Validar que sean números
            if [[ "$x" =~ ^[0-9]+$ ]] && [[ "$y" =~ ^[0-9]+$ ]]; then
                local key="$((x/100))_$((y/100))"

                if [ -n "${positions[$key]}" ]; then
                    ((overlapped++))
                    log "ENCIMADAS: $title y ${positions[$key]} en posición similar ($pos)"
                fi
                positions[$key]="$title"
            fi
        fi
    done

    return $overlapped
}

# ============= VERIFICAR POSICIÓN DE UNA CÁMARA =============
check_camera_position() {
    local cam_num=$1
    local title="${CAM_TITLES[$cam_num]}"
    local target_x="${CAM_X[$cam_num]}"
    local target_y="${CAM_Y[$cam_num]}"

    local pos=$(get_window_position "$title")
    [ -z "$pos" ] && return 1

    local current_x=$(echo "$pos" | cut -d',' -f1)
    local current_y=$(echo "$pos" | cut -d',' -f2)

    # Validar que sean números
    if ! [[ "$current_x" =~ ^[0-9]+$ ]] || ! [[ "$current_y" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    local diff_x=$((current_x - target_x))
    local diff_y=$((current_y - target_y))
    [ $diff_x -lt 0 ] && diff_x=$((diff_x * -1))
    [ $diff_y -lt 0 ] && diff_y=$((diff_y * -1))

    if [ $diff_x -gt $POSITION_TOLERANCE ] || [ $diff_y -gt $POSITION_TOLERANCE ]; then
        return 1  # Mal posicionada
    fi
    return 0  # OK
}

# ============= CORREGIR POSICIÓN DE UNA CÁMARA =============
fix_window_position() {
    local cam_num=$1
    local title="${CAM_TITLES[$cam_num]}"
    local target_x="${CAM_X[$cam_num]}"
    local target_y="${CAM_Y[$cam_num]}"
    local target_w="${CAM_W[$cam_num]}"
    local target_h="${CAM_H[$cam_num]}"

    local wid=$(DISPLAY=:0 xdotool search --name "$title" 2>/dev/null | head -1)
    [ -z "$wid" ] && return 1

    log "Reposicionando $title -> ($target_x,$target_y)"
    DISPLAY=:0 xdotool windowsize "$wid" "$target_w" "$target_h"
    sleep 0.2
    DISPLAY=:0 xdotool windowmove "$wid" "$target_x" "$target_y"
    return 0
}

# ============= VERIFICAR Y CORREGIR TODAS LAS POSICIONES =============
check_and_fix_positions() {
    local misplaced=0

    # Primero verificar encimamiento
    check_overlapping
    local overlapped=$?

    if [ $overlapped -ge 2 ]; then
        log "ALERTA: $overlapped+ ventanas encimadas - REINICIO TOTAL"
        return 2  # Señal para reinicio total
    fi

    # Verificar posiciones individuales
    for cam_num in 1 2 3 4 5 6; do
        if check_camera $cam_num; then
            if ! check_camera_position $cam_num; then
                ((misplaced++))
                fix_window_position $cam_num
                sleep 0.5
            fi
        fi
    done

    [ $misplaced -gt 0 ] && log "Corregidas $misplaced ventanas mal posicionadas"
    return 0
}

start_camera() {
    local cam_num=$1
    local title="${CAM_TITLES[$cam_num]}"
    local url="${CAM_URLS[$cam_num]}"
    local x="${CAM_X[$cam_num]}"
    local y="${CAM_Y[$cam_num]}"
    local w="${CAM_W[$cam_num]}"
    local h="${CAM_H[$cam_num]}"

    pkill -f "title=$title" 2>/dev/null
    sleep 1

    log "Iniciando $title en ${x},${y}..."
    DISPLAY=:0 mpv $MPV_ARGS --geometry="${w}x${h}+${x}+${y}" --title="$title" "$url" &
    sleep 3
    CAM_LOW_CPU_COUNT[$cam_num]=0
}

check_camera() {
    local cam_num=$1
    local title="${CAM_TITLES[$cam_num]}"
    pgrep -f "title=$title" > /dev/null 2>&1
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
    log "=== WATCHDOG v2.5.1 ACTIVO ==="
    log "    - Position check: detecta encimamiento y corrige"
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

        # ============= CHECK 2: Posiciones (NUEVO v2.5) =============
        check_and_fix_positions
        if [ $? -eq 2 ]; then
            full_restart
            continue
        fi

        # ============= CHECK 3: Procesos caídos =============
        for cam_num in 1 2 3 4 5 6; do
            if ! check_camera "$cam_num"; then
                log "ALERTA: ${CAM_TITLES[$cam_num]} proceso caído"
                start_camera "$cam_num"
                sleep 2
                if check_camera "$cam_num"; then
                    log "OK: ${CAM_TITLES[$cam_num]} recuperada"
                else
                    log "ERROR: ${CAM_TITLES[$cam_num]} no recuperada"
                    ((FAILURE_COUNT++))
                fi
            fi
        done

        # ============= CHECK 4: Streams congelados (CPU) =============
        for cam_num in 1 2 3 4 5 6; do
            if check_camera "$cam_num" && check_camera_frozen "$cam_num"; then
                log "CONGELADA: ${CAM_TITLES[$cam_num]} (CPU baja por ${FROZEN_CYCLES} ciclos)"
                start_camera "$cam_num"
            fi
        done

        # ============= CHECK 5: Reinicio periódico =============
        local now=$(date +%s)
        local since_periodic=$((now - LAST_PERIODIC_RESTART))
        if [ $since_periodic -ge $PERIODIC_RESTART ]; then
            log "REINICIO PERIÓDICO (cada $((PERIODIC_RESTART/3600))h)"
            full_restart
            continue
        fi

        [ $FAILURE_COUNT -ge $MAX_FAILURES ] && full_restart
    done
}

cleanup() {
    log "Terminando..."
    stop_all_cameras
    exit 0
}

trap cleanup SIGINT SIGTERM

log "========================================"
log "MATRIX CÁMARAS v2.5 - POSITION CHECK"
log "========================================"

stop_all_cameras
start_all_cameras

active=$(pgrep -c mpv 2>/dev/null || echo 0)
log "Inicio: $active/6 cámaras"

watchdog_loop

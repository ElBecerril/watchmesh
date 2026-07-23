#!/bin/bash

# =============================================================================
# MATRIX DE 6 CAMARAS CON WATCHDOG v3.4
# =============================================================================
# v3.4:
#   - Todas las camaras via go2rtc restream en proxmox-lugar1 (192.0.2.20)
#   - go2rtc es unico consumidor RTSP (resuelve limite ICSee 1 conexion)
#   - cam5/cam6 ya no son VPN desde RPi5 (go2rtc maneja ruta Tailscale)
#
# Fix v3.3:
#   - CAM4: agregar --untimed, --cache=no, reducir buffers (fix 48% freezes)
#   - Ventana de mantenimiento configurable (evitar cascada por reinicio del router)
#   - Limpieza de procesos mpv huerfanos cada ciclo
#
# Fix v3.2:
#   - Argumentos especiales para CAM4 (ICSee PTZ) con mayor resolucion
#   - Cache y buffer extra para evitar congelamientos por stream inestable
#   - Bug fix: pgrep -c || echo 0 causaba "0\n0" cuando no habia matches
#
# Mejoras v3.0:
#   - Verificacion de conectividad VPN antes de reiniciar CAM5/CAM6
#   - Backoff exponencial para reinicios fallidos
#   - Estado VPN separado (no reinicia si VPN esta caida)
#   - Simplificado: solo usa CPU check (elimina tracking de bytes complejo)
# =============================================================================

LOG_FILE="/tmp/matrix_camaras.log"
WATCHDOG_INTERVAL=30
MAX_FAILURES=3
RESTART_COOLDOWN=300
PERIODIC_RESTART=14400       # 4 horas - reinicio general
VPN_CHECK_INTERVAL=120       # 2 minutos - check de VPN cuando esta caida
CPU_THRESHOLD=2.0
FROZEN_CYCLES=3
ROUTER_IP="192.0.2.1"

# Ventana de mantenimiento: franja diaria en la que se suprimen los CHECK 3-6.
# Util si tu router/ISP hace un reinicio programado a la misma hora cada dia.
# Vacio = desactivada. Configurala por entorno segun TU despliegue, p.ej.:
#   MAINTENANCE_START=HH:MM MAINTENANCE_END=HH:MM matrix_camaras.sh
MAINTENANCE_START="${MAINTENANCE_START:-}"
MAINTENANCE_END="${MAINTENANCE_END:-}"

# IP del peer Tailscale del Lugar 2 para verificar conectividad VPN
VPN_PEER_IP="100.64.10.3"  # proxy-lugar2 (proxy RTSP Lugar 2)


# Backoff exponencial (segundos de espera segun fallos consecutivos)
BACKOFF_LEVEL1=60    # 3-5 fallos: esperar 1 minuto
BACKOFF_LEVEL2=300   # 6-9 fallos: esperar 5 minutos
BACKOFF_LEVEL3=900   # 10+ fallos: esperar 15 minutos

# --- CONFIGURACION DE CAMARAS ---
declare -A CAM_URLS CAM_TITLES CAM_X CAM_Y CAM_W CAM_H CAM_LOW_CPU_COUNT
declare -A CAM_FAIL_COUNT CAM_LAST_RESTART

CAM_TITLES[1]="CAM1-NVR";     CAM_X[1]=0;    CAM_Y[1]=0;   CAM_W[1]=640; CAM_H[1]=540;CAM_URLS[1]="rtsp://192.0.2.20:8554/cam1"

CAM_TITLES[2]="CAM2-NVR";     CAM_X[2]=640;  CAM_Y[2]=0;   CAM_W[2]=640; CAM_H[2]=540;CAM_URLS[2]="rtsp://192.0.2.20:8554/cam2"

CAM_TITLES[3]="CAM3-NVR";     CAM_X[3]=1280; CAM_Y[3]=0;   CAM_W[3]=640; CAM_H[3]=540;CAM_URLS[3]="rtsp://192.0.2.20:8554/cam3"

CAM_TITLES[4]="CAM4-ICSEE";   CAM_X[4]=0;    CAM_Y[4]=540; CAM_W[4]=640; CAM_H[4]=540;CAM_URLS[4]="rtsp://192.0.2.20:8554/cam4"

CAM_TITLES[5]="CAM5-LUGAR2"; CAM_X[5]=1280; CAM_Y[5]=540; CAM_W[5]=640; CAM_H[5]=540;CAM_URLS[5]="rtsp://192.0.2.20:8554/cam5"

CAM_TITLES[6]="CAM6-LUGAR2"; CAM_X[6]=640;  CAM_Y[6]=540; CAM_W[6]=640; CAM_H[6]=540;CAM_URLS[6]="rtsp://192.0.2.20:8554/cam6"

# Inicializar contadores
for i in 1 2 3 4 5 6; do
    CAM_LOW_CPU_COUNT[$i]=0
    CAM_FAIL_COUNT[$i]=0
    CAM_LAST_RESTART[$i]=0
done

MPV_ARGS="--vo=gpu --gpu-context=x11egl --profile=low-latency --untimed --rtsp-transport=tcp --network-timeout=20 --no-border --no-osc --no-input-default-bindings --force-window=immediate --no-keepaspect-window --autofit=640x540 --no-audio"
# Argumentos especiales para CAM4 - tiene resolucion 800x448 vs 352x240 de las otras
# --untimed es critico: sin el, mpv sincroniza con reloj RTSP causando stalls
MPV_ARGS_CAM4="--vo=gpu --gpu-context=x11egl --profile=low-latency --untimed --rtsp-transport=tcp --network-timeout=30 --cache=no --demuxer-max-bytes=2M --demuxer-readahead-secs=1 --no-border --no-osc --no-input-default-bindings --force-window=immediate --no-keepaspect-window --autofit=640x540 --no-audio"

FAILURE_COUNT=0
LAST_FULL_RESTART=0
LAST_PERIODIC_RESTART=0
NETWORK_WAS_DOWN=0
VPN_AVAILABLE=0
VPN_LAST_CHECK=0
VPN_LAST_LOG=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ============= Validar dependencias =============
check_dependencies() {
    local missing=0
    for cmd in xdotool bc mpv ping pgrep awk; do
        if ! command -v $cmd &> /dev/null; then
            echo "ERROR CRITICO: $cmd no esta instalado"
            missing=1
        fi
    done
    [ $missing -eq 1 ] && exit 1
}

# ============= Verificar conectividad de red local =============
check_network() {
    ping -c 3 -W 2 "$ROUTER_IP" > /dev/null 2>&1
}

# ============= NUEVO: Verificar conectividad VPN =============
check_vpn_connectivity() {
    # Verifica conectividad real al peer Tailscale del Lugar 2
    ping -c 1 -W 3 "$VPN_PEER_IP" > /dev/null 2>&1 && return 0
    return 1
}

# ============= Verificar ventana de mantenimiento =============
is_maintenance_window() {
    # Sin ventana configurada -> nunca suprime checks
    [[ -z "$MAINTENANCE_START" || -z "$MAINTENANCE_END" ]] && return 1
    local now_hhmm=$(date '+%H:%M')
    [[ ! "$now_hhmm" < "$MAINTENANCE_START" && "$now_hhmm" < "$MAINTENANCE_END" ]]
}

# ============= Limpiar procesos mpv huerfanos =============
cleanup_orphan_mpv() {
    # Recopilar PIDs de camaras conocidas
    local known_pids=""
    for cam_num in 1 2 3 4 5 6; do
        local title="${CAM_TITLES[$cam_num]}"
        local pids=$(pgrep -f "title=$title" 2>/dev/null)
        [ -n "$pids" ] && known_pids="$known_pids $pids"
    done

    # Obtener todos los PIDs mpv
    local all_mpv_pids=$(pgrep mpv 2>/dev/null)
    [ -z "$all_mpv_pids" ] && return

    # Matar huerfanos (no matchean ninguna camara)
    for pid in $all_mpv_pids; do
        local is_known=0
        for kpid in $known_pids; do
            [ "$pid" = "$kpid" ] && is_known=1 && break
        done
        if [ $is_known -eq 0 ]; then
            log "HUERFANO: matando mpv PID $pid"
            kill "$pid" 2>/dev/null
            sleep 1
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        fi
    done

    # Matar duplicados por camara (mantener solo el mas reciente)
    for cam_num in 1 2 3 4 5 6; do
        local title="${CAM_TITLES[$cam_num]}"
        local pids=$(pgrep -f "title=$title" 2>/dev/null)
        [ -z "$pids" ] && continue
        local count=$(echo "$pids" | wc -l)
        if [ "$count" -gt 1 ]; then
            local newest=$(echo "$pids" | tail -1)
            for pid in $pids; do
                if [ "$pid" != "$newest" ]; then
                    log "DUPLICADO: matando $title PID $pid (manteniendo $newest)"
                    kill "$pid" 2>/dev/null
                    sleep 0.5
                    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
                fi
            done
        fi
    done
}

# ============= Calcular tiempo de backoff =============
get_backoff_time() {
    local cam_num=$1
    local fails=${CAM_FAIL_COUNT[$cam_num]}

    if [ $fails -ge 10 ]; then
        echo $BACKOFF_LEVEL3
    elif [ $fails -ge 6 ]; then
        echo $BACKOFF_LEVEL2
    elif [ $fails -ge 3 ]; then
        echo $BACKOFF_LEVEL1
    else
        echo 0
    fi
}

# ============= NUEVO: Verificar si camara puede reiniciarse (backoff) =============
can_restart_camera() {
    local cam_num=$1
    local now=$(date +%s)
    local last_restart=${CAM_LAST_RESTART[$cam_num]}
    local backoff=$(get_backoff_time $cam_num)

    if [ $backoff -eq 0 ]; then
        return 0  # Sin backoff, puede reiniciar
    fi

    local elapsed=$((now - last_restart))
    if [ $elapsed -ge $backoff ]; then
        return 0  # Tiempo de backoff cumplido
    fi

    return 1  # Todavia en backoff
}

# ============= Obtener CPU de un proceso mpv =============
get_mpv_cpu() {
    local title="$1"
    local pid=$(pgrep -f "title=$title" | head -1)
    [ -z "$pid" ] && echo "0" && return
    local cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
    [ -z "$cpu" ] && echo "0" && return
    echo "$cpu"
}

# ============= Verificar si camara esta congelada (CPU) =============
check_camera_frozen() {
    local cam_num=$1
    local title="${CAM_TITLES[$cam_num]}"
    local cpu=$(get_mpv_cpu "$title")

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

# ============= Posicionar ventanas con xdotool =============
position_windows() {
    log "Posicionando ventanas..."
    sleep 2

    for w in $(DISPLAY=:0 xdotool search --name "CAM1-NVR" 2>/dev/null); do
        DISPLAY=:0 xdotool windowmove $w 0 0
        DISPLAY=:0 xdotool windowsize $w 640 540
    done
    for w in $(DISPLAY=:0 xdotool search --name "CAM2-NVR" 2>/dev/null); do
        DISPLAY=:0 xdotool windowmove $w 640 0
        DISPLAY=:0 xdotool windowsize $w 640 540
    done
    for w in $(DISPLAY=:0 xdotool search --name "CAM3-NVR" 2>/dev/null); do
        DISPLAY=:0 xdotool windowmove $w 1280 0
        DISPLAY=:0 xdotool windowsize $w 640 540
    done
    for w in $(DISPLAY=:0 xdotool search --name "CAM4-ICSEE" 2>/dev/null); do
        DISPLAY=:0 xdotool windowmove $w 0 540
        DISPLAY=:0 xdotool windowsize $w 640 540
    done
    for w in $(DISPLAY=:0 xdotool search --name "CAM6-LUGAR2" 2>/dev/null); do
        DISPLAY=:0 xdotool windowmove $w 640 540
        DISPLAY=:0 xdotool windowsize $w 640 540
    done
    for w in $(DISPLAY=:0 xdotool search --name "CAM5-LUGAR2" 2>/dev/null); do
        DISPLAY=:0 xdotool windowmove $w 1280 540
        DISPLAY=:0 xdotool windowsize $w 640 540
    done

    log "Ventanas posicionadas"
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
    # Force kill survivors (procesos stuck en I/O no mueren con SIGTERM)
    pkill -9 -f "title=$title" 2>/dev/null
    sleep 0.5

    log "Iniciando $title en ${x},${y}..."
    # Usar argumentos especiales para CAM4 (mayor resolucion/cache)
    local mpv_args="$MPV_ARGS"
    [ "$cam_num" -eq 4 ] && mpv_args="$MPV_ARGS_CAM4"

    DISPLAY=:0 mpv $mpv_args --geometry="${w}x${h}+${x}+${y}" --title="$title" "$url" &
    sleep 2

    # Actualizar timestamp de reinicio
    CAM_LAST_RESTART[$cam_num]=$(date +%s)

    # Resetear contador de CPU baja
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
    log "Deteniendo camaras..."
    pkill mpv 2>/dev/null
    sleep 2
    pkill -9 mpv 2>/dev/null
    sleep 1
}

start_all_cameras() {
    log "=== INICIANDO CAMARAS ==="

    # Primero iniciar camaras locales
    for cam_num in 1 2 3 4; do
        start_camera "$cam_num"
    done

    # Verificar VPN antes de iniciar camaras remotas
    if check_vpn_connectivity; then
        VPN_AVAILABLE=1
        log "VPN disponible - iniciando CAM5/CAM6"
        for cam_num in 5 6; do
            start_camera "$cam_num"
        done
    else
        VPN_AVAILABLE=0
        log "VPN no disponible - CAM5/CAM6 esperando conexion"
    fi

    log "Camaras locales iniciadas"
    position_windows
    sleep 3
    check_and_fix_positions
}

# ============= Reiniciar solo camaras VPN =============
restart_vpn_cameras() {
    log "=== REINICIANDO CAMARAS VPN ==="
    for cam_num in 5 6; do
        start_camera "$cam_num"
        sleep 2
        fix_window_position "$cam_num"
        CAM_FAIL_COUNT[$cam_num]=0  # Resetear contador de fallos
    done
    log "Camaras VPN reiniciadas"
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

    # Resetear contadores de fallos
    for i in 1 2 3 4 5 6; do
        CAM_FAIL_COUNT[$i]=0
    done
}

watchdog_loop() {
    log "=== WATCHDOG v3.4 ACTIVO ==="
    log "    - CPU check: <${CPU_THRESHOLD}% por ${FROZEN_CYCLES} ciclos = congelado"
    log "    - Network monitor: ping -c 3 $ROUTER_IP"
    log "    - VPN check: cada ${VPN_CHECK_INTERVAL}s cuando esta caida"
    log "    - Backoff: 1min(3+), 5min(6+), 15min(10+)"
    log "    - Reinicio general: cada $((PERIODIC_RESTART/3600))h"
    if [[ -n "$MAINTENANCE_START" && -n "$MAINTENANCE_END" ]]; then
        log "    - Mantenimiento: ventana configurada (CHECK 3-6 suprimidos)"
    else
        log "    - Mantenimiento: sin ventana configurada"
    fi
    log "    - Limpieza huerfanos: cada ciclo"

    LAST_PERIODIC_RESTART=$(date +%s)
    VPN_LAST_CHECK=$(date +%s)

    while true; do
        sleep "$WATCHDOG_INTERVAL"
        local now=$(date +%s)

        # ============= Limpiar procesos mpv huerfanos =============
        cleanup_orphan_mpv

        # ============= CHECK 0: Ventana de mantenimiento =============
        local in_maintenance=0
        if is_maintenance_window; then
            in_maintenance=1
        fi

        # ============= CHECK 1: Conectividad de red local =============
        if ! check_network; then
            if [ $NETWORK_WAS_DOWN -eq 0 ]; then
                log "RED LOCAL CAIDA - Esperando reconexion..."
                NETWORK_WAS_DOWN=1
            fi
            continue
        elif [ $NETWORK_WAS_DOWN -eq 1 ]; then
            log "RED LOCAL RESTAURADA - Reiniciando camaras..."
            NETWORK_WAS_DOWN=0
            sleep 5
            full_restart
            continue
        fi

        # ============= CHECK 2: Estado de VPN =============
        local vpn_check_elapsed=$((now - VPN_LAST_CHECK))
        if [ $vpn_check_elapsed -ge $VPN_CHECK_INTERVAL ]; then
            VPN_LAST_CHECK=$now

            if check_vpn_connectivity; then
                if [ $VPN_AVAILABLE -eq 0 ]; then
                    log "VPN RESTAURADA - Iniciando CAM5/CAM6"
                    VPN_AVAILABLE=1
                    restart_vpn_cameras
                fi
            else
                if [ $VPN_AVAILABLE -eq 1 ]; then
                    log "VPN CAIDA - CAM5/CAM6 en espera"
                    VPN_AVAILABLE=0
                    # Matar procesos de camaras VPN para liberar recursos
                    pkill -f "title=CAM5-LUGAR2" 2>/dev/null
                    pkill -f "title=CAM6-LUGAR2" 2>/dev/null
                else
                    # Loguear solo cada 5 minutos para no saturar
                    local log_elapsed=$((now - VPN_LAST_LOG))
                    if [ $log_elapsed -ge 300 ]; then
                        log "VPN sigue caida - esperando..."
                        VPN_LAST_LOG=$now
                    fi
                fi
            fi
        fi

        # ============= CHECK 3-6: Solo fuera de ventana de mantenimiento =============
        if [ $in_maintenance -eq 0 ]; then

            # ============= CHECK 3: Procesos caidos (camaras locales) =============
            for cam_num in 1 2 3 4; do
                if ! check_camera "$cam_num"; then
                    log "ALERTA: ${CAM_TITLES[$cam_num]} proceso caido"

                    if can_restart_camera "$cam_num"; then
                        start_camera "$cam_num"
                        sleep 2
                        if check_camera "$cam_num"; then
                            log "OK: ${CAM_TITLES[$cam_num]} recuperada"
                            fix_window_position "$cam_num"
                            CAM_FAIL_COUNT[$cam_num]=0
                        else
                            ((CAM_FAIL_COUNT[$cam_num]++))
                            local backoff=$(get_backoff_time $cam_num)
                            log "ERROR: ${CAM_TITLES[$cam_num]} no recuperada (fallos: ${CAM_FAIL_COUNT[$cam_num]}, backoff: ${backoff}s)"
                            ((FAILURE_COUNT++))
                        fi
                    else
                        local backoff=$(get_backoff_time $cam_num)
                        log "BACKOFF: ${CAM_TITLES[$cam_num]} esperando ${backoff}s"
                    fi
                fi
            done

            # ============= CHECK 4: Procesos caidos (camaras VPN) =============
            if [ $VPN_AVAILABLE -eq 1 ]; then
                for cam_num in 5 6; do
                    if ! check_camera "$cam_num"; then
                        log "ALERTA: ${CAM_TITLES[$cam_num]} proceso caido"

                        if can_restart_camera "$cam_num"; then
                            start_camera "$cam_num"
                            sleep 2
                            if check_camera "$cam_num"; then
                                log "OK: ${CAM_TITLES[$cam_num]} recuperada"
                                fix_window_position "$cam_num"
                                CAM_FAIL_COUNT[$cam_num]=0
                            else
                                ((CAM_FAIL_COUNT[$cam_num]++))
                                local backoff=$(get_backoff_time $cam_num)
                                log "ERROR: ${CAM_TITLES[$cam_num]} no recuperada (fallos: ${CAM_FAIL_COUNT[$cam_num]}, backoff: ${backoff}s)"
                            fi
                        else
                            local backoff=$(get_backoff_time $cam_num)
                            log "BACKOFF: ${CAM_TITLES[$cam_num]} esperando ${backoff}s"
                        fi
                    fi
                done
            fi

            # ============= CHECK 5: Streams congelados (CPU) - solo locales =============
            for cam_num in 1 2 3 4; do
                if check_camera "$cam_num" && check_camera_frozen "$cam_num"; then
                    log "CONGELADA (CPU): ${CAM_TITLES[$cam_num]}"
                    if can_restart_camera "$cam_num"; then
                        start_camera "$cam_num"
                        sleep 2
                        fix_window_position "$cam_num"
                    fi
                fi
            done

            # ============= CHECK 6: Streams congelados (CPU) - VPN si disponible =============
            if [ $VPN_AVAILABLE -eq 1 ]; then
                for cam_num in 5 6; do
                    if check_camera "$cam_num" && check_camera_frozen "$cam_num"; then
                        log "CONGELADA (CPU): ${CAM_TITLES[$cam_num]}"
                        if can_restart_camera "$cam_num"; then
                            start_camera "$cam_num"
                            sleep 2
                            fix_window_position "$cam_num"
                        fi
                    fi
                done
            fi

        else
            # En ventana de mantenimiento: resetear contadores para evitar falsos positivos
            for i in 1 2 3 4 5 6; do
                CAM_LOW_CPU_COUNT[$i]=0
            done
        fi

        # ============= CHECK 7: Reinicio periodico general (cada 4h) =============
        local since_periodic=$((now - LAST_PERIODIC_RESTART))
        if [ $since_periodic -ge $PERIODIC_RESTART ]; then
            log "REINICIO PERIODICO (cada $((PERIODIC_RESTART/3600))h)"
            full_restart
            continue
        fi

        check_and_fix_positions

        [ $FAILURE_COUNT -ge $MAX_FAILURES ] && full_restart

        # Estado resumido
        local active_local active_vpn
        active_local=$(pgrep -c -f "title=CAM[1-4]" 2>/dev/null) || active_local=0
        active_vpn=$(pgrep -c -f "title=CAM[56]" 2>/dev/null) || active_vpn=0
        local total=$((active_local + active_vpn))

        if [ $VPN_AVAILABLE -eq 1 ]; then
            [ "$total" -ne 6 ] && log "Estado: $total/6 activas (local:$active_local, vpn:$active_vpn)"
        else
            [ "$active_local" -ne 4 ] && log "Estado: $active_local/4 locales activas (VPN caida)"
        fi
    done
}

cleanup() {
    log "Terminando..."
    stop_all_cameras
    exit 0
}

trap cleanup SIGINT SIGTERM

# ============= INICIO =============
check_dependencies

log "========================================"
log "MATRIX CAMARAS v3.4"
log "========================================"

stop_all_cameras
start_all_cameras

active=$(pgrep -c mpv 2>/dev/null || echo 0)
log "Inicio: $active camaras activas"

watchdog_loop

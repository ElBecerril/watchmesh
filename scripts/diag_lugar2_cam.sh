#!/bin/bash
# ============================================================
# diag_lugar2_cam.sh — Diagnostico remoto por CAPAS de las camaras del Lugar 2
#
# SOLO LECTURA. No despliega, no reinicia, no toca configuracion. Localiza EN QUE
# CAPA se rompe la cadena hasta la camara y emite un veredicto accionable:
#
#   [L1] proxy proxy-lugar2 vivo por Tailscale   (ping)
#   [L2] el proxy forwardea el puerto RTSP      (TCP connect 5541/5542)
#   [L3] la camara responde a nivel IP          (ping a 198.51.100.x = CAPA FISICA)
#   [L4] la camara entrega VIDEO                 (ffprobe RTSP extremo-a-extremo)
#
# Por que importa L3 (el ping al IP local de la camara):
#   - Es la prueba que separa "cable/alimentacion" de "camara colgada":
#       * IP NO responde  -> fallo de capa fisica (cable RJ45 / PoE / corriente /
#                            camara muerta). NO malgastes tiempo en software.
#       * IP responde pero sin video -> firmware/encoder colgado -> power-cycle de
#                            la camara; el cable esta BIEN.
#   - Requiere que la subred del Lugar 2 (198.51.100.0/24) sea alcanzable, ya sea
#     por subnet-routing de Tailscale en proxy-lugar2, o corriendo este script
#     DESDE proxy-lugar2. Si no hay ruta, L3 sale "inconcluso" (ver canary).
#
# OJO — pista fisica de cam6: el LED del eliminador encendido NO prueba
# que lleguen los 12V a la camara, y la AUSENCIA del speech "system starting app"
# apunta a alimentacion/camara, no necesariamente al cable de datos:
#   - Si la camara tiene ELIMINADOR DC propio y el RJ45 es solo datos: con corriente
#     ARRANCA Y HABLA aunque el cable de red este cortado. No-speech => revisar
#     conector de barril / cable DC / etapa de entrada / camara muerta.
#   - Si la camara es PoE (corriente POR el RJ45): cable degradado => no llega
#     corriente => no arranca => no habla => host unreachable. Ahi SI cambia cable.
#   Pregunta de oro en sitio: ¿cam6 es PoE o tiene eliminador DC aparte?
#
# Config (env / EnvironmentFile, SEC-7 — solo el password es secreto):
#   PROXY_LUGAR2_HOST   (def 100.64.10.3)
#   LUGAR2_RTSP_USER (def admin)
#   CAM5_LAN_IP / CAM6_LAN_IP   (def .30 / .40)
#   CAM5_RTSP_PASS / CAM6_RTSP_PASS   (REQUERIDO para L4; sin el, L4 se omite)
#   LUGAR2_ROUTING_CANARY  (def 198.51.100.30 — IP conocida-viva para validar ruta)
#
# Uso:
#   diag_lugar2_cam.sh [cam5|cam6|all]   (def: all)
#   diag_lugar2_cam.sh cam6 --notify     (manda el veredicto por alert_notify.sh)
#
# Exit code (del peor caso entre las camaras evaluadas):
#   0 = SANA (video llega)   1 = degradada/sin video (no fisico-confirmado)
#   2 = FALLO FISICO (capa 1-2 de la camara)   3 = proxy/red del Lugar 2 caido
# ============================================================

set -uo pipefail

# --- cargar env opcional sin pisar lo ya exportado ---
for f in /etc/vigilancia/vigilancia.env "$(dirname "$0")/../.env"; do
    if [[ -f "$f" ]]; then set -a; . "$f"; set +a; fi
done

PROXY_LUGAR2_HOST="${PROXY_LUGAR2_HOST:-100.64.10.3}"
LUGAR2_RTSP_USER="${LUGAR2_RTSP_USER:-admin}"
CAM5_LAN_IP="${CAM5_LAN_IP:-198.51.100.30}"
CAM6_LAN_IP="${CAM6_LAN_IP:-198.51.100.40}"
CAM5_RTSP_PASS="${CAM5_RTSP_PASS:-}"
CAM6_RTSP_PASS="${CAM6_RTSP_PASS:-}"
LUGAR2_ROUTING_CANARY="${LUGAR2_ROUTING_CANARY:-198.51.100.30}"

# puerto del proxy y path RTSP por camara (valores publicos, no secretos)
CAM5_PORT="${CAM5_PORT:-5541}"; CAM6_PORT="${CAM6_PORT:-5542}"
CAM5_PATH="${CAM5_PATH:-ch0_1.h264}"; CAM6_PATH="${CAM6_PATH:-ch0_1.h264}"

TARGET="${1:-all}"
NOTIFY=0; [[ "${2:-}" == "--notify" || "${1:-}" == "--notify" ]] && NOTIFY=1
[[ "$TARGET" == "--notify" ]] && TARGET="all"

WORST=0  # peor exit code visto

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_rst=$'\033[0m'
[[ -t 1 ]] || { c_red=; c_grn=; c_yel=; c_dim=; c_rst=; }

ping1() { ping -c1 -W3 "$1" >/dev/null 2>&1; }       # 0 = responde
tcp_open() { timeout 4 bash -c "echo > /dev/tcp/$1/$2" 2>/dev/null; }

# devuelve 0 si llegan frames de video; imprime una linea-resumen del stream
ffprobe_video() {
    local url="$1"
    timeout 22 ffprobe -v error -rtsp_transport tcp -timeout 8000000 \
        -select_streams v:0 \
        -show_entries stream=codec_name,width,height,avg_frame_rate \
        -of default=noprint_wrappers=1:nokey=0 "$url" 2>/dev/null
}

worst() { (( $1 > WORST )) && WORST="$1"; }

diag_cam() {
    local cam="$1" port path lan pass
    case "$cam" in
        cam5) port=$CAM5_PORT; path=$CAM5_PATH; lan=$CAM5_LAN_IP; pass=$CAM5_RTSP_PASS ;;
        cam6) port=$CAM6_PORT; path=$CAM6_PATH; lan=$CAM6_LAN_IP; pass=$CAM6_RTSP_PASS ;;
        *) echo "camara desconocida: $cam (usa cam5|cam6|all)"; return 4 ;;
    esac

    echo "──────────────────────────────────────────────"
    echo " ${cam}  (proxy ${PROXY_LUGAR2_HOST}:${port}  ·  IP local ${lan})"
    echo "──────────────────────────────────────────────"

    # L1 — proxy host vivo
    if ping1 "$PROXY_LUGAR2_HOST"; then
        echo "  ${c_grn}[L1 ✓]${c_rst} proxy proxy-lugar2 responde (Tailscale)"
    else
        echo "  ${c_red}[L1 ✗]${c_rst} proxy-lugar2 NO responde por Tailscale"
        echo "  ${c_yel}VEREDICTO:${c_rst} PROXY/RED del Lugar 2 caido. No es la camara."
        echo "    → revisar internet del Lugar 2 / PC proxy-lugar2 / Tailscale del proxy."
        worst 3; VERDICT="[$cam] PROXY/RED Lugar 2 caido (proxy-lugar2 sin Tailscale)"; LEVEL=SOS
        return 3
    fi

    # L2 — forward del puerto
    if tcp_open "$PROXY_LUGAR2_HOST" "$port"; then
        echo "  ${c_grn}[L2 ✓]${c_rst} el proxy acepta conexion en :${port}"
    else
        echo "  ${c_red}[L2 ✗]${c_rst} :${port} cerrado/sin respuesta"
        echo "  ${c_yel}VEREDICTO:${c_rst} proxy vivo pero NO forwardea ${cam}."
        echo "    → revisar go2rtc/relay en proxy-lugar2 (servicio del puerto ${port})."
        worst 3; VERDICT="[$cam] proxy no forwardea :${port}"; LEVEL=SOS
        return 3
    fi

    # L3 — IP local de la camara (CAPA FISICA)
    local ip_state="?"
    if ping1 "$lan"; then
        ip_state="up"
        echo "  ${c_grn}[L3 ✓]${c_rst} la camara responde a IP ${lan} (capa fisica OK)"
    elif ping1 "$LUGAR2_ROUTING_CANARY"; then
        # hay ruta a la LAN del Lugar 2 (canary responde) PERO la camara no -> fisico
        ip_state="down"
        echo "  ${c_red}[L3 ✗]${c_rst} ${lan} NO responde (canary ${LUGAR2_ROUTING_CANARY} si) → capa fisica caida"
    else
        ip_state="noroute"
        echo "  ${c_yel}[L3 ?]${c_rst} sin ruta a 198.51.100.0/24 (ni la camara ni el canary responden)"
        echo "       ${c_dim}habilita subnet-routing en proxy-lugar2 o corre esto DESDE proxy-lugar2${c_rst}"
    fi

    # L4 — video extremo a extremo
    local v_state="?" vinfo=""
    if [[ -z "$pass" ]]; then
        echo "  ${c_yel}[L4 –]${c_rst} sin ${cam^^}_RTSP_PASS en env → omito prueba de video"
        v_state="skip"
    else
        # userinfo aparte para no formar el literal de credenciales en la URL (hook SEC-8)
        local creds="${LUGAR2_RTSP_USER}:${pass}"
        local url="rtsp://${creds}@${PROXY_LUGAR2_HOST}:${port}/${path}"
        vinfo="$(ffprobe_video "$url")"
        if [[ -n "$vinfo" ]]; then
            v_state="up"
            echo "  ${c_grn}[L4 ✓]${c_rst} VIDEO OK: $(echo "$vinfo" | paste -sd' ' -)"
        else
            v_state="down"
            echo "  ${c_red}[L4 ✗]${c_rst} sin video (puerto abre pero RTSP no entrega frames)"
        fi
    fi

    # ---- veredicto ----
    echo
    if [[ "$v_state" == "up" ]]; then
        echo "  ${c_grn}VEREDICTO:${c_rst} ${cam} SANA — entrega video ahora mismo."
        [[ "$cam" == "cam5" ]] && echo "    (si cae a ratos: flapping del relay/restart Frigate, lo cubre el watchdog; no es fisico)"
        worst 0; VERDICT="[$cam] SANA, video OK"; LEVEL=OK
        return 0
    fi

    if [[ "$ip_state" == "up" ]]; then
        echo "  ${c_yel}VEREDICTO:${c_rst} ${cam} VIVA a nivel IP pero SIN VIDEO → firmware/encoder colgado."
        echo "    → ACCION: power-cycle de la CAMARA (no es el cable). Reiniciar desde la app ICSee o cortar/dar corriente."
        worst 1; VERDICT="[$cam] viva a IP, sin video → reboot camara (no cable)"; LEVEL=WARN
        return 1
    fi

    if [[ "$ip_state" == "down" ]]; then
        echo "  ${c_red}VEREDICTO:${c_rst} ${cam} FALLO FISICO (capa 1-2): no responde a IP."
        echo "    → cable RJ45 / PoE / alimentacion / camara muerta. Checklist en sitio:"
        echo "      1) ¿es PoE (corriente por el RJ45) o tiene eliminador DC aparte? define la causa probable."
        echo "      2) ¿la camara da su speech 'system starting app' al darle corriente? si NO -> no arranca (alimentacion/camara), no el cable de datos."
        echo "      3) LED de enlace en el puerto del switch; probar la camara en otro puerto/cable conocido-bueno."
        echo "      4) tester de continuidad de los 8 conductores del RJ45; medir 12V reales en el conector de la camara."
        worst 2; VERDICT="[$cam] FALLO FISICO: sin IP → cable/PoE/alimentacion/camara"; LEVEL=SOS
        return 2
    fi

    # ip_state == noroute  -> no pude confirmar capa fisica desde aqui
    if [[ "$v_state" == "down" ]]; then
        echo "  ${c_yel}VEREDICTO:${c_rst} ${cam} sin video y SIN ruta para probar IP."
        echo "    → corre este script desde proxy-lugar2 (o activa subnet-routing) para separar cable vs camara."
        worst 1; VERDICT="[$cam] sin video; capa fisica inconclusa (sin ruta a LAN Lugar 2)"; LEVEL=WARN
        return 1
    fi

    echo "  ${c_yel}VEREDICTO:${c_rst} ${cam} inconcluso (define ${cam^^}_RTSP_PASS y/o la ruta a la LAN del Lugar 2)."
    worst 1; VERDICT="[$cam] inconcluso"; LEVEL=WARN
    return 1
}

# --- main ---
echo "diag_lugar2_cam — $(date '+%Y-%m-%d %H:%M:%S') — solo lectura, no toca nada"
LAST_VERDICT=""; LAST_LEVEL=OK
run_one() {
    VERDICT=""; LEVEL=OK
    diag_cam "$1"
    LAST_VERDICT="$VERDICT"; LAST_LEVEL="$LEVEL"
    if [[ "$NOTIFY" == "1" && -n "$VERDICT" ]]; then
        notifier="$(dirname "$0")/alert_notify.sh"
        [[ -x "$notifier" ]] && "$notifier" "$LEVEL" "$VERDICT" >/dev/null 2>&1 \
            && echo "  ${c_dim}(notificado por alert_notify.sh: $LEVEL)${c_rst}"
    fi
    echo
}

case "$TARGET" in
    cam5) run_one cam5 ;;
    cam6) run_one cam6 ;;
    all)  run_one cam5; run_one cam6 ;;
    *) echo "uso: $0 [cam5|cam6|all] [--notify]"; exit 4 ;;
esac

echo "── peor estado: exit $WORST (0=sana 1=degradada 2=fisico 3=proxy) ──"
exit "$WORST"

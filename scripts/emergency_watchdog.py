#!/usr/bin/env python3
"""
Emergency Watchdog - Detección de Fallos en Cascada 🆘

Corre en el HOST proxmox-lugar1 (NO en LXC 200) para sobrevivir al colapso.
Monitorea LXC 200, Frigate, Coral TPU, cámaras, RAM y disco.
Envía alertas escalonadas por Telegram antes del colapso total.

v2.0: Deteccion crash-loop por conteo de restarts (ffmpeg_pid changes).
       v1.5 solo detectaba 0fps+RTSP_unreachable, pero fallaba cuando:
       - cam4: RTSP responde TCP pero no entrega video (0fps+RTSP reachable)
       - cam5/cam6: ciclan tan rapido que el watchdog ve fps>0 entre checks
       Resultado: 41K restarts/dia en cam5+cam6 via Tailscale relay, 3K cam4.
       Esto causaba memory leak de Frigate 3x peor (~1GB/dia vs 300MB/dia).
       Fix: monitorea ffmpeg_pid de cada camara. Si PID cambia >RESTART_THRESHOLD
       veces en RESTART_WINDOW_SECS, desactiva camara via MQTT.
       Tambien: 0fps prolongado (ZERO_FPS_FORCE_DISABLE checks) desactiva
       aunque RTSP responda. cam6_remota agregada a CAMS_AUTO_DISABLE.

v1.5: Fix crash-loop-guard: usa MQTT (mosquitto_pub) en vez de API REST
       (endpoint /api/cam/detect/set no existe en Frigate 0.17).
       Ahora desactiva camara COMPLETA (no solo detect) para parar ffmpeg.
       v1.4 nunca logro desactivar camaras (5683 restarts cam4 en 3 dias).

v1.4: Auto-disable cámaras en crash loop (RTSP muerto pero ping OK).
       Desactiva detect en Frigate tras 2min a 0fps, prueba RTSP cada 5min,
       reactiva automáticamente cuando RTSP vuelve. Evita miles de reinicios
       inútiles de ffmpeg (cam4: 3334 restarts en 72h).

Lección v4.5: GenAI retry storm → CPU 100% → Frigate deadlock → 1h30m sin aviso.
Este watchdog habría alertado en ~2 minutos.
"""

import json
import logging
import os
import re
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime
from urllib.request import Request, urlopen
from urllib.error import URLError

# Self-watchdog: if main loop is stuck for >120s, force restart via SIGALRM
LOOP_TIMEOUT = 120  # seconds

# === CONFIGURACION ===
LXC_ID = "200"
FRIGATE_URL = "http://192.0.2.20:5000"
FRIGATE_USER = "admin"
FRIGATE_PASS = os.environ.get("FRIGATE_PASS", "SET_FRIGATE_PASS_IN_ENV")

TELEGRAM_TOKEN = os.environ.get("TELEGRAM_TOKEN", "SET_TELEGRAM_TOKEN_IN_ENV")
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "SET_TELEGRAM_CHAT_ID_IN_ENV")

# RES-8: canal de respaldo ntfy (CT201). Si Telegram cae, la alerta igual llega.
# Vacio = off. Config en el mismo EnvironmentFile que ya usa alert_notify.sh.
NTFY_URL = os.environ.get("NTFY_URL", "")
NTFY_TOKEN = os.environ.get("NTFY_TOKEN", "")

CHECK_INTERVAL = 30  # segundos entre checks
ALERT_COOLDOWN = 300  # 5 min entre alertas
SOS_COOLDOWN = 600  # 10 min entre SOS

# Umbrales
CPU_WARN = 80
CPU_SOS = 90
RAM_WARN = 85
RAM_SOS = 93
DISK_WARN = 90
DISK_SOS = 95
CAMS_WARN = 2  # cámaras a 0fps para warning
CAMS_SOS = 4   # cámaras a 0fps para SOS
CAMS_IGNORE = {"cam6_face"}  # desactivada (face-bridge off, rostros demasiado pequenos)

# Auto-disable: camaras que pueden entrar en crash loop
# Mapa: frigate_cam_name -> RTSP source URL para health check
CAMS_AUTO_DISABLE = {
    "cam4_icsee": {
        "rtsp_host": "192.0.2.30",
        "rtsp_port": 554,
    },
    "cam5_remota": {
        "rtsp_host": "100.64.10.3",
        "rtsp_port": 5541,
    },
    "cam6_remota": {
        "rtsp_host": "100.64.10.3",
        "rtsp_port": 5542,
    },
}

# Camaras donde el watchdog NUNCA debe re-habilitar automaticamente.
# Util cuando la causa raiz es hardware (cable danado, camara muerta) y el ciclo
# OFF/ON automatico solo genera ruido. Para reactivar: quitar de este set y
# reiniciar el servicio (systemctl restart emergency-watchdog).
CAMS_NO_AUTO_RECOVERY = set()  # cam6 recableada y verificada por el operador (enlace OK, 3fps) -> vuelve a auto-recovery normal. Revertir si el enlace falla.

CAM_DISABLE_AFTER = 4       # checks a 0fps antes de desactivar (4 x 30s = 2 min)
CAM_RTSP_CHECK_INTERVAL = 10  # checks entre pruebas RTSP mientras desactivada (10 x 30s = 5 min)

# Crash-loop por conteo de restarts (ffmpeg_pid changes)
RESTART_WINDOW_SECS = 300   # ventana de 5 minutos
RESTART_THRESHOLD = 15      # >15 restarts en 5 min = crash loop
ZERO_FPS_FORCE_DISABLE = 12 # 12 checks (6 min) a 0fps -> desactivar aunque RTSP responda

# TPU umbrales
TPU_LATENCY_WARN = 100   # ms - inferencia degradada
TPU_LATENCY_SOS = 200    # ms - inferencia critica
TPU_RESETS_WARN = 5      # resets en ventana de tiempo
TPU_RESETS_SOS = 10      # resets en ventana de tiempo
TPU_RESET_WINDOW = 3600  # ventana de 1 hora para contar resets
TPU_USB_DEVICE = "1-2.1" # bus-port del Coral

# Fallos consecutivos requeridos (anti-falso-positivo)
CONSEC_WARN = 4   # 4 checks = 2 min
CONSEC_SOS = 8    # 8 checks = 4 min
CONSEC_API = 3    # 3 fallos API = ~1.5 min

LOG_FILE = "/var/log/emergency_watchdog.log"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_FILE, mode="a"),
    ],
)
log = logging.getLogger(__name__)

# Estado de fallos consecutivos
fail_counts = {
    "cpu": 0,
    "ram": 0,
    "disk": 0,
    "api": 0,
    "cameras": 0,
    "coral": 0,
    "tpu_usb": 0,
    "docker": 0,
}

# Historial de latencia TPU POR-DETECTOR para detectar degradación progresiva.
# dict: detector_name -> [latencias]. Antes era una lista global compartida, lo
# que mezclaba detectores y se borraba entera ante un solo sample a 0 (BUG-7).
tpu_latency_history = {}
TPU_HISTORY_SIZE = 20  # últimos 20 checks (~10 min) por detector

# RES-7: restart preventivo de Frigate si su RSS supera el umbral (memory leak ~1GB/dia)
FRIGATE_MEM_RESTART_GB = 9.5      # LXC tiene 12GB; reiniciar antes de agotar swap
FRIGATE_MEM_RESTART_COOLDOWN = 3600  # minimo 1h entre restarts automaticos

last_alert_time = 0
last_sos_time = 0
last_frigate_mem_restart = 0

# Estado de camaras auto-desactivadas por crash loop
# cam_name -> {"disabled": bool, "zero_fps_count": int, "checks_since_disable": int}
cam_auto_state = {
    cam: {"disabled": cam in CAMS_NO_AUTO_RECOVERY, "zero_fps_count": 0, "checks_since_disable": 0}
    for cam in CAMS_AUTO_DISABLE
}

# Tracking de restarts por cambio de ffmpeg_pid
# cam_name -> {"last_ffmpeg_pid": int|None, "restart_times": [float]}
cam_restart_tracking = {}


def pct_exec(cmd):
    """Ejecuta comando en LXC via pct exec. Retorna stdout o None."""
    try:
        result = subprocess.run(
            ["pct", "exec", LXC_ID, "--", "bash", "-c", cmd],
            capture_output=True, text=True, timeout=10,
            start_new_session=True,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, OSError) as e:
        log.debug(f"pct_exec failed: {e}")
    return None


def check_cpu():
    """Check CPU load del LXC 200. Retorna (ok, detalle, nivel)."""
    out = pct_exec("cat /proc/loadavg")
    if out is None:
        return False, "LXC 200 no responde", "WARN"
    try:
        load_1min = float(out.split()[0])
        # N95 tiene 4 cores, load > 3.2 (80%) es alto
        cpu_pct = (load_1min / 4) * 100
        if cpu_pct > CPU_SOS:
            return False, f"CPU {cpu_pct:.0f}% (load {load_1min:.1f})", "SOS"
        if cpu_pct > CPU_WARN:
            return False, f"CPU {cpu_pct:.0f}% (load {load_1min:.1f})", "WARN"
        return True, f"CPU {cpu_pct:.0f}%", "OK"
    except (ValueError, IndexError):
        return False, "CPU parse error", "WARN"


def check_ram():
    """Check RAM del LXC 200. Retorna (ok, detalle, nivel)."""
    out = pct_exec("free -m | grep Mem")
    if out is None:
        return False, "LXC 200 no responde", "WARN"
    try:
        parts = out.split()
        total = int(parts[1])
        available = int(parts[6])
        used_pct = ((total - available) / total) * 100
        if used_pct > RAM_SOS:
            return False, f"RAM {used_pct:.0f}% ({available}MB libre)", "SOS"
        if used_pct > RAM_WARN:
            return False, f"RAM {used_pct:.0f}% ({available}MB libre)", "WARN"
        return True, f"RAM {used_pct:.0f}%", "OK"
    except (ValueError, IndexError):
        return False, "RAM parse error", "WARN"


def check_disk():
    """Check disco del LXC 200. Retorna (ok, detalle, nivel)."""
    out = pct_exec("df / --output=pcent | tail -1")
    if out is None:
        return False, "LXC 200 no responde", "WARN"
    try:
        pct = int(out.strip().replace("%", ""))
        if pct > DISK_SOS:
            return False, f"Disco {pct}%", "SOS"
        if pct > DISK_WARN:
            return False, f"Disco {pct}%", "WARN"
        return True, f"Disco {pct}%", "OK"
    except ValueError:
        return False, "Disco parse error", "WARN"


def check_frigate_api():
    """Check Frigate API. Retorna (ok, detalle, stats)."""
    try:
        import base64
        auth = base64.b64encode(f"{FRIGATE_USER}:{FRIGATE_PASS}".encode()).decode()
        req = Request(f"{FRIGATE_URL}/api/stats", headers={"Authorization": f"Basic {auth}"})
        with urlopen(req, timeout=5) as r:
            stats = json.loads(r.read())
        return True, "API OK", stats
    except Exception as e:
        return False, f"API no responde: {type(e).__name__}", None


def check_cameras(stats):
    """Check cámaras activas via stats de Frigate. Retorna (ok, detalle, nivel)."""
    if stats is None:
        return False, "Sin stats (API caída)", "WARN"
    cameras = stats.get("cameras", {})
    # Include auto-disabled cameras in ignore set
    ignore = CAMS_IGNORE | {c for c, s in cam_auto_state.items() if s["disabled"]}
    dead = []
    for cam, data in cameras.items():
        if cam in ignore:
            continue
        fps = data.get("camera_fps", 0)
        if fps == 0:
            dead.append(cam)
    if len(dead) >= CAMS_SOS:
        return False, f"{len(dead)} camaras muertas: {', '.join(dead)}", "SOS"
    if len(dead) >= CAMS_WARN:
        return False, f"{len(dead)} camaras a 0fps: {', '.join(dead)}", "WARN"
    return True, f"{len(cameras)} camaras activas", "OK"


def check_coral(stats):
    """Check Coral TPU via stats de Frigate con detección preventiva.
    Monitorea TODOS los detectores (BUG-3): inference muerta, latencia degradada,
    tendencia al alza. Devuelve el peor estado entre todos. (ok, detalle, nivel)."""
    if stats is None:
        return False, "Sin stats (API caida)", "WARN"
    detectors = stats.get("detectors", {})
    if not detectors:
        return False, "Sin detectores configurados", "WARN"

    # Rank de severidad: 3=muerta/critico (SOS), 2=degradada (WARN), 1=tendencia (WARN), 0=ok
    worst_rank = 0
    worst_detail = None
    ok_details = []

    for name, data in detectors.items():
        inf_speed = data.get("inference_speed", 0)
        rank = 0
        detail = None

        if inf_speed == 0:
            # Historial POR-DETECTOR: solo se borra el del detector muerto (BUG-7)
            tpu_latency_history.pop(name, None)
            rank, detail = 3, f"TPU {name}: 0ms (MUERTA)"
        else:
            hist = tpu_latency_history.setdefault(name, [])
            hist.append(inf_speed)
            if len(hist) > TPU_HISTORY_SIZE:
                hist.pop(0)

            if inf_speed > TPU_LATENCY_SOS:
                rank, detail = 3, f"TPU {name}: {inf_speed:.0f}ms (CRITICO, normal ~25ms)"
            elif inf_speed > TPU_LATENCY_WARN:
                rank, detail = 2, f"TPU {name}: {inf_speed:.0f}ms (degradada, normal ~25ms)"
            elif len(hist) >= 10:
                recent = hist[-5:]
                older = hist[:-5]
                avg_recent = sum(recent) / len(recent)
                avg_older = sum(older) / len(older)
                if avg_older > 0 and avg_recent > avg_older * 2.5 and avg_recent > 50:
                    rank, detail = 1, f"TPU {name}: {inf_speed:.0f}ms (tendencia al alza, avg {avg_recent:.0f} vs {avg_older:.0f}ms)"

        if rank > 0:
            if rank > worst_rank:
                worst_rank, worst_detail = rank, detail
        else:
            ok_details.append(f"{name}:{inf_speed:.0f}ms")

    if worst_rank >= 3:
        return False, worst_detail, "SOS"
    if worst_rank > 0:
        return False, worst_detail, "WARN"
    return True, "TPU OK (" + ", ".join(ok_details) + ")", "OK"


def check_tpu_usb():
    """Check USB resets del Coral desde dmesg del HOST (preventivo).
    Detecta aceleración de resets que precede a un fallo total."""
    # LANG=C/LC_ALL=C: forzar nombres de mes/dia en ingles para que strptime
    # (%a %b ...) parsee el timestamp aunque el host tenga locale no-ingles (BUG-9).
    dmesg_env = {**os.environ, "LANG": "C", "LC_ALL": "C"}
    try:
        result = subprocess.run(
            ["dmesg", "-T", "--since", "-1h"],
            capture_output=True, text=True, timeout=5,
            start_new_session=True, env=dmesg_env,
        )
        if result.returncode != 0:
            # Fallback: dmesg without --since (older kernels)
            result = subprocess.run(
                ["dmesg", "-T"],
                capture_output=True, text=True, timeout=5,
                start_new_session=True, env=dmesg_env,
            )
            if result.returncode != 0:
                return True, "dmesg no disponible", "OK"

        now = time.time()
        recent_resets = 0
        last_reset_time = None
        has_errors = False

        for line in result.stdout.splitlines():
            if f"usb {TPU_USB_DEVICE}: reset" not in line and f"usb {TPU_USB_DEVICE}: device descriptor" not in line:
                continue

            # Parsear timestamp de dmesg -T: [Day Mon DD HH:MM:SS YYYY]
            try:
                ts_str = line.split("]")[0].strip("[").strip()
                ts = datetime.strptime(ts_str, "%a %b %d %H:%M:%S %Y")
                ts_epoch = ts.timestamp()
            except (ValueError, IndexError):
                continue

            # Contar resets en la ventana
            if now - ts_epoch < TPU_RESET_WINDOW:
                if "reset" in line:
                    recent_resets += 1
                    last_reset_time = ts_str
                if "error" in line.lower():
                    has_errors = True

        # Evaluar
        if recent_resets >= TPU_RESETS_SOS or (recent_resets >= TPU_RESETS_WARN and has_errors):
            return False, f"TPU USB: {recent_resets} resets/h (CRITICO, ultimo: {last_reset_time})", "SOS"
        if recent_resets >= TPU_RESETS_WARN:
            return False, f"TPU USB: {recent_resets} resets/h (degradando, ultimo: {last_reset_time})", "WARN"

        detail = f"TPU USB: {recent_resets} resets/h"
        if recent_resets > 0:
            detail += f" (ultimo: {last_reset_time})"
        return True, detail, "OK"

    except (subprocess.TimeoutExpired, OSError) as e:
        return True, f"TPU USB check skip: {e}", "OK"


def mqtt_publish(topic, message):
    """Publica mensaje MQTT via mosquitto_pub en LXC 200."""
    try:
        result = subprocess.run(
            ["pct", "exec", LXC_ID, "--", "mosquitto_pub", "-h", "localhost", "-t", topic, "-m", message],
            capture_output=True, text=True, timeout=10,
            start_new_session=True,
        )
        if result.returncode == 0:
            return True
        log.debug(f"mosquitto_pub failed: {result.stderr}")
    except (subprocess.TimeoutExpired, OSError) as e:
        log.debug(f"mqtt_publish failed: {e}")
    return False


def set_camera_detect(cam_name, enabled):
    """Activa o desactiva detect de una camara via MQTT."""
    state = "ON" if enabled else "OFF"
    if mqtt_publish(f"frigate/{cam_name}/detect/set", state):
        log.info(f"Camera {cam_name} detect set to {state}")
        return True
    log.error(f"Failed to set {cam_name} detect to {state}")
    return False


def set_camera_enabled(cam_name, enabled):
    """Activa o desactiva una camara completa via MQTT (ffmpeg + detect + record)."""
    state = "ON" if enabled else "OFF"
    if mqtt_publish(f"frigate/{cam_name}/set", state):
        log.info(f"Camera {cam_name} set to {state}")
        return True
    log.error(f"Failed to set {cam_name} to {state}")
    return False


def test_rtsp_reachable(host, port, timeout=3):
    """Prueba si un host:port RTSP es alcanzable (TCP connect)."""
    import socket
    try:
        sock = socket.create_connection((host, port), timeout=timeout)
        sock.close()
        return True
    except (socket.timeout, ConnectionRefusedError, OSError):
        return False


def _disable_camera(cam_name, reason, detail):
    """Desactiva una camara y envia alerta Telegram."""
    cfg = CAMS_AUTO_DISABLE[cam_name]
    state = cam_auto_state[cam_name]
    if set_camera_enabled(cam_name, False):
        state["disabled"] = True
        state["checks_since_disable"] = 0
        state["zero_fps_count"] = 0
        log.warning(f"CRASH-LOOP: {cam_name} DISABLED - {reason}")
        send_telegram(
            f"\u26a0\ufe0f <b>{cam_name} AUTO-DESACTIVADA</b>\n\n"
            f"<b>Razon:</b> {reason}\n"
            f"{detail}\n"
            f"Se reactivara automaticamente cuando RTSP vuelva.\n"
            f"Hora: {datetime.now().strftime('%H:%M:%S')}"
        )


def _track_ffmpeg_restarts(cam_name, ffmpeg_pid):
    """Trackea cambios de ffmpeg_pid. Retorna cantidad de restarts en ventana."""
    now = time.time()
    if cam_name not in cam_restart_tracking:
        cam_restart_tracking[cam_name] = {"last_ffmpeg_pid": None, "restart_times": []}

    track = cam_restart_tracking[cam_name]

    # Detectar cambio de PID (restart)
    if track["last_ffmpeg_pid"] is not None and ffmpeg_pid != track["last_ffmpeg_pid"] and ffmpeg_pid != 0:
        track["restart_times"].append(now)

    track["last_ffmpeg_pid"] = ffmpeg_pid

    # Limpiar restarts fuera de la ventana
    cutoff = now - RESTART_WINDOW_SECS
    track["restart_times"] = [t for t in track["restart_times"] if t > cutoff]

    return len(track["restart_times"])


def manage_cam_crash_loops(stats):
    """Gestiona auto-disable/re-enable de camaras en crash loop.

    Deteccion por 3 vias:
    1. ffmpeg_pid changes: si PID cambia >RESTART_THRESHOLD veces en 5min
    2. 0fps + RTSP unreachable: desactiva tras CAM_DISABLE_AFTER checks (2 min)
    3. 0fps + RTSP reachable prolongado: desactiva tras ZERO_FPS_FORCE_DISABLE checks (6 min)

    Re-enable: prueba RTSP cada 5min, reactiva si responde.
    """
    if stats is None:
        return

    cameras = stats.get("cameras", {})

    for cam_name, cfg in CAMS_AUTO_DISABLE.items():
        state = cam_auto_state[cam_name]
        cam_stats = cameras.get(cam_name, {})
        fps = cam_stats.get("camera_fps", 0)
        ffmpeg_pid = cam_stats.get("ffmpeg_pid", 0)

        if state["disabled"]:
            # Skip auto-recovery si esta en CAMS_NO_AUTO_RECOVERY (causa raiz fisica no resuelta)
            if cam_name in CAMS_NO_AUTO_RECOVERY:
                continue
            # Camara esta desactivada, probar RTSP periodicamente
            state["checks_since_disable"] += 1
            if state["checks_since_disable"] % CAM_RTSP_CHECK_INTERVAL == 0:
                rtsp_ok = test_rtsp_reachable(cfg["rtsp_host"], cfg["rtsp_port"])
                if rtsp_ok:
                    log.info(f"CRASH-LOOP: {cam_name} RTSP back! Re-enabling camera")
                    if set_camera_enabled(cam_name, True):
                        state["disabled"] = False
                        state["zero_fps_count"] = 0
                        state["checks_since_disable"] = 0
                        # Reset restart tracking para dar oportunidad limpia
                        if cam_name in cam_restart_tracking:
                            cam_restart_tracking[cam_name]["restart_times"] = []
                            cam_restart_tracking[cam_name]["last_ffmpeg_pid"] = None
                        send_telegram(
                            f"\u2705 <b>{cam_name} REACTIVADA</b>\n\n"
                            f"RTSP recuperado ({cfg['rtsp_host']}:{cfg['rtsp_port']}). "
                            f"Camara re-habilitada.\n"
                            f"Hora: {datetime.now().strftime('%H:%M:%S')}"
                        )
                else:
                    mins = (state["checks_since_disable"] * CHECK_INTERVAL) // 60
                    log.info(f"CRASH-LOOP: {cam_name} RTSP still down ({mins}min)")
        else:
            # === VIA 1: Deteccion por conteo de restarts (ffmpeg_pid changes) ===
            restart_count = _track_ffmpeg_restarts(cam_name, ffmpeg_pid)
            if restart_count >= RESTART_THRESHOLD:
                _disable_camera(
                    cam_name,
                    f"{restart_count} ffmpeg restarts en {RESTART_WINDOW_SECS // 60}min",
                    f"Crash loop detectado por cambio de PID.\n"
                    f"({cfg['rtsp_host']}:{cfg['rtsp_port']})"
                )
                continue

            # === VIA 2 y 3: Deteccion por 0fps ===
            if fps == 0:
                state["zero_fps_count"] += 1
                if state["zero_fps_count"] >= CAM_DISABLE_AFTER:
                    rtsp_ok = test_rtsp_reachable(cfg["rtsp_host"], cfg["rtsp_port"])
                    if not rtsp_ok:
                        # VIA 2: 0fps + RTSP unreachable (original)
                        _disable_camera(
                            cam_name,
                            f"0fps x{state['zero_fps_count']} checks, RTSP unreachable",
                            f"({cfg['rtsp_host']}:{cfg['rtsp_port']})"
                        )
                    elif state["zero_fps_count"] >= ZERO_FPS_FORCE_DISABLE:
                        # VIA 3: 0fps prolongado aunque RTSP responda TCP
                        mins = (state["zero_fps_count"] * CHECK_INTERVAL) // 60
                        _disable_camera(
                            cam_name,
                            f"0fps x{state['zero_fps_count']} checks ({mins}min), RTSP responde pero sin video",
                            f"({cfg['rtsp_host']}:{cfg['rtsp_port']})"
                        )
                    else:
                        log.info(f"CRASH-LOOP: {cam_name} 0fps but RTSP reachable ({state['zero_fps_count']}/{ZERO_FPS_FORCE_DISABLE} checks)")
            else:
                state["zero_fps_count"] = 0


def _get_frigate_mem_gb():
    """RSS del contenedor frigate en GB (via docker stats), o None."""
    out = pct_exec("docker stats frigate --no-stream --format '{{.MemUsage}}'")
    if not out:
        return None
    # formato tipico: "5.483GiB / 12GiB"
    try:
        used = out.split("/")[0].strip()
        is_mib = "MiB" in used
        num = float(used.replace("GiB", "").replace("MiB", "").replace("KiB", "").strip())
        if is_mib:
            num /= 1024.0
        return num
    except (ValueError, IndexError):
        return None


def manage_frigate_memory():
    """RES-7: restart preventivo de Frigate si su RSS supera el umbral.
    El leak de Frigate 0.17 crece ~1GB/dia; el restart semanal por cron puede
    llegar tarde. Reinicia el contenedor antes de agotar swap, con cooldown."""
    global last_frigate_mem_restart
    mem_gb = _get_frigate_mem_gb()
    if mem_gb is None or mem_gb < FRIGATE_MEM_RESTART_GB:
        return
    now = time.time()
    if now - last_frigate_mem_restart < FRIGATE_MEM_RESTART_COOLDOWN:
        log.warning(f"Frigate RSS {mem_gb:.1f}GB > umbral pero en cooldown de restart")
        return
    log.warning(f"Frigate RSS {mem_gb:.1f}GB supera {FRIGATE_MEM_RESTART_GB}GB, reiniciando (memory leak)")
    pct_exec("docker restart frigate")
    last_frigate_mem_restart = now
    send_telegram(
        f"♻️ <b>Frigate reiniciado por RAM</b>\n\n"
        f"RSS {mem_gb:.1f}GB > umbral {FRIGATE_MEM_RESTART_GB}GB.\n"
        f"Restart preventivo (memory leak conocido).\n"
        f"Hora: {datetime.now().strftime('%H:%M:%S')}"
    )


def check_docker():
    """Check Docker container frigate health. Retorna (ok, detalle, nivel)."""
    out = pct_exec("docker inspect frigate --format '{{.State.Health.Status}}' 2>/dev/null || docker inspect frigate --format '{{.State.Status}}' 2>/dev/null")
    if out is None:
        return False, "Docker no responde", "SOS"
    if "healthy" in out or "running" in out:
        return True, f"Docker: {out}", "OK"
    return False, f"Docker: {out}", "SOS"


_HTML_TAG_RE = re.compile(r"<[^>]+>")

# Mapeo nivel -> (prioridad ntfy, tag/emoji), alineado con alert_notify.sh
_NTFY_LEVEL = {
    "OK":    ("default", "white_check_mark"),
    "WARN":  ("high",    "warning"),
    "ALERT": ("high",    "warning"),
    "SOS":   ("urgent",  "rotating_light"),
}


def send_ntfy(text, level="WARN"):
    """Envía la misma alerta por ntfy (RES-8, canal de respaldo). No-op si NTFY_URL vacío."""
    if not NTFY_URL:
        return False
    prio, tag = _NTFY_LEVEL.get(level, _NTFY_LEVEL["WARN"])
    body = _HTML_TAG_RE.sub("", text)  # ntfy es texto plano: quitar <b>, </b>, etc.
    headers = {
        "Title": f"Vigilancia [{level}] watchdog",
        "Priority": prio,
        "Tags": tag,
    }
    if NTFY_TOKEN:
        headers["Authorization"] = f"Bearer {NTFY_TOKEN}"
    try:
        req = Request(NTFY_URL, data=body.encode(), headers=headers)
        with urlopen(req, timeout=10):
            pass
        log.info("ntfy message sent")
        return True
    except Exception as e:
        log.error(f"ntfy failed: {e}")
        return False


def send_telegram(text, level="WARN"):
    """Envía la alerta por DOS canales independientes (RES-8): ntfy + Telegram.

    El nombre se conserva por compatibilidad con los call sites existentes.
    ntfy se dispara primero (canal de respaldo) para que la alerta llegue
    aunque Telegram o su token estén caídos.
    """
    send_ntfy(text, level)
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"
    data = json.dumps({
        "chat_id": TELEGRAM_CHAT_ID,
        "text": text,
        "parse_mode": "HTML",
    }).encode()
    try:
        req = Request(url, data=data, headers={"Content-Type": "application/json"})
        with urlopen(req, timeout=10):
            pass
        log.info("Telegram message sent")
        return True
    except Exception as e:
        log.error(f"Telegram failed: {e}")
        return False


def run_checks():
    """Ejecuta todos los checks y retorna resultados."""
    results = {}

    # Checks que no dependen de la API
    results["cpu"] = check_cpu()
    results["ram"] = check_ram()
    results["disk"] = check_disk()
    results["docker"] = check_docker()

    # Check TPU USB desde HOST (no depende de API ni LXC)
    results["tpu_usb"] = check_tpu_usb()

    # Check API + checks dependientes
    api_ok, api_detail, stats = check_frigate_api()
    results["api"] = (api_ok, api_detail, "OK" if api_ok else "SOS")

    if stats:
        results["cameras"] = check_cameras(stats)
        results["coral"] = check_coral(stats)
        # Auto-disable camaras en crash loop (RTSP muerto)
        manage_cam_crash_loops(stats)
        # RES-7: restart preventivo de Frigate por memory leak
        manage_frigate_memory()
    else:
        results["cameras"] = (False, "Sin datos (API caida)", "WARN")
        results["coral"] = (False, "Sin datos (API caida)", "WARN")

    return results


def update_fail_counts(results):
    """Actualiza contadores de fallos consecutivos."""
    for key, res in results.items():
        if not res[0]:
            fail_counts[key] += 1
        else:
            fail_counts[key] = 0


def assess_severity(results):
    """Evalúa severidad usando el NIVEL explícito de cada check (OK/WARN/SOS),
    sin re-parsear floats desde strings de UI (BUG-8).

    - active_failures: checks fallidos sostenidos >= CONSEC_WARN.
    - critical_sustained: un check critico en nivel SOS sostenido el tiempo
      requerido. Solo CRITICAL_KEYS escalan por si mismos (preserva el
      comportamiento previo: cpu/ram/coral via CONSEC_SOS, api via CONSEC_API,
      tpu_usb via CONSEC_WARN; disco/docker/camaras solo cuentan para el conteo).
    """
    CRITICAL_KEYS = {"cpu", "ram", "api", "coral", "tpu_usb"}

    active_failures = []
    critical_sustained = False

    for key, res in results.items():
        ok, detail = res[0], res[1]
        level = res[2] if len(res) > 2 else ("SOS" if not ok else "OK")

        if not ok and fail_counts[key] >= CONSEC_WARN:
            active_failures.append((key, detail, fail_counts[key]))

        if not ok and level == "SOS" and key in CRITICAL_KEYS:
            if key == "api":
                threshold = CONSEC_API
            elif key == "tpu_usb":
                threshold = CONSEC_WARN
            else:
                threshold = CONSEC_SOS
            if fail_counts[key] >= threshold:
                critical_sustained = True

    if critical_sustained or len(active_failures) >= 3:
        return "SOS", active_failures
    elif len(active_failures) >= 2:
        return "ALERT", active_failures
    elif len(active_failures) >= 1:
        return "WARNING", active_failures
    return "OK", []


def format_alert(severity, failures, results):
    """Formatea mensaje de alerta."""
    now = datetime.now().strftime("%H:%M:%S")

    if severity == "SOS":
        lines = [
            "\U0001f198 <b>EMERGENCIA SISTEMA VIGILANCIA</b>",
            "",
            "<b>MULTIPLES FALLOS DETECTADOS:</b>",
        ]
        for key, detail, count in failures:
            mins = (count * CHECK_INTERVAL) // 60
            lines.append(f"\u2022 {detail} (hace {mins}min)")

        lines.append("")
        lines.append("\u26a1 <b>Accion sugerida:</b> reiniciar LXC 200")
        lines.append("<code>ssh root@100.64.10.2</code>")
        lines.append("<code>pct restart 200</code>")
        lines.append(f"\nHora: {now}")

    elif severity == "ALERT":
        lines = [
            "\u26a0\ufe0f <b>ALERTA SISTEMA VIGILANCIA</b>",
            "",
            "Problemas detectados:",
        ]
        for key, detail, count in failures:
            mins = (count * CHECK_INTERVAL) // 60
            lines.append(f"\u2022 {detail} (hace {mins}min)")

        # Mostrar checks OK
        ok_checks = [k for k, res in results.items() if res[0]]
        if ok_checks:
            lines.append(f"\nOtros checks OK: {', '.join(ok_checks)}")
        lines.append(f"Hora: {now}")

    return "\n".join(lines)


def format_recovery(prev_failures):
    """Formatea mensaje de recuperación."""
    now = datetime.now().strftime("%H:%M:%S")
    recovered = [key for key, _, _ in prev_failures]
    return (
        "\u2705 <b>SISTEMA RECUPERADO</b>\n\n"
        f"Checks recuperados: {', '.join(recovered)}\n"
        f"Hora: {now}"
    )


def _loop_watchdog_reset():
    """Reset the self-watchdog timer. Call at start of each loop iteration."""
    if hasattr(signal, 'alarm'):
        signal.alarm(LOOP_TIMEOUT)


def _loop_watchdog_handler(signum, frame):
    """Handle SIGALRM: main loop is stuck, log and force restart."""
    log.error(f"SELF-WATCHDOG: Main loop stuck for >{LOOP_TIMEOUT}s! Forcing restart via exit.")
    logging.shutdown()  # flush de handlers para no perder el mensaje en disco (BUG-15)
    os._exit(1)  # systemd will restart us


def main():
    global last_alert_time, last_sos_time

    # Install self-watchdog (SIGALRM)
    if hasattr(signal, 'alarm'):
        signal.signal(signal.SIGALRM, _loop_watchdog_handler)
        log.info(f"Self-watchdog installed (SIGALRM, {LOOP_TIMEOUT}s timeout)")

    log.info("=" * 60)
    log.info("Emergency Watchdog v2.0 starting (restart-count crash-loop + MQTT + self-watchdog + TPU)")
    log.info(f"  LXC: {LXC_ID}")
    log.info(f"  Frigate: {FRIGATE_URL}")
    log.info(f"  Check interval: {CHECK_INTERVAL}s")
    log.info(f"  Alert cooldown: {ALERT_COOLDOWN}s")
    log.info(f"  SOS cooldown: {SOS_COOLDOWN}s")
    log.info(f"  TPU USB device: {TPU_USB_DEVICE}")
    log.info(f"  TPU latency warn/sos: {TPU_LATENCY_WARN}/{TPU_LATENCY_SOS}ms")
    log.info(f"  TPU resets warn/sos: {TPU_RESETS_WARN}/{TPU_RESETS_SOS} per hour")
    log.info(f"  Loop timeout: {LOOP_TIMEOUT}s (self-watchdog)")
    log.info(f"  Crash-loop guard: {list(CAMS_AUTO_DISABLE.keys())}")
    log.info(f"  No auto-recovery: {sorted(CAMS_NO_AUTO_RECOVERY)}")
    log.info(f"    Via 1: ffmpeg_pid restarts >{RESTART_THRESHOLD} in {RESTART_WINDOW_SECS}s")
    log.info(f"    Via 2: 0fps + RTSP unreachable after {CAM_DISABLE_AFTER} checks")
    log.info(f"    Via 3: 0fps + RTSP reachable after {ZERO_FPS_FORCE_DISABLE} checks")
    log.info(f"    Re-enable: RTSP recheck every {CAM_RTSP_CHECK_INTERVAL} checks")
    log.info("=" * 60)

    prev_severity = "OK"
    prev_failures = []
    check_count = 0
    HEARTBEAT_INTERVAL = 10  # cada 10 checks (5 min) loguear heartbeat

    while True:
        _loop_watchdog_reset()  # Reset self-watchdog at start of each iteration
        try:
            results = run_checks()
            update_fail_counts(results)
            severity, failures = assess_severity(results)
            check_count += 1

            # Heartbeat cada 5 minutos + primer check
            if check_count == 1 or check_count % HEARTBEAT_INTERVAL == 0:
                ok_count = sum(1 for _, res in results.items() if res[0])
                log.info(f"Heartbeat #{check_count}: {ok_count}/{len(results)} checks OK, severity={severity}")

            now = time.time()

            if severity == "SOS" and (now - last_sos_time) > SOS_COOLDOWN:
                msg = format_alert("SOS", failures, results)
                send_telegram(msg, "SOS")
                last_sos_time = now
                last_alert_time = now
                log.warning(f"SOS sent: {len(failures)} failures")

            elif severity == "ALERT" and (now - last_alert_time) > ALERT_COOLDOWN:
                msg = format_alert("ALERT", failures, results)
                send_telegram(msg, "ALERT")
                last_alert_time = now
                log.warning(f"ALERT sent: {len(failures)} failures")

            elif severity == "WARNING":
                # Solo log, no Telegram
                for key, detail, count in failures:
                    log.info(f"WARNING: {key} - {detail} (x{count})")

            # Detectar recuperación después de alerta/SOS
            if severity == "OK" and prev_severity in ("ALERT", "SOS"):
                msg = format_recovery(prev_failures)
                send_telegram(msg, "OK")
                log.info("Recovery detected, notification sent")

            prev_severity = severity
            prev_failures = failures

        except KeyboardInterrupt:
            log.info("Shutting down")
            break
        except Exception as e:
            log.error(f"Watchdog error: {e}", exc_info=True)

        time.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    main()

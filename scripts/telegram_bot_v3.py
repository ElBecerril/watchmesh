#!/usr/bin/env python3
"""
Frigate -> Telegram Bot v4

Features:
  - Teclado con botones (sin necesidad de escribir comandos)
  - Botones inline para seleccionar camara
  - Alertas inteligentes via MQTT (person/dog/cat inmediato, car solo si permanece detenido)
  - Resumen diario automatico (hora configurable, DAILY_SUMMARY_HOUR)
  - Descripcion GenAI incluida en alertas cuando disponible
  - Cooldown configurable por camara+objeto (COOLDOWN_SECONDS)
"""

import json
import os
import time
import threading
import logging
import requests
import paho.mqtt.client as mqtt
from datetime import datetime
from collections import defaultdict

# === CONFIGURACION ===
TELEGRAM_TOKEN = os.environ.get("TELEGRAM_TOKEN", "SET_TELEGRAM_TOKEN_IN_ENV")
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "SET_TELEGRAM_CHAT_ID_IN_ENV")
# IDs autorizados (coma-separados en env AUTHORIZED_IDS; por defecto solo el chat principal).
# Si no hay ninguno valido, el set queda vacio y el bot rechaza a todos (seguro por defecto).
AUTHORIZED_IDS = {int(x) for x in os.environ.get("AUTHORIZED_IDS", TELEGRAM_CHAT_ID).split(",") if x.strip().isdigit()}
FRIGATE_URL = os.environ.get("FRIGATE_URL", "http://127.0.0.1:5000")
FRIGATE_AUTH = (os.environ.get("FRIGATE_USER", "admin"), os.environ.get("FRIGATE_PASS", "SET_FRIGATE_PASS_IN_ENV"))
MQTT_HOST = "127.0.0.1"
MQTT_PORT = 1883

# Face Recognition API
FACE_API_URL = os.environ.get("FACE_API_URL", "http://127.0.0.1:5050")
FACE_API_KEY = os.environ.get("FACE_API_KEY", "")

# Parametros de alerta. Son DEFAULTS: ajustalos por entorno segun tu despliegue.
# Publicar los valores reales equivale a publicar el margen exacto en el que el
# sistema no notifica nada, asi que conviene no documentarlos fuera del sitio.
COOLDOWN_SECONDS = int(os.environ.get("COOLDOWN_SECONDS", "60"))
CAR_STATIONARY_THRESHOLD = int(os.environ.get("CAR_STATIONARY_THRESHOLD", "60"))
DAILY_SUMMARY_HOUR = int(os.environ.get("DAILY_SUMMARY_HOUR", "23"))

# Tracking (estado compartido entre threads; protegido por state_lock - BUG-16)
state_lock = threading.Lock()
last_alert = {}
car_notified_events = {}        # event_id -> notified_at (BUG-6: expiracion, no clear())
CAR_NOTIFY_TTL = 3600           # segundos: olvidar coches notificados tras 1h

# Face training: chat_id -> nombre esperando foto
pending_face_train: dict[int, str] = {}

CAMERA_NAMES = {
    "cam1_nvr": "CAM1 Lugar 1",
    "cam2_nvr": "CAM2 Lugar 1",
    "cam3_nvr": "CAM3 Lugar 1",
    "cam4_icsee": "CAM4 Lugar 1",
    "cam5_remota": "CAM5 Lugar 2",
    "cam6_remota": "CAM6 Lugar 2",
    "cam6_face": "CAM6 Zoom (Rostros)",
}

# Mapeo nombre corto -> ID Frigate
CAM_SHORT = {
    "cam1": "cam1_nvr",
    "cam2": "cam2_nvr",
    "cam3": "cam3_nvr",
    "cam4": "cam4_icsee",
    "cam5": "cam5_remota",
    "cam6": "cam6_remota",
}

LABEL_ES = {
    "person": "Persona",
    "car": "Coche",
    "dog": "Perro",
    "cat": "Gato",
}

LABEL_EMOJI = {
    "person": "\U0001f464",
    "car": "\U0001f697",
    "dog": "\U0001f436",
    "cat": "\U0001f431",
}

# Textos de botones del teclado principal
BTN_STATUS = "\U0001f4f9 Estado"
BTN_RESUMEN = "\U0001f4ca Resumen"
BTN_SNAP = "\U0001f4f7 Ver camara"
BTN_ULTIMAS = "\U0001f50d Ultimas alertas"
BTN_STATS = "\U0001f4c8 Sistema"

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("telegram_bot")


# ================= TELEGRAM API =================

def tg_api(method, timeout=15, **kwargs):
    """Llamada generica a la API de Telegram."""
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/{method}"
    try:
        resp = requests.post(url, timeout=timeout, **kwargs)
        if resp.ok:
            return resp.json().get("result")
        else:
            log.error(f"TG API {method} error: {resp.text[:150]}")
    except Exception as e:
        if "timeout" not in str(e).lower():
            log.error(f"TG API {method} exception: {e}")
    return None


def build_main_keyboard():
    """Teclado principal con botones grandes."""
    return json.dumps({
        "keyboard": [
            [{"text": BTN_STATUS}, {"text": BTN_RESUMEN}],
            [{"text": BTN_SNAP}, {"text": BTN_ULTIMAS}],
            [{"text": BTN_STATS}],
        ],
        "resize_keyboard": True,
        "is_persistent": True,
    })


def build_camera_inline_keyboard():
    """Botones inline para seleccionar camara."""
    return json.dumps({
        "inline_keyboard": [
            [
                {"text": "\U0001f3e0 CAM1", "callback_data": "snap_cam1"},
                {"text": "\U0001f3e0 CAM2", "callback_data": "snap_cam2"},
                {"text": "\U0001f3e0 CAM3", "callback_data": "snap_cam3"},
            ],
            [
                {"text": "\U0001f3e0 CAM4", "callback_data": "snap_cam4"},
                {"text": "\U0001f3ec CAM5", "callback_data": "snap_cam5"},
                {"text": "\U0001f3ec CAM6", "callback_data": "snap_cam6"},
            ],
            [
                {"text": "\U0001f4f8 Todas las camaras", "callback_data": "snap_todas"},
            ],
        ]
    })


def send_photo(photo_bytes, caption, chat_id=None):
    tg_api(
        "sendPhoto",
        data={
            "chat_id": chat_id or TELEGRAM_CHAT_ID,
            "caption": caption,
            "parse_mode": "HTML",
        },
        files={"photo": ("snapshot.jpg", photo_bytes, "image/jpeg")},
    )


def send_text(text, chat_id=None, reply_markup=None):
    data = {
        "chat_id": chat_id or TELEGRAM_CHAT_ID,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": True,
    }
    if reply_markup:
        data["reply_markup"] = reply_markup
    tg_api("sendMessage", data=data)


def answer_callback(callback_id, text=""):
    """Responder a un callback query (quitar el relojito del boton)."""
    tg_api("answerCallbackQuery", data={
        "callback_query_id": callback_id,
        "text": text,
    })


# ================= FRIGATE API =================

def frigate_get(path, params=None):
    try:
        resp = requests.get(
            f"{FRIGATE_URL}{path}",
            params=params,
            auth=FRIGATE_AUTH,
            timeout=10,
        )
        if resp.ok:
            return resp.json()
    except Exception as e:
        log.error(f"Frigate API {path} error: {e}")
    return None


def frigate_get_raw(path, params=None):
    try:
        resp = requests.get(
            f"{FRIGATE_URL}{path}",
            params=params,
            auth=FRIGATE_AUTH,
            timeout=10,
        )
        if resp.ok and len(resp.content) > 1000:
            return resp.content
    except Exception as e:
        log.error(f"Frigate raw {path} error: {e}")
    return None


def get_snapshot(event_id):
    return frigate_get_raw(f"/api/events/{event_id}/snapshot.jpg", {"bbox": 1, "quality": 80})


def get_camera_snapshot(camera):
    return frigate_get_raw(f"/api/{camera}/latest.jpg", {"quality": 80})


def get_events(hours=24, limit=500, label=None, camera=None):
    after = time.time() - (hours * 3600)
    params = {"after": after, "limit": limit}
    if label:
        params["label"] = label
    if camera:
        params["camera"] = camera
    return frigate_get("/api/events", params) or []


def get_stats():
    return frigate_get("/api/stats")


# ================= COMANDOS =================

def cmd_help(chat_id):
    send_text(
        "\U0001f44b <b>Bienvenido al sistema de vigilancia</b>\n\n"
        "Usa los botones de abajo para navegar:\n\n"
        "\U0001f4f9 <b>Estado</b> - Ver si las camaras funcionan\n"
        "\U0001f4ca <b>Resumen</b> - Que se detecto hoy\n"
        "\U0001f4f7 <b>Ver camara</b> - Foto en vivo de una camara\n"
        "\U0001f50d <b>Ultimas alertas</b> - Ultimas detecciones\n"
        "\U0001f4c8 <b>Sistema</b> - Estado tecnico del servidor\n\n"
        "<b>Face Recognition:</b>\n"
        "/entrenar NOMBRE - Entrenar rostro (envia foto)\n"
        "/rostros - Ver rostros entrenados\n"
        "/cancelar - Cancelar entrenamiento\n",
        chat_id,
        reply_markup=build_main_keyboard(),
    )


def cmd_status(chat_id):
    stats = get_stats()
    if not stats:
        send_text("\u274c No se pudo conectar con el servidor", chat_id)
        return

    lines = ["\U0001f4f9 <b>Estado de las camaras</b>\n"]
    cameras = stats.get("cameras", {})
    for cam_id, cam_data in sorted(cameras.items()):
        cam_name = CAMERA_NAMES.get(cam_id, cam_id)
        fps = cam_data.get("camera_fps", 0)
        det_on = cam_data.get("detection_enabled", False)

        if fps > 0:
            icon = "\U0001f7e2"  # verde = OK
        else:
            icon = "\U0001f534"  # rojo = problema
        det_text = "detectando" if det_on else "pausada"
        lines.append(f"{icon} <b>{cam_name}</b> - {det_text}")

    # Detector
    detectors = stats.get("detectors", {})
    for det_name, det_data in detectors.items():
        speed = det_data.get("inference_speed", 0)
        lines.append(f"\n\U0001f9e0 Inteligencia artificial: <b>{speed:.0f}ms</b> por analisis")

    # Uptime
    svc = stats.get("service", {})
    uptime_s = svc.get("uptime", 0)
    hours = int(uptime_s // 3600)
    mins = int((uptime_s % 3600) // 60)
    lines.append(f"\u23f1 Encendido hace: {hours}h {mins}m")

    # Storage
    storage = svc.get("storage", {})
    for path, info in storage.items():
        used = info.get("used", 0)
        total = info.get("total", 0)
        if total > 0:
            pct = (used / total) * 100
            lines.append(f"\U0001f4be Espacio en disco: {used:.1f}/{total:.1f} GB ({pct:.0f}%)")

    send_text("\n".join(lines), chat_id)


def aggregate_events(events):
    """Agregar eventos por label, camara y hora."""
    by_label = defaultdict(int)
    persons_by_cam = defaultdict(int)
    by_hour = defaultdict(int)

    for ev in events:
        label = ev.get("label", "?")
        camera = ev.get("camera", "?")
        by_label[label] += 1
        if label == "person":
            persons_by_cam[camera] += 1
        st = ev.get("start_time", 0)
        if st > 0:
            by_hour[datetime.fromtimestamp(st).hour] += 1

    return by_label, persons_by_cam, by_hour


def format_summary_lines(title, events, by_label, persons_by_cam, by_hour):
    """Formatear lineas de resumen."""
    lines = [title]

    personas = by_label.get("person", 0)
    coches = by_label.get("car", 0)
    lines.append(f"\U0001f464 <b>{personas}</b> personas detectadas")
    lines.append(f"\U0001f697 <b>{coches}</b> vehiculos detectados")
    for label in ["dog", "cat"]:
        count = by_label.get(label, 0)
        if count > 0:
            emoji = LABEL_EMOJI.get(label, "")
            name = LABEL_ES.get(label, label)
            lines.append(f"{emoji} <b>{count}</b> {name.lower()}(s)")

    if persons_by_cam:
        lines.append("\n<b>Personas por camara:</b>")
        for cam_id in sorted(persons_by_cam, key=persons_by_cam.get, reverse=True):
            cam_name = CAMERA_NAMES.get(cam_id, cam_id)
            lines.append(f"  \U0001f4f7 {cam_name}: <b>{persons_by_cam[cam_id]}</b>")

    if by_hour:
        peak = sorted(by_hour.items(), key=lambda x: -x[1])[:3]
        lines.append("\n<b>Horas con mas movimiento:</b>")
        for h, c in peak:
            lines.append(f"  {h:02d}:00 - {c} eventos")

    lines.append(f"\n\U0001f4cb Total: {len(events)} detecciones")
    return lines


def cmd_resumen(chat_id, hours=24):
    events = get_events(hours=hours)
    if not events:
        send_text(
            f"\U0001f4ca <b>Resumen del dia</b>\n\n"
            f"Todo tranquilo, no se detecto nada en las ultimas {hours} horas.",
            chat_id,
        )
        return

    by_label, persons_by_cam, by_hour = aggregate_events(events)
    lines = format_summary_lines(
        f"\U0001f4ca <b>Resumen de hoy</b>\n",
        events, by_label, persons_by_cam, by_hour,
    )
    send_text("\n".join(lines), chat_id)


def cmd_snap_menu(chat_id):
    """Mostrar botones para elegir camara."""
    send_text(
        "\U0001f4f7 <b>Elige una camara para ver en vivo:</b>\n\n"
        "\U0001f3e0 = Lugar 1  |  \U0001f3ec = Lugar 2",
        chat_id,
        reply_markup=build_camera_inline_keyboard(),
    )


def cmd_snap(chat_id, cam_short):
    """Enviar snapshot de una camara."""
    cam_id = CAM_SHORT.get(cam_short, cam_short)
    snapshot = get_camera_snapshot(cam_id)
    if snapshot:
        cam_name = CAMERA_NAMES.get(cam_id, cam_id)
        now = datetime.now().strftime("%H:%M:%S")
        send_photo(snapshot, f"\U0001f4f7 <b>{cam_name}</b>\n\U0001f552 {now}", chat_id)
    else:
        send_text(f"\u274c No se pudo obtener la imagen de {cam_short}", chat_id)


def cmd_snap_todas(chat_id):
    """Enviar snapshot de todas las camaras."""
    send_text("\U0001f4f8 Capturando todas las camaras...", chat_id)
    for cam_short, cam_id in CAM_SHORT.items():
        snapshot = get_camera_snapshot(cam_id)
        if snapshot:
            cam_name = CAMERA_NAMES.get(cam_id, cam_id)
            now = datetime.now().strftime("%H:%M:%S")
            send_photo(snapshot, f"\U0001f4f7 <b>{cam_name}</b> - {now}", chat_id)
        time.sleep(0.5)  # Evitar flood


def cmd_ultimas(chat_id, n=5):
    events = get_events(hours=24, limit=n)
    if not events:
        send_text("\U0001f50d No hay detecciones recientes", chat_id)
        return

    lines = [f"\U0001f50d <b>Ultimas {len(events)} alertas:</b>\n"]
    for ev in events:
        label = ev.get("label", "?")
        camera = ev.get("camera", "?")
        score = ev.get("data", {}).get("top_score", 0) if ev.get("data") else 0
        start = ev.get("start_time", 0)
        zones = ev.get("zones", [])
        genai_desc = ev.get("data", {}).get("description", "") if ev.get("data") else ""

        cam_name = CAMERA_NAMES.get(camera, camera)
        emoji = LABEL_EMOJI.get(label, "\u2022")
        label_es = LABEL_ES.get(label, label)
        time_str = datetime.fromtimestamp(start).strftime("%H:%M") if start > 0 else "?"

        line = f"{emoji} <b>{time_str}</b> - {label_es} en {cam_name}"
        if zones:
            line += f" ({', '.join(zones)})"
        lines.append(line)

        if genai_desc:
            lines.append(f"   <i>{genai_desc}</i>")

    send_text("\n".join(lines), chat_id)


def cmd_stats(chat_id):
    stats = get_stats()
    if not stats:
        send_text("\u274c No se pudo conectar con el servidor", chat_id)
        return

    svc = stats.get("service", {})
    detectors = stats.get("detectors", {})
    cameras = stats.get("cameras", {})

    total_cam_fps = sum(c.get("camera_fps", 0) for c in cameras.values())
    total_det_fps = sum(c.get("detection_fps", 0) for c in cameras.values())
    total_skipped = sum(c.get("skipped_fps", 0) for c in cameras.values())

    lines = ["\U0001f4c8 <b>Estado del servidor</b>\n"]

    for det_name, det_data in detectors.items():
        speed = det_data.get("inference_speed", 0)
        lines.append(f"\U0001f9e0 IA (Coral TPU): <b>{speed:.0f}ms</b> por analisis")

    lines.append(f"\U0001f4f9 Camaras activas: <b>{len(cameras)}</b>")
    lines.append(f"\U0001f39e Video total: <b>{total_cam_fps:.0f} fps</b>")
    lines.append(f"\U0001f916 Analisis IA: <b>{total_det_fps:.0f} fps</b>")
    if total_skipped > 1:
        lines.append(f"\u26a0 Frames sin analizar: <b>{total_skipped:.0f} fps</b>")

    # Temperaturas
    temps = svc.get("temperatures", {})
    if temps:
        lines.append("")
        for sensor, t in temps.items():
            if t is not None:
                if t < 60:
                    icon = "\U0001f7e2"
                    estado = "normal"
                elif t < 75:
                    icon = "\U0001f7e1"
                    estado = "tibio"
                else:
                    icon = "\U0001f534"
                    estado = "caliente!"
                lines.append(f"{icon} Temperatura: <b>{t:.0f}C</b> ({estado})")

    # Uptime
    uptime_s = svc.get("uptime", 0)
    days = int(uptime_s // 86400)
    hours = int((uptime_s % 86400) // 3600)
    mins = int((uptime_s % 3600) // 60)
    if days > 0:
        uptime_str = f"{days} dias, {hours}h {mins}m"
    else:
        uptime_str = f"{hours}h {mins}m"
    lines.append(f"\n\u23f1 Tiempo encendido: <b>{uptime_str}</b>")

    send_text("\n".join(lines), chat_id)


# ================= FACE RECOGNITION =================

def cmd_entrenar(chat_id, name=""):
    """Iniciar entrenamiento de rostro."""
    if not name:
        send_text(
            "\U0001f9d1 <b>Entrenar rostro</b>\n\n"
            "Uso: /entrenar NOMBRE\n"
            "Ejemplo: <code>/entrenar Maria</code>\n\n"
            "Despues envia una foto con el rostro de la persona.",
            chat_id,
        )
        return
    name = name.strip().upper()
    pending_face_train[int(chat_id)] = name
    send_text(
        f"\U0001f4f8 <b>Entrenando: {name}</b>\n\n"
        f"Envia una foto con el rostro de {name} visible.\n"
        f"La foto debe tener exactamente 1 rostro.\n\n"
        f"Puedes enviar varias fotos para mejor precision.\n"
        f"Escribe /cancelar para cancelar.",
        chat_id,
    )


def cmd_rostros(chat_id):
    """Listar rostros entrenados."""
    try:
        resp = requests.get(
            f"{FACE_API_URL}/faces",
            headers={"X-API-Key": FACE_API_KEY},
            timeout=5,
        )
        if resp.ok:
            data = resp.json()
            faces = data.get("faces", {})
            if not faces:
                send_text("\U0001f9d1 No hay rostros entrenados.", chat_id)
                return
            lines = ["\U0001f9d1 <b>Rostros entrenados:</b>\n"]
            for name, count in faces.items():
                lines.append(f"  \u2022 <b>{name}</b>: {count} foto(s)")
            lines.append(f"\nUsa /entrenar NOMBRE para agregar mas.")
            send_text("\n".join(lines), chat_id)
        else:
            send_text("\u274c Error conectando con Face API", chat_id)
    except Exception as e:
        send_text(f"\u274c Face API no disponible: {e}", chat_id)


def handle_photo_for_training(chat_id, message):
    """Procesar foto enviada para entrenamiento de rostro."""
    chat_id_int = int(chat_id)
    name = pending_face_train.get(chat_id_int)
    if not name:
        return False

    photos = message.get("photo", [])
    if not photos:
        return False

    # Tomar la foto de mayor resolucion
    best_photo = max(photos, key=lambda p: p.get("file_size", 0))
    file_id = best_photo.get("file_id")

    # Descargar archivo de Telegram
    file_info = tg_api("getFile", data={"file_id": file_id})
    if not file_info:
        send_text("\u274c No se pudo descargar la foto", chat_id)
        return True

    file_path = file_info.get("file_path", "")
    file_url = f"https://api.telegram.org/file/bot{TELEGRAM_TOKEN}/{file_path}"

    try:
        img_resp = requests.get(file_url, timeout=10)
        img_resp.raise_for_status()  # BUG-12: no subir body de error como imagen
        img_data = img_resp.content
    except Exception as e:
        send_text(f"\u274c Error descargando foto: {e}", chat_id)
        return True

    # Enviar al Face API para entrenar
    try:
        resp = requests.post(
            f"{FACE_API_URL}/train/{name}",
            files={"file": ("photo.jpg", img_data, "image/jpeg")},
            headers={"X-API-Key": FACE_API_KEY},
            timeout=15,
        )
        if resp.ok:
            data = resp.json()
            samples = data.get("samples", 0)
            send_text(
                f"\u2705 <b>Rostro registrado!</b>\n\n"
                f"Nombre: <b>{name}</b>\n"
                f"Muestras totales: <b>{samples}</b>\n\n"
                f"Envia mas fotos para mejor precision\n"
                f"o escribe /cancelar cuando termines.",
                chat_id,
            )
            log.info(f"Face trained: {name} ({samples} samples)")
        else:
            error = resp.json().get("detail", resp.text[:200])
            send_text(f"\u274c Error: {error}", chat_id)
    except Exception as e:
        send_text(f"\u274c Face API error: {e}", chat_id)

    return True


# ================= RESUMEN DIARIO =================

def send_daily_summary():
    log.info("Generando resumen diario automatico...")
    events = get_events(hours=24)
    if not events:
        send_text(
            "\U0001f319 <b>Resumen del dia</b>\n\n"
            "Todo tranquilo, no hubo detecciones hoy."
        )
        return

    by_label, persons_by_cam, by_hour = aggregate_events(events)
    title = (
        "\U0001f319 <b>Resumen del dia</b>\n"
        f"\U0001f4c5 {datetime.now().strftime('%d/%m/%Y')}\n"
    )
    lines = format_summary_lines(title, events, by_label, persons_by_cam, by_hour)
    send_text("\n".join(lines))
    log.info(f"Resumen diario enviado: {len(events)} eventos")


def cancel_training(chat_id):
    """Cancelar entrenamiento pendiente."""
    chat_id_int = int(chat_id)
    if chat_id_int in pending_face_train:
        name = pending_face_train.pop(chat_id_int)
        send_text(f"\u274c Entrenamiento de <b>{name}</b> cancelado.", chat_id)
    else:
        send_text("No hay entrenamiento pendiente.", chat_id)


def daily_summary_scheduler():
    last_sent = None
    while True:
        try:
            now = datetime.now()
            today = now.strftime("%Y-%m-%d")
            if now.hour == DAILY_SUMMARY_HOUR and last_sent != today:
                send_daily_summary()
                last_sent = today
            time.sleep(30)
        except Exception as e:
            log.error(f"Daily scheduler error: {e}")
            time.sleep(60)


# ================= TELEGRAM POLLING =================

def handle_button_text(chat_id, text):
    """Manejar texto de botones del teclado principal."""
    if text == BTN_STATUS:
        cmd_status(chat_id)
    elif text == BTN_RESUMEN:
        cmd_resumen(chat_id)
    elif text == BTN_SNAP:
        cmd_snap_menu(chat_id)
    elif text == BTN_ULTIMAS:
        cmd_ultimas(chat_id)
    elif text == BTN_STATS:
        cmd_stats(chat_id)
    else:
        return False
    return True


def handle_command(chat_id, text):
    """Manejar comandos con /."""
    parts = text.strip().split(maxsplit=1)
    cmd = parts[0].lower().split("@")[0]  # Quitar @botname
    args = parts[1] if len(parts) > 1 else ""

    handlers = {
        "/help": lambda: cmd_help(chat_id),
        "/start": lambda: cmd_help(chat_id),
        "/status": lambda: cmd_status(chat_id),
        "/resumen": lambda: cmd_resumen(chat_id),
        "/snap": lambda: cmd_snap(chat_id, args) if args else cmd_snap_menu(chat_id),
        "/ultimas": lambda: cmd_ultimas(chat_id, int(args) if args.isdigit() else 5),
        "/stats": lambda: cmd_stats(chat_id),
        "/entrenar": lambda: cmd_entrenar(chat_id, args),
        "/rostros": lambda: cmd_rostros(chat_id),
        "/cancelar": lambda: cancel_training(chat_id),
    }

    handler = handlers.get(cmd)
    if handler:
        log.info(f"Comando: {cmd} de chat {chat_id}")
        handler()
        return True
    return False


def handle_callback(callback_query):
    """Manejar pulsaciones de botones inline."""
    cb_id = callback_query.get("id", "")
    data = callback_query.get("data", "")
    chat_id = str(callback_query.get("message", {}).get("chat", {}).get("id", ""))

    if not chat_id:
        return

    if data == "snap_todas":
        answer_callback(cb_id, "Capturando todas...")
        log.info(f"Callback: snap_todas de chat {chat_id}")
        cmd_snap_todas(chat_id)
    elif data.startswith("snap_cam"):
        cam_short = data.replace("snap_", "")
        cam_name = CAMERA_NAMES.get(CAM_SHORT.get(cam_short, ""), cam_short)
        answer_callback(cb_id, f"Capturando {cam_name}...")
        log.info(f"Callback: snap {cam_short} de chat {chat_id}")
        cmd_snap(chat_id, cam_short)
    else:
        answer_callback(cb_id)


def telegram_polling():
    """Thread de polling para mensajes y callbacks."""
    offset = 0
    log.info("Telegram polling iniciado")

    while True:
        try:
            result = tg_api(
                "getUpdates",
                timeout=60,
                data={
                    "offset": offset,
                    "timeout": 30,
                    "allowed_updates": '["message","callback_query"]',
                },
            )
            if not result:
                time.sleep(5)
                continue

            for update in result:
                offset = update["update_id"] + 1

                # Callback de botones inline
                cb = update.get("callback_query")
                if cb:
                    # Autorizar por el USUARIO que pulsa (from.id), no por el chat (BUG-5)
                    cb_user_id = cb.get("from", {}).get("id")
                    if cb_user_id not in AUTHORIZED_IDS:
                        answer_callback(cb.get("id", ""), "No autorizado")
                        continue
                    handle_callback(cb)
                    continue

                # Mensaje
                msg = update.get("message", {})
                text = msg.get("text", "")
                chat_id = msg.get("chat", {}).get("id")
                user_id = msg.get("from", {}).get("id")

                if not chat_id:
                    continue

                # Verificar autorizacion por el USUARIO que envia (from.id), no el chat (BUG-5)
                if user_id not in AUTHORIZED_IDS:
                    log.warning(f"Acceso no autorizado: user_id={user_id} chat_id={chat_id}")
                    continue

                chat_id_str = str(chat_id)

                # Fotos: verificar si es entrenamiento de rostro
                if msg.get("photo"):
                    if handle_photo_for_training(chat_id_str, msg):
                        continue

                if not text:
                    continue

                # Intentar como boton del teclado
                if handle_button_text(chat_id_str, text):
                    continue

                # Intentar como comando /
                if text.startswith("/"):
                    if not handle_command(chat_id_str, text):
                        send_text(
                            "No entendi ese comando.\nUsa los botones de abajo o escribe /help",
                            chat_id_str,
                            reply_markup=build_main_keyboard(),
                        )

        except Exception as e:
            log.error(f"Polling error: {e}")
            time.sleep(10)


# ================= MQTT ALERTAS =================

def send_alert(event_id, camera, label, score, extra=""):
    cam_name = CAMERA_NAMES.get(camera, camera)
    label_es = LABEL_ES.get(label, label)

    caption = (
        f"\U0001f6a8 <b>{label_es} detectado</b>\n"
        f"\U0001f4f7 {cam_name}\n"
        f"\U0001f3af Confianza: {score:.0%}"
    )
    if extra:
        caption += f"\n{extra}"

    snapshot = get_snapshot(event_id)
    if snapshot:
        send_photo(snapshot, caption)
    else:
        send_text(caption)


def check_cooldown(camera, label):
    key = f"{camera}_{label}"
    now = time.time()
    with state_lock:
        if key in last_alert and (now - last_alert[key]) < COOLDOWN_SECONDS:
            return False
        last_alert[key] = now
    return True


def on_connect(client, userdata, flags, reason_code, properties):
    log.info(f"MQTT conectado (rc={reason_code})")
    client.subscribe("frigate/events")
    client.subscribe("frigate/reviews")
    log.info("Suscrito a frigate/events y frigate/reviews")


def on_message(client, userdata, msg):
    try:
        payload = json.loads(msg.payload)
    except json.JSONDecodeError:
        return

    if msg.topic == "frigate/reviews":
        handle_review(payload)
        return

    event_type = payload.get("type")
    before = payload.get("before", {})
    after = payload.get("after", {})
    data = after if after else before

    camera = data.get("camera", "")
    label = data.get("label", "")
    score = data.get("top_score") or 0
    event_id = data.get("id", "")
    start_time = data.get("start_time") or 0

    if label not in LABEL_ES:
        return

    # === COCHES: solo si llevan detenidos CAR_STATIONARY_THRESHOLD segundos ===
    if label == "car":
        if event_type == "new":
            return
        if event_type == "update":
            with state_lock:
                if event_id in car_notified_events:
                    return
            now = time.time()
            duration = now - start_time if start_time > 0 else 0
            if duration < CAR_STATIONARY_THRESHOLD:
                return
            if not check_cooldown(camera, label):
                return
            with state_lock:
                car_notified_events[event_id] = now
                # Limpiar por antiguedad (BUG-6): evita el clear() catastrofico
                # que re-notificaba coches aun vivos al llegar a 100 entradas.
                cutoff = now - CAR_NOTIFY_TTL
                for k in [eid for eid, ts in car_notified_events.items() if ts < cutoff]:
                    del car_notified_events[k]
            log.info(f"COCHE DETENIDO: {camera} ({duration:.0f}s)")
            send_alert(event_id, camera, label, score, f"\u23f1 Detenido: {duration:.0f}s")
            return
        return

    # === PERSONA/PERRO/GATO: alerta inmediata ===
    if event_type == "new":
        if not check_cooldown(camera, label):
            return
        current_zones = data.get("current_zones", [])
        zone_text = ""
        if current_zones:
            zone_text = f"\U0001f4cd Zona: {', '.join(current_zones)}"
        log.info(f"ALERTA: {label} en {camera} ({score:.0%})")
        send_alert(event_id, camera, label, score, zone_text)


def handle_review(payload):
    review_type = payload.get("type")
    if review_type != "new":
        return
    after = payload.get("after", {})
    data = after.get("data", {})
    description = data.get("description", "")
    if not description:
        return
    camera = after.get("camera", "")
    cam_name = CAMERA_NAMES.get(camera, camera)
    severity = data.get("severity", "")
    if severity != "alert":
        return

    # Enriquecer con contexto del review
    objects = data.get("objects", [])
    zones = data.get("zones", [])
    detections = data.get("detections", [])
    now = datetime.now().strftime("%H:%M")

    lines = [f"\U0001f9e0 <b>Analisis IA - {cam_name}</b>"]
    lines.append(f"\U0001f552 {now}")

    if objects:
        obj_parts = []
        for obj in objects:
            emoji = LABEL_EMOJI.get(obj, "\U0001f4a1")
            name = LABEL_ES.get(obj, obj)
            obj_parts.append(f"{emoji} {name}")
        lines.append(f"\U0001f4cc Detectado: {', '.join(obj_parts)}")

    if zones:
        lines.append(f"\U0001f4cd Zona: {', '.join(zones)}")

    lines.append(f"\n\U0001f4ac <i>{description}</i>")

    caption = "\n".join(lines)

    # Enviar con snapshot del evento si disponible
    snapshot = None
    if detections:
        snapshot = get_snapshot(detections[0])

    if snapshot:
        send_photo(snapshot, caption)
    else:
        send_text(caption)

    log.info(f"GenAI review: {camera} - {description[:60]}")


# ================= MAIN =================

def main():
    log.info("=== Telegram Bot Vigilancia v4.2 (telegram_bot_v3.py) ===")

    send_text(
        "\U0001f7e2 <b>Sistema de vigilancia activo</b>\n\n"
        "\U0001f4f7 7 camaras monitoreadas\n"
        "\U0001f9e0 Deteccion inteligente activada\n"
        "\U0001f319 Resumen automatico diario\n\n"
        "Usa los botones de abajo para controlar el sistema:",
        reply_markup=build_main_keyboard(),
    )

    # Thread: Telegram polling (mensajes + callbacks)
    t_poll = threading.Thread(target=telegram_polling, daemon=True)
    t_poll.start()

    # Thread: Resumen diario
    t_daily = threading.Thread(target=daily_summary_scheduler, daemon=True)
    t_daily.start()

    # Main thread: MQTT alertas
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    client.on_connect = on_connect
    client.on_message = on_message

    while True:
        try:
            client.connect(MQTT_HOST, MQTT_PORT, 60)
            client.loop_forever()
        except Exception as e:
            log.error(f"MQTT error: {e}, reconectando en 10s...")
            time.sleep(10)


if __name__ == "__main__":
    main()

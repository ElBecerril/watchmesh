#!/usr/bin/env python3
"""
Face Bridge - Puente MQTT -> InsightFace API remoto

Escucha eventos MQTT de Frigate, descarga snapshots de personas,
los envía al servidor InsightFace remoto y actualiza sub_labels en Frigate.

Funciona como puente entre:
  Frigate (proxmox-lugar1 LXC 200) <--MQTT--> face_bridge <--HTTP/Tailscale--> VM 110 InsightFace

Solo procesa cam5_remota y cam6_remota.
"""

import json
import logging
import os
import sys
import time

import paho.mqtt.client as mqtt
import requests

# === CONFIGURACION ===
MQTT_HOST = os.environ.get("MQTT_HOST", "127.0.0.1")
MQTT_PORT = int(os.environ.get("MQTT_PORT", "1883"))
FRIGATE_URL = os.environ.get("FRIGATE_URL", "http://127.0.0.1:5000")
FRIGATE_USER = os.environ.get("FRIGATE_USER", "admin")
FRIGATE_PASS = os.environ.get("FRIGATE_PASS", "SET_FRIGATE_PASS_IN_ENV")
FACE_API_URL = os.environ.get("FACE_API_URL", "http://100.64.10.5:5050")
FACE_API_KEY = os.environ.get("FACE_API_KEY", "")

# Camaras habilitadas para face recognition
ENABLED_CAMERAS = {"cam5_remota", "cam6_remota", "cam6_face"}

# Cooldown por camara (segundos) para evitar spam
COOLDOWN_SECONDS = int(os.environ.get("COOLDOWN_SECONDS", "30"))

# Espera antes de descargar snapshot (Frigate necesita tiempo para generar buen snapshot)
SNAPSHOT_DELAY = float(os.environ.get("SNAPSHOT_DELAY", "1.5"))

# Umbral minimo de confianza para aceptar un reconocimiento
MIN_CONFIDENCE = float(os.environ.get("MIN_CONFIDENCE", "0.45"))

# Timeout para requests HTTP
HTTP_TIMEOUT = int(os.environ.get("HTTP_TIMEOUT", "10"))

# Tamano minimo de rostro en pixels para enviar a la API (ancho o alto)
MIN_FACE_SIZE = int(os.environ.get("MIN_FACE_SIZE", "40"))

# Tambien procesar evento "update" (mejores snapshots conforme la persona se acerca)
PROCESS_UPDATES = True
UPDATE_INTERVAL = 5.0  # segundos minimo entre updates del mismo evento

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger(__name__)

# Tracking de cooldown por camara y evento
last_processed: dict[str, float] = {}
last_event_update: dict[str, float] = {}  # event_id -> last update time
recognized_events: set = set()  # eventos ya reconocidos exitosamente


def is_on_cooldown(camera: str) -> bool:
    """Verifica si la camara esta en cooldown."""
    now = time.time()
    last = last_processed.get(camera, 0)
    return (now - last) < COOLDOWN_SECONDS


def download_snapshot(event_id: str) -> bytes | None:
    """Descarga snapshot de un evento de Frigate."""
    url = f"{FRIGATE_URL}/api/events/{event_id}/snapshot.jpg"
    try:
        resp = requests.get(
            url,
            auth=(FRIGATE_USER, FRIGATE_PASS),
            timeout=HTTP_TIMEOUT,
            params={"quality": 95},
        )
        if resp.status_code == 200 and len(resp.content) > 1000:
            return resp.content
        logger.warning(f"Snapshot failed: status={resp.status_code}, size={len(resp.content)}")
    except requests.RequestException as e:
        logger.error(f"Error downloading snapshot {event_id}: {e}")
    return None


def recognize_face(image_data: bytes) -> list[dict] | None:
    """Envía imagen al servidor InsightFace y retorna rostros reconocidos.
    Filtra rostros demasiado pequeños para reconocimiento confiable."""
    url = f"{FACE_API_URL}/recognize"
    headers = {"X-API-Key": FACE_API_KEY} if FACE_API_KEY else {}
    try:
        resp = requests.post(
            url,
            files={"file": ("snapshot.jpg", image_data, "image/jpeg")},
            headers=headers,
            timeout=HTTP_TIMEOUT,
        )
        if resp.status_code == 200:
            data = resp.json()
            all_faces = data["faces"]
            # Filtrar rostros demasiado pequenos
            valid_faces = []
            for f in all_faces:
                bbox = f["bbox"]
                w = bbox[2] - bbox[0]
                h = bbox[3] - bbox[1]
                if w >= MIN_FACE_SIZE or h >= MIN_FACE_SIZE:
                    valid_faces.append(f)
                else:
                    logger.debug(f"Face too small: {w}x{h}px (min {MIN_FACE_SIZE})")

            skipped = len(all_faces) - len(valid_faces)
            if skipped > 0:
                logger.info(
                    f"API response: {len(all_faces)} face(s), "
                    f"{len(valid_faces)} valid (>={MIN_FACE_SIZE}px), "
                    f"{skipped} too small, {data['processing_ms']:.0f}ms"
                )
            else:
                logger.info(
                    f"API response: {len(all_faces)} face(s), "
                    f"{data['processing_ms']:.0f}ms"
                )
            return valid_faces
        logger.warning(f"API error: status={resp.status_code}, body={resp.text[:200]}")
    except requests.RequestException as e:
        logger.error(f"Error calling face API: {e}")
    return None


def update_sub_label(event_id: str, sub_label: str):
    """Actualiza el sub_label de un evento en Frigate."""
    url = f"{FRIGATE_URL}/api/events/{event_id}/sub_label"
    try:
        resp = requests.post(
            url,
            json={"subLabel": sub_label},
            auth=(FRIGATE_USER, FRIGATE_PASS),
            timeout=HTTP_TIMEOUT,
        )
        if resp.status_code == 200:
            logger.info(f"Sub-label updated: event={event_id}, label={sub_label}")
        else:
            logger.warning(f"Sub-label update failed: {resp.status_code} {resp.text[:200]}")
    except requests.RequestException as e:
        logger.error(f"Error updating sub_label: {e}")


def process_event(event_data: dict):
    """Procesa un evento MQTT de Frigate.

    Procesa tanto 'new' como 'update' - cuando una persona se acerca,
    los updates traen snapshots con rostros mas grandes y reconocibles.
    """
    after = event_data.get("after", {})
    event_type = event_data.get("type")
    event_id = after.get("id")
    label = after.get("label")
    camera = after.get("camera")

    if label != "person":
        return

    # Solo camaras habilitadas
    if camera not in ENABLED_CAMERAS:
        return

    # Eventos "new": cooldown por camara
    if event_type == "new":
        if is_on_cooldown(camera):
            return
        last_processed[camera] = time.time()

    # Eventos "update": reintentar si aun no se reconocio
    elif event_type == "update" and PROCESS_UPDATES:
        if event_id in recognized_events:
            return  # Ya reconocido, no reintentar
        now = time.time()
        last_update = last_event_update.get(event_id, 0)
        if (now - last_update) < UPDATE_INTERVAL:
            return  # Rate limit updates
        last_event_update[event_id] = now
    else:
        return

    logger.info(f"Processing: camera={camera}, event={event_id}, type={event_type}")

    # Esperar a que Frigate genere buen snapshot (solo en new)
    if event_type == "new":
        time.sleep(SNAPSHOT_DELAY)

    # Descargar snapshot
    snapshot = download_snapshot(event_id)
    if not snapshot:
        logger.warning(f"No snapshot for event {event_id}")
        return

    # Enviar al servidor de face recognition
    faces = recognize_face(snapshot)
    if not faces:
        return

    # Buscar el rostro con mayor confianza que no sea "unknown"
    best_match = None
    for face in faces:
        if face["name"] != "unknown" and face["confidence"] >= MIN_CONFIDENCE:
            if best_match is None or face["confidence"] > best_match["confidence"]:
                best_match = face

    if best_match:
        logger.info(
            f"RECOGNIZED: {best_match['name']} "
            f"(confidence={best_match['confidence']:.3f}) "
            f"on {camera} [{event_type}]"
        )
        update_sub_label(event_id, best_match["name"])
        recognized_events.add(event_id)
        # Limpiar tracking viejo (evitar memory leak)
        if len(recognized_events) > 500:
            recognized_events.clear()
        last_event_update.pop(event_id, None)
    else:
        names = [face["name"] for face in faces]
        logger.info(f"No match above threshold on {camera}: {names}")

    # Limpiar event updates viejos (>5 min)
    now = time.time()
    stale = [k for k, v in last_event_update.items() if now - v > 300]
    for k in stale:
        del last_event_update[k]


def on_connect(client, userdata, flags, rc, properties=None):
    if rc == 0:
        logger.info("Connected to MQTT broker")
        client.subscribe("frigate/events")
        logger.info("Subscribed to frigate/events")
    else:
        logger.error(f"MQTT connection failed: rc={rc}")


def on_message(client, userdata, msg):
    try:
        payload = json.loads(msg.payload)
        process_event(payload)
    except json.JSONDecodeError:
        logger.error("Invalid JSON in MQTT message")
    except Exception as e:
        logger.error(f"Error processing event: {e}", exc_info=True)


def check_face_api():
    """Verifica que el servidor de face recognition está accesible."""
    try:
        resp = requests.get(f"{FACE_API_URL}/health", timeout=5)
        if resp.status_code == 200:
            data = resp.json()
            logger.info(
                f"Face API OK: model={data['model']}, "
                f"faces={data['faces_registered']}, "
                f"threshold={data['threshold']}"
            )
            return True
    except requests.RequestException as e:
        logger.warning(f"Face API not reachable: {e}")
    return False


def main():
    logger.info("=" * 60)
    logger.info("Face Bridge v1.1 starting (smart retry + min face size)")
    logger.info(f"  MQTT: {MQTT_HOST}:{MQTT_PORT}")
    logger.info(f"  Frigate: {FRIGATE_URL}")
    logger.info(f"  Face API: {FACE_API_URL}")
    logger.info(f"  Cameras: {ENABLED_CAMERAS}")
    logger.info(f"  Cooldown: {COOLDOWN_SECONDS}s")
    logger.info(f"  Min confidence: {MIN_CONFIDENCE}")
    logger.info(f"  Min face size: {MIN_FACE_SIZE}px")
    logger.info(f"  Process updates: {PROCESS_UPDATES}")
    logger.info("=" * 60)

    # Check face API (warning only, don't block startup)
    if not check_face_api():
        logger.warning("Face API not available - will retry on each event")

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="face_bridge")
    client.on_connect = on_connect
    client.on_message = on_message

    while True:
        try:
            client.connect(MQTT_HOST, MQTT_PORT, keepalive=60)
            client.loop_forever()
        except KeyboardInterrupt:
            logger.info("Shutting down")
            client.disconnect()
            break
        except Exception as e:
            logger.error(f"MQTT error: {e}, reconnecting in 10s...")
            time.sleep(10)


if __name__ == "__main__":
    main()

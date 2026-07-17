#!/usr/bin/env python3
"""
Frigate Prometheus Exporter v2

Metricas exportadas:
  - Infraestructura: camera_fps, detection_fps, process_fps, skipped_fps, inference_ms, storage, uptime, temps
  - Eventos: conteo por camara+label (hoy, ultima hora, total activos)
"""

import json
import os
import time
import base64
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
from datetime import datetime
from collections import defaultdict
from urllib.request import Request, urlopen
from urllib.error import URLError

FRIGATE_URL = os.environ.get("FRIGATE_URL", "http://127.0.0.1:5000")
_FRIGATE_USER = os.environ.get("FRIGATE_USER", "admin")
_FRIGATE_PASS = os.environ.get("FRIGATE_PASS", "SET_FRIGATE_PASS_IN_ENV")
FRIGATE_AUTH = base64.b64encode(f"{_FRIGATE_USER}:{_FRIGATE_PASS}".encode()).decode()
PORT = 9101

# Cache de eventos (se actualiza cada 60s para no saturar Frigate)
event_cache = {"data": {}, "last_update": 0}
EVENT_CACHE_TTL = 60  # segundos


def frigate_get(path):
    """GET a la API de Frigate."""
    try:
        req = Request(f"{FRIGATE_URL}{path}")
        req.add_header("Authorization", f"Basic {FRIGATE_AUTH}")
        req.add_header("Connection", "close")
        with urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except Exception:
        return None


def get_event_counts():
    """Obtener conteos de eventos, con cache."""
    now = time.time()
    if now - event_cache["last_update"] < EVENT_CACHE_TTL:
        return event_cache["data"]

    result = {
        "today": defaultdict(lambda: defaultdict(int)),
        "last_hour": defaultdict(lambda: defaultdict(int)),
        "active": defaultdict(lambda: defaultdict(int)),
    }

    # Eventos de hoy (desde medianoche)
    today_start = datetime.now().replace(hour=0, minute=0, second=0).timestamp()
    events_today = frigate_get(f"/api/events?after={today_start}&limit=500")
    if events_today:
        hour_ago = now - 3600
        for ev in events_today:
            camera = ev.get("camera", "unknown")
            label = ev.get("label", "unknown")
            result["today"][camera][label] += 1

            st = ev.get("start_time", 0)
            if st >= hour_ago:
                result["last_hour"][camera][label] += 1

            if ev.get("end_time") is None:
                result["active"][camera][label] += 1

    event_cache["data"] = result
    event_cache["last_update"] = now
    return result


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return

        try:
            metrics = []

            # === STATS (infraestructura) ===
            stats = frigate_get("/api/stats")
            if stats:
                # Camera metrics
                metrics.append("# HELP frigate_camera_fps Camera input FPS")
                metrics.append("# TYPE frigate_camera_fps gauge")
                metrics.append("# HELP frigate_detection_fps Detection FPS per camera")
                metrics.append("# TYPE frigate_detection_fps gauge")
                metrics.append("# HELP frigate_process_fps Process FPS")
                metrics.append("# TYPE frigate_process_fps gauge")
                metrics.append("# HELP frigate_skipped_fps Skipped FPS")
                metrics.append("# TYPE frigate_skipped_fps gauge")
                metrics.append("# HELP frigate_detection_enabled Detection enabled (1/0)")
                metrics.append("# TYPE frigate_detection_enabled gauge")

                for cam, s in stats.get("cameras", {}).items():
                    metrics.append(f'frigate_camera_fps{{camera="{cam}"}} {s.get("camera_fps", 0)}')
                    metrics.append(f'frigate_detection_fps{{camera="{cam}"}} {s.get("detection_fps", 0)}')
                    metrics.append(f'frigate_process_fps{{camera="{cam}"}} {s.get("process_fps", 0)}')
                    metrics.append(f'frigate_skipped_fps{{camera="{cam}"}} {s.get("skipped_fps", 0)}')
                    metrics.append(f'frigate_detection_enabled{{camera="{cam}"}} {1 if s.get("detection_enabled") else 0}')

                # Detector metrics
                metrics.append("# HELP frigate_detector_inference_ms Inference speed ms")
                metrics.append("# TYPE frigate_detector_inference_ms gauge")
                for d, s in stats.get("detectors", {}).items():
                    metrics.append(f'frigate_detector_inference_ms{{detector="{d}"}} {s.get("inference_speed", 0)}')

                # Temperatures
                svc = stats.get("service", {})
                temps = svc.get("temperatures", {})
                if temps:
                    metrics.append("# HELP frigate_temperature_celsius Temperature")
                    metrics.append("# TYPE frigate_temperature_celsius gauge")
                    for sensor, t in temps.items():
                        if t is not None:
                            metrics.append(f'frigate_temperature_celsius{{sensor="{sensor}"}} {t}')

                # Storage
                storage = svc.get("storage", {})
                if storage:
                    metrics.append("# HELP frigate_storage_used_gb Storage used GB")
                    metrics.append("# TYPE frigate_storage_used_gb gauge")
                    metrics.append("# HELP frigate_storage_total_gb Storage total GB")
                    metrics.append("# TYPE frigate_storage_total_gb gauge")
                    for path, info in storage.items():
                        p = path.replace("/", "_").strip("_")
                        metrics.append(f'frigate_storage_used_gb{{path="{p}"}} {info.get("used", 0)}')
                        metrics.append(f'frigate_storage_total_gb{{path="{p}"}} {info.get("total", 0)}')

                # Uptime
                metrics.append("# HELP frigate_uptime_seconds Uptime")
                metrics.append("# TYPE frigate_uptime_seconds gauge")
                metrics.append(f'frigate_uptime_seconds {svc.get("uptime", 0)}')

            # === EVENTOS (conteos) ===
            event_counts = get_event_counts()

            # Eventos hoy
            metrics.append("# HELP frigate_events_today Total events today by camera and label")
            metrics.append("# TYPE frigate_events_today gauge")
            for camera, labels in event_counts.get("today", {}).items():
                for label, count in labels.items():
                    metrics.append(f'frigate_events_today{{camera="{camera}",label="{label}"}} {count}')

            # Eventos ultima hora
            metrics.append("# HELP frigate_events_last_hour Events in the last hour by camera and label")
            metrics.append("# TYPE frigate_events_last_hour gauge")
            for camera, labels in event_counts.get("last_hour", {}).items():
                for label, count in labels.items():
                    metrics.append(f'frigate_events_last_hour{{camera="{camera}",label="{label}"}} {count}')

            # Eventos activos (en curso)
            metrics.append("# HELP frigate_events_active Currently active events by camera and label")
            metrics.append("# TYPE frigate_events_active gauge")
            for camera, labels in event_counts.get("active", {}).items():
                for label, count in labels.items():
                    metrics.append(f'frigate_events_active{{camera="{camera}",label="{label}"}} {count}')

            # Totales agregados
            total_today = sum(
                count
                for labels in event_counts.get("today", {}).values()
                for count in labels.values()
            )
            total_persons_today = sum(
                labels.get("person", 0)
                for labels in event_counts.get("today", {}).values()
            )
            total_cars_today = sum(
                labels.get("car", 0)
                for labels in event_counts.get("today", {}).values()
            )

            metrics.append("# HELP frigate_events_total_today Total events today")
            metrics.append("# TYPE frigate_events_total_today gauge")
            metrics.append(f"frigate_events_total_today {total_today}")

            metrics.append("# HELP frigate_persons_today Total persons detected today")
            metrics.append("# TYPE frigate_persons_today gauge")
            metrics.append(f"frigate_persons_today {total_persons_today}")

            metrics.append("# HELP frigate_cars_today Total cars detected today")
            metrics.append("# TYPE frigate_cars_today gauge")
            metrics.append(f"frigate_cars_today {total_cars_today}")

            # Response
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.end_headers()
            self.wfile.write(("\n".join(metrics) + "\n").encode())

        except Exception as e:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(f"Error: {e}\n".encode())

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"Frigate exporter v2 running on :{PORT}")
    HTTPServer(("0.0.0.0", PORT), MetricsHandler).serve_forever()

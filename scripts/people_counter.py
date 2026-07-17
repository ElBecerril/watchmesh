#!/usr/bin/env python3
"""
People Counter - Contador de Personas para Análisis de Tráfico Peatonal

Consume eventos de persona de Frigate, almacena en SQLite,
expone métricas Prometheus y envía reportes por Telegram.

Diseñado para correr como servicio systemd en LXC 200.
"""

import base64
import calendar
import json
import logging
import os
import sqlite3
import sys
import threading
import time
from collections import defaultdict
from contextlib import closing
from datetime import datetime, timedelta
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import Request, urlopen
from urllib.error import URLError

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger(__name__)

# === CONFIGURACION ===
FRIGATE_URL = os.environ.get("FRIGATE_URL", "http://127.0.0.1:5000")
FRIGATE_USER = os.environ.get("FRIGATE_USER", "admin")
FRIGATE_PASS = os.environ.get("FRIGATE_PASS", "SET_FRIGATE_PASS_IN_ENV")
FRIGATE_AUTH = base64.b64encode(f"{FRIGATE_USER}:{FRIGATE_PASS}".encode()).decode()

TELEGRAM_TOKEN = os.environ.get("TELEGRAM_TOKEN", "SET_TELEGRAM_TOKEN_IN_ENV")
TELEGRAM_CHAT_ID = os.environ.get("TELEGRAM_CHAT_ID", "SET_TELEGRAM_CHAT_ID_IN_ENV")

DB_PATH = os.environ.get("DB_PATH", "/opt/vigilancia/people_counter.db")
METRICS_PORT = int(os.environ.get("METRICS_PORT", "9102"))
SYNC_INTERVAL = int(os.environ.get("SYNC_INTERVAL", "300"))  # 5 minutos
QUERY_LIMIT = 500

# Zonas configurables por cámara (None = todas las zonas cuentan)
CAMERA_ZONES = {
    "cam5_remota": ["zona_1", "banqueta"],
    "cam6_remota": ["banqueta", "estacionamiento"],
    "cam1_nvr": None,
    "cam2_nvr": None,
    "cam3_nvr": None,
    "cam4_icsee": None,
}

# Tracking de coches por zona (camera -> zonas donde contar coches)
CAR_ZONES = {
    "cam6_remota": ["estacionamiento", "calle_2"],
}

CAMERA_NAMES = {
    "cam1_nvr": "CAM1 Lugar 1",
    "cam2_nvr": "CAM2 Lugar 1",
    "cam3_nvr": "CAM3 Lugar 1",
    "cam4_icsee": "CAM4 Lugar 1",
    "cam5_remota": "CAM5 Lugar 2",
    "cam6_remota": "CAM6 Lugar 2",
}

# Deduplicacion: cam1-3 apuntan a la misma calle, tomar solo el max
DEDUP_GROUPS = {
    "Calle Lugar 1": ["cam1_nvr", "cam2_nvr", "cam3_nvr"],
}

DAILY_REPORT_HOUR = 23
WEEKLY_REPORT_HOUR = 22
WEEKLY_REPORT_DAY = 6  # domingo


# === BASE DE DATOS ===

def db_connect():
    """Conexión SQLite con timeout para tolerar locks de escritura concurrente
    entre el thread de sync, el de métricas y el scheduler (BUG-4)."""
    return sqlite3.connect(DB_PATH, timeout=10)


def init_db():
    conn = db_connect()
    conn.execute("PRAGMA journal_mode=WAL")   # lecturas concurrentes con escritura
    conn.execute("PRAGMA busy_timeout=10000")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS person_events (
            event_id TEXT PRIMARY KEY,
            camera TEXT NOT NULL,
            start_time REAL NOT NULL,
            zones TEXT,
            score REAL,
            date TEXT NOT NULL,
            hour INTEGER NOT NULL,
            label TEXT NOT NULL DEFAULT 'person'
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_date_camera ON person_events(date, camera)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_date ON person_events(date)")
    # Migrate: add label column if missing
    try:
        conn.execute("ALTER TABLE person_events ADD COLUMN label TEXT NOT NULL DEFAULT 'person'")
        log.info("Migrated DB: added label column")
    except sqlite3.OperationalError:
        pass  # column already exists
    conn.execute("CREATE INDEX IF NOT EXISTS idx_label ON person_events(date, label)")
    conn.commit()
    conn.close()
    log.info(f"Database initialized: {DB_PATH}")


def query_count(date_from, date_to=None, camera=None, label="person"):
    """Cuenta eventos en rango de fechas."""
    sql = "SELECT COUNT(*) FROM person_events WHERE date >= ? AND label = ?"
    params = [date_from, label]
    if date_to:
        sql += " AND date <= ?"
        params.append(date_to)
    if camera:
        sql += " AND camera = ?"
        params.append(camera)
    with closing(db_connect()) as conn:
        return conn.execute(sql, params).fetchone()[0]


def query_by_hour(date_str, camera=None, label="person"):
    """Conteo por hora para una fecha."""
    sql = "SELECT hour, COUNT(*) FROM person_events WHERE date = ? AND label = ?"
    params = [date_str, label]
    if camera:
        sql += " AND camera = ?"
        params.append(camera)
    sql += " GROUP BY hour ORDER BY hour"
    with closing(db_connect()) as conn:
        rows = conn.execute(sql, params).fetchall()
    return dict(rows)


def query_by_camera(date_str, label="person"):
    """Conteo por cámara para una fecha."""
    with closing(db_connect()) as conn:
        rows = conn.execute(
            "SELECT camera, COUNT(*) FROM person_events WHERE date = ? AND label = ? GROUP BY camera ORDER BY COUNT(*) DESC",
            (date_str, label),
        ).fetchall()
    return dict(rows)


def query_daily_totals(days=30):
    """Totales diarios de los últimos N días."""
    since = (datetime.now() - timedelta(days=days)).strftime("%Y-%m-%d")
    with closing(db_connect()) as conn:
        rows = conn.execute(
            "SELECT date, COUNT(*) FROM person_events WHERE date >= ? AND label = 'person' GROUP BY date ORDER BY date",
            (since,),
        ).fetchall()
    return dict(rows)


def query_by_zone(date_str, camera=None):
    """Conteo por zona para una fecha. Parsea JSON zones y cuenta por zona individual."""
    sql = "SELECT zones FROM person_events WHERE date = ? AND label = 'person'"
    params = [date_str]
    if camera:
        sql += " AND camera = ?"
        params.append(camera)
    with closing(db_connect()) as conn:
        rows = conn.execute(sql, params).fetchall()
    zone_counts = defaultdict(int)
    for (zones_json,) in rows:
        try:
            zones = json.loads(zones_json) if zones_json else []
        except (json.JSONDecodeError, TypeError):
            continue
        for z in zones:
            zone_counts[z] += 1
    return dict(zone_counts)


def query_cars(date_str, camera=None):
    """Conteo de coches para una fecha."""
    sql = "SELECT COUNT(*) FROM person_events WHERE date = ? AND label = 'car'"
    params = [date_str]
    if camera:
        sql += " AND camera = ?"
        params.append(camera)
    with closing(db_connect()) as conn:
        return conn.execute(sql, params).fetchone()[0]


def query_cars_by_hour(date_str, camera=None):
    """Conteo de coches por hora."""
    sql = "SELECT hour, COUNT(*) FROM person_events WHERE date = ? AND label = 'car'"
    params = [date_str]
    if camera:
        sql += " AND camera = ?"
        params.append(camera)
    sql += " GROUP BY hour ORDER BY hour"
    with closing(db_connect()) as conn:
        rows = conn.execute(sql, params).fetchall()
    return dict(rows)


def _dedup_range_total(date_from, date_to):
    """Total deduplicado para un rango de fechas: suma por dia del dedup, no suma global raw."""
    with closing(db_connect()) as conn:
        rows = conn.execute(
            "SELECT date, camera, COUNT(*) FROM person_events "
            "WHERE date >= ? AND date <= ? AND label = 'person' "
            "GROUP BY date, camera",
            (date_from, date_to),
        ).fetchall()
    daily = defaultdict(dict)
    for date_str, cam, count in rows:
        daily[date_str][cam] = count
    total = 0
    for date_str, by_cam in daily.items():
        deduped = dedup_by_camera(by_cam)
        total += sum(deduped.values())
    return total


def dedup_by_camera(by_camera):
    """Deduplica conteos de camaras que apuntan a la misma area.
    Para cada grupo, toma el max en lugar de sumar (misma persona vista por varias cams).
    Retorna dict con grupos colapsados y camaras individuales."""
    result = {}
    grouped_cams = set()
    for group_name, cams in DEDUP_GROUPS.items():
        group_counts = {c: by_camera.get(c, 0) for c in cams}
        max_count = max(group_counts.values()) if group_counts else 0
        if max_count > 0:
            result[group_name] = max_count
        grouped_cams.update(cams)
    for cam, count in by_camera.items():
        if cam not in grouped_cams:
            result[cam] = count
    return result


# === FRIGATE API ===

def frigate_get(path):
    try:
        req = Request(f"{FRIGATE_URL}{path}")
        req.add_header("Authorization", f"Basic {FRIGATE_AUTH}")
        with urlopen(req, timeout=15) as r:
            return json.loads(r.read())
    except (URLError, OSError, json.JSONDecodeError) as e:
        log.error(f"Frigate API error: {e}")
        return None


def get_last_sync_time():
    """Obtiene el start_time más reciente en la DB."""
    with closing(db_connect()) as conn:
        row = conn.execute("SELECT MAX(start_time) FROM person_events").fetchone()
    if row and row[0]:
        return row[0]
    # Primera ejecución: sincronizar últimas 24h
    return time.time() - 86400


def sync_events():
    """Sincroniza eventos de persona y coches desde Frigate a SQLite."""
    last_sync = get_last_sync_time()
    after = last_sync - 60

    total_new = 0

    # Sync person events
    total_new += _sync_label_events("person", CAMERA_ZONES, after)

    # Sync car events
    total_new += _sync_label_events("car", CAR_ZONES, after)

    return total_new


def _sync_label_events(label, zone_config, after):
    """Sincroniza eventos de un label específico desde Frigate."""
    events_raw = frigate_get(f"/api/events?after={after}&limit={QUERY_LIMIT}&label={label}")
    if events_raw is None:
        log.warning(f"Failed to fetch {label} events from Frigate")
        return 0

    events_to_insert = []
    for ev in events_raw:
        camera = ev.get("camera", "")
        if camera not in zone_config:
            continue

        allowed_zones = zone_config.get(camera)
        if allowed_zones is not None:
            event_zones = ev.get("zones", [])
            if not any(z in allowed_zones for z in event_zones):
                continue

        st = ev.get("start_time", 0)
        if st <= 0:
            continue

        dt = datetime.fromtimestamp(st)
        events_to_insert.append({
            "event_id": ev["id"],
            "camera": camera,
            "start_time": st,
            "zones": ev.get("zones", []),
            "score": ev.get("top_score", 0),
            "date": dt.strftime("%Y-%m-%d"),
            "hour": dt.hour,
            "label": label,
        })

    if not events_to_insert:
        return 0

    new_count = 0
    with closing(db_connect()) as conn:
        cursor = conn.cursor()
        for e in events_to_insert:
            cursor.execute(
                "INSERT OR IGNORE INTO person_events (event_id, camera, start_time, zones, score, date, hour, label) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (e["event_id"], e["camera"], e["start_time"],
                 json.dumps(e["zones"]), e["score"], e["date"], e["hour"], e["label"]),
            )
            new_count += cursor.rowcount
        conn.commit()
    if new_count > 0:
        log.info(f"Synced {new_count} new {label} events")
    return new_count


# === TELEGRAM ===

def send_telegram(text):
    """Envía mensaje por Telegram."""
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"
    data = json.dumps({
        "chat_id": TELEGRAM_CHAT_ID,
        "text": text,
        "parse_mode": "HTML",
    }).encode()
    try:
        req = Request(url, data=data, headers={"Content-Type": "application/json"})
        with urlopen(req, timeout=10) as r:
            return r.status == 200
    except (URLError, OSError) as e:
        log.error(f"Telegram send failed: {e}")
        return False


def generate_daily_report(date_str=None):
    """Genera reporte diario de personas."""
    if date_str is None:
        date_str = datetime.now().strftime("%Y-%m-%d")

    yesterday = (datetime.strptime(date_str, "%Y-%m-%d") - timedelta(days=1)).strftime("%Y-%m-%d")

    by_camera_raw = query_by_camera(date_str)
    by_camera = dedup_by_camera(by_camera_raw)
    by_hour = query_by_hour(date_str)
    total_today = sum(by_camera.values())

    # Ayer tambien deduplicado
    yesterday_raw = query_by_camera(yesterday)
    yesterday_dedup = dedup_by_camera(yesterday_raw)
    total_yesterday = sum(yesterday_dedup.values())

    lines = [
        f"<b>Contador de Personas - {date_str}</b>",
        "",
        f"Total: <b>{total_today}</b> personas",
    ]

    # Comparativa con ayer
    if total_yesterday > 0:
        diff = total_today - total_yesterday
        pct = (diff / total_yesterday) * 100
        arrow = "+" if diff >= 0 else ""
        lines.append(f"vs ayer: {arrow}{diff} ({arrow}{pct:.0f}%)")
    elif total_yesterday == 0 and total_today > 0:
        lines.append("vs ayer: sin datos")

    # Por cámara (deduplicado)
    if by_camera:
        lines.append("")
        lines.append("<b>Por ubicacion:</b>")
        for cam, count in sorted(by_camera.items(), key=lambda x: -x[1]):
            name = CAMERA_NAMES.get(cam, cam)
            lines.append(f"  {name}: <b>{count}</b>")

    # Horas pico
    if by_hour:
        peak = sorted(by_hour.items(), key=lambda x: -x[1])[:3]
        lines.append("")
        lines.append("<b>Horas pico:</b>")
        for h, c in peak:
            lines.append(f"  {h:02d}:00 - {c} personas")

    # Desglose por zona (Lugar 2)
    for cam in ["cam5_remota", "cam6_remota"]:
        zones = query_by_zone(date_str, cam)
        if zones:
            cam_name = CAMERA_NAMES.get(cam, cam)
            lines.append("")
            lines.append(f"<b>{cam_name} por zona:</b>")
            for z, c in sorted(zones.items(), key=lambda x: -x[1]):
                lines.append(f"  {z}: {c}")

    # Coches estacionamiento
    cars_total = query_cars(date_str)
    if cars_total > 0:
        lines.append("")
        lines.append(f"<b>Coches detectados:</b> {cars_total}")
        cars_hour = query_cars_by_hour(date_str, "cam6_remota")
        if cars_hour:
            peak_car = sorted(cars_hour.items(), key=lambda x: -x[1])[:3]
            for h, c in peak_car:
                lines.append(f"  {h:02d}:00 - {c} coches")

    return "\n".join(lines)


def generate_weekly_report():
    """Genera reporte semanal."""
    today = datetime.now()
    week_start = today - timedelta(days=today.weekday())
    week_end = today
    prev_week_start = week_start - timedelta(days=7)
    prev_week_end = week_start - timedelta(days=1)

    ws = week_start.strftime("%Y-%m-%d")
    we = week_end.strftime("%Y-%m-%d")
    pws = prev_week_start.strftime("%Y-%m-%d")
    pwe = prev_week_end.strftime("%Y-%m-%d")

    total_this = _dedup_range_total(ws, we)
    total_prev = _dedup_range_total(pws, pwe)

    days_elapsed = (today - week_start).days + 1
    avg_daily = total_this / days_elapsed if days_elapsed > 0 else 0

    lines = [
        f"<b>Reporte Semanal - {ws} a {we}</b>",
        "",
        f"Total semana: <b>{total_this}</b> personas",
        f"Promedio diario: <b>{avg_daily:.0f}</b>",
    ]

    if total_prev > 0:
        diff = total_this - total_prev
        pct = (diff / total_prev) * 100
        arrow = "+" if diff >= 0 else ""
        lines.append(f"vs semana anterior: {arrow}{diff} ({arrow}{pct:.0f}%)")

    # Mejor y peor día
    daily = query_daily_totals(7)
    if daily:
        best = max(daily.items(), key=lambda x: x[1])
        worst = min(daily.items(), key=lambda x: x[1])
        lines.append("")
        lines.append(f"Mejor dia: {best[0]} ({best[1]})")
        lines.append(f"Peor dia: {worst[0]} ({worst[1]})")

    # Por cámara acumulado (deduplicado)
    with closing(db_connect()) as conn:
        rows = conn.execute(
            "SELECT camera, COUNT(*) FROM person_events WHERE date >= ? AND date <= ? AND label = 'person' GROUP BY camera ORDER BY COUNT(*) DESC",
            (ws, we),
        ).fetchall()
    by_cam_week = dict(rows)
    deduped_week = dedup_by_camera(by_cam_week)
    if deduped_week:
        lines.append("")
        lines.append("<b>Por ubicacion:</b>")
        for cam, count in sorted(deduped_week.items(), key=lambda x: -x[1]):
            name = CAMERA_NAMES.get(cam, cam)
            lines.append(f"  {name}: <b>{count}</b>")

    return "\n".join(lines)


def generate_monthly_report():
    """Genera reporte mensual."""
    today = datetime.now()
    month_start = today.replace(day=1).strftime("%Y-%m-%d")
    month_end = today.strftime("%Y-%m-%d")

    # Mes anterior
    first_of_month = today.replace(day=1)
    prev_month_end = first_of_month - timedelta(days=1)
    prev_month_start = prev_month_end.replace(day=1)
    pms = prev_month_start.strftime("%Y-%m-%d")
    pme = prev_month_end.strftime("%Y-%m-%d")

    total_this = _dedup_range_total(month_start, month_end)
    total_prev = _dedup_range_total(pms, pme)

    days_elapsed = today.day
    avg_daily = total_this / days_elapsed if days_elapsed > 0 else 0

    lines = [
        f"<b>Reporte Mensual - {today.strftime('%B %Y')}</b>",
        "",
        f"Total mes: <b>{total_this}</b> personas",
        f"Promedio diario: <b>{avg_daily:.0f}</b>",
    ]

    if total_prev > 0:
        diff = total_this - total_prev
        pct = (diff / total_prev) * 100
        arrow = "+" if diff >= 0 else ""
        lines.append(f"vs mes anterior: {arrow}{diff} ({arrow}{pct:.0f}%)")

    return "\n".join(lines)


# === PROMETHEUS METRICS ===

class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return

        today = datetime.now().strftime("%Y-%m-%d")
        week_start = (datetime.now() - timedelta(days=datetime.now().weekday())).strftime("%Y-%m-%d")
        month_start = datetime.now().replace(day=1).strftime("%Y-%m-%d")

        lines = []
        lines.append("# HELP people_count_today Total persons detected today")
        lines.append("# TYPE people_count_today gauge")

        by_camera_today = query_by_camera(today)
        for cam in CAMERA_ZONES:
            count = by_camera_today.get(cam, 0)
            lines.append(f'people_count_today{{camera="{cam}"}} {count}')

        lines.append("# HELP people_count_total_today Total persons all cameras today (raw)")
        lines.append("# TYPE people_count_total_today gauge")
        lines.append(f"people_count_total_today {sum(by_camera_today.values())}")

        deduped = dedup_by_camera(by_camera_today)
        lines.append("# HELP people_count_dedup_today Total persons deduplicated today")
        lines.append("# TYPE people_count_dedup_today gauge")
        lines.append(f"people_count_dedup_today {sum(deduped.values())}")

        lines.append("# HELP people_count_by_hour Persons by hour today")
        lines.append("# TYPE people_count_by_hour gauge")
        by_hour = query_by_hour(today)
        for h in range(24):
            lines.append(f'people_count_by_hour{{hour="{h:02d}"}} {by_hour.get(h, 0)}')

        lines.append("# HELP people_count_week Total persons this week")
        lines.append("# TYPE people_count_week gauge")
        for cam in CAMERA_ZONES:
            count = query_count(week_start, today, cam)
            lines.append(f'people_count_week{{camera="{cam}"}} {count}')

        lines.append("# HELP people_count_month Total persons this month")
        lines.append("# TYPE people_count_month gauge")
        for cam in CAMERA_ZONES:
            count = query_count(month_start, today, cam)
            lines.append(f'people_count_month{{camera="{cam}"}} {count}')

        # Zone-level metrics for Lugar 2 cameras
        lines.append("# HELP people_count_by_zone Persons by zone today")
        lines.append("# TYPE people_count_by_zone gauge")
        for cam in ["cam5_remota", "cam6_remota"]:
            zones = query_by_zone(today, cam)
            for zone_name, count in zones.items():
                lines.append(f'people_count_by_zone{{camera="{cam}",zone="{zone_name}"}} {count}')

        # Car metrics
        lines.append("# HELP cars_count_today Cars detected today")
        lines.append("# TYPE cars_count_today gauge")
        for cam in CAR_ZONES:
            count = query_cars(today, cam)
            lines.append(f'cars_count_today{{camera="{cam}"}} {count}')

        lines.append("# HELP cars_count_by_hour Cars by hour today")
        lines.append("# TYPE cars_count_by_hour gauge")
        cars_by_hour = query_cars_by_hour(today, "cam6_remota")
        for h in range(24):
            lines.append(f'cars_count_by_hour{{hour="{h:02d}"}} {cars_by_hour.get(h, 0)}')

        body = "\n".join(lines) + "\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(body.encode())

    def log_message(self, format, *args):
        pass  # Suppress HTTP logs


def start_metrics_server():
    server = HTTPServer(("0.0.0.0", METRICS_PORT), MetricsHandler)
    log.info(f"Metrics server on :{METRICS_PORT}/metrics")
    server.serve_forever()


# === SCHEDULER ===

def report_scheduler():
    """Envía reportes programados."""
    last_daily = None
    last_weekly = None
    last_monthly = None

    while True:
        try:
            now = datetime.now()
            today_str = now.strftime("%Y-%m-%d")

            # Reporte diario a las 23:00
            if now.hour == DAILY_REPORT_HOUR and last_daily != today_str:
                report = generate_daily_report()
                if send_telegram(report):
                    log.info("Daily report sent")
                last_daily = today_str

            # Reporte semanal domingos a las 22:00
            if now.weekday() == WEEKLY_REPORT_DAY and now.hour == WEEKLY_REPORT_HOUR and last_weekly != today_str:
                report = generate_weekly_report()
                if send_telegram(report):
                    log.info("Weekly report sent")
                last_weekly = today_str

            # Reporte mensual último día del mes a las 22:00
            last_day = calendar.monthrange(now.year, now.month)[1]
            if now.day == last_day and now.hour == WEEKLY_REPORT_HOUR and last_monthly != today_str:
                report = generate_monthly_report()
                if send_telegram(report):
                    log.info("Monthly report sent")
                last_monthly = today_str

        except Exception as e:
            log.error(f"Scheduler error: {e}")

        time.sleep(30)


# === MAIN ===

def main():
    import argparse
    parser = argparse.ArgumentParser(description="People Counter")
    parser.add_argument("--report", choices=["daily", "weekly", "monthly"],
                        help="Generate and send a report immediately")
    args = parser.parse_args()

    init_db()

    # Modo reporte manual (generar UNA sola vez, no doble: BUG-10)
    if args.report:
        if args.report == "daily":
            report = generate_daily_report()
        elif args.report == "weekly":
            report = generate_weekly_report()
        else:  # monthly
            report = generate_monthly_report()
        print(report)
        send_telegram(report)
        return

    log.info("=" * 60)
    log.info("People Counter v2.1 starting (zones + cars + dedup cam1-3)")
    log.info(f"  Frigate: {FRIGATE_URL}")
    log.info(f"  DB: {DB_PATH}")
    log.info(f"  Metrics: :{METRICS_PORT}")
    log.info(f"  Sync interval: {SYNC_INTERVAL}s")
    log.info(f"  Cameras: {list(CAMERA_ZONES.keys())}")
    log.info("=" * 60)

    # Sincronización inicial
    sync_events()

    # Iniciar servidor de métricas en thread
    metrics_thread = threading.Thread(target=start_metrics_server, daemon=True)
    metrics_thread.start()

    # Iniciar scheduler de reportes en thread
    scheduler_thread = threading.Thread(target=report_scheduler, daemon=True)
    scheduler_thread.start()

    # Loop principal de sincronización
    while True:
        try:
            time.sleep(SYNC_INTERVAL)
            sync_events()
        except KeyboardInterrupt:
            log.info("Shutting down")
            break
        except Exception as e:
            log.error(f"Sync error: {e}")
            time.sleep(60)


if __name__ == "__main__":
    main()

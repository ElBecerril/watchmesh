#!/usr/bin/env python3
"""Agrega paneles de eventos al dashboard de Grafana."""

import json
import os
import base64
from urllib.request import Request, urlopen

GRAFANA_URL = os.environ.get("GRAFANA_URL", "http://127.0.0.1:3000")
_GRAFANA_USER = os.environ.get("GRAFANA_USER", "admin")
_GRAFANA_PASS = os.environ.get("GRAFANA_PASS", "SET_GRAFANA_PASS_IN_ENV")
AUTH = base64.b64encode(f"{_GRAFANA_USER}:{_GRAFANA_PASS}".encode()).decode()
DASHBOARD_UID = "f750c380-bc81-4525-a5ab-35720e0aedd6"


def grafana_get(path):
    req = Request(f"{GRAFANA_URL}{path}")
    req.add_header("Authorization", f"Basic {AUTH}")
    with urlopen(req, timeout=10) as r:
        return json.loads(r.read())


def grafana_post(path, data):
    body = json.dumps(data).encode()
    req = Request(f"{GRAFANA_URL}{path}", data=body, method="POST")
    req.add_header("Authorization", f"Basic {AUTH}")
    req.add_header("Content-Type", "application/json")
    with urlopen(req, timeout=10) as r:
        return json.loads(r.read())


# Obtener dashboard actual
result = grafana_get(f"/api/dashboards/uid/{DASHBOARD_UID}")
dashboard = result["dashboard"]
existing_panels = dashboard.get("panels", [])

print(f"Dashboard actual: {len(existing_panels)} paneles")

# Calcular siguiente ID
max_id = max(p.get("id", 0) for p in existing_panels)

# ===== NUEVOS PANELES =====

new_panels = [
    # --- Fila separadora: Detecciones ---
    {
        "id": max_id + 1,
        "type": "row",
        "title": "Detecciones y Eventos",
        "gridPos": {"h": 1, "w": 24, "x": 0, "y": 26},
        "collapsed": False,
    },
    # --- Stat: Personas Hoy ---
    {
        "id": max_id + 2,
        "type": "stat",
        "title": "Personas Hoy",
        "gridPos": {"h": 6, "w": 6, "x": 0, "y": 27},
        "targets": [
            {
                "expr": "frigate_persons_today",
                "instant": True,
                "legendFormat": "Personas",
                "refId": "A",
            }
        ],
        "fieldConfig": {
            "defaults": {
                "thresholds": {
                    "mode": "absolute",
                    "steps": [
                        {"color": "blue", "value": None},
                        {"color": "yellow", "value": 50},
                        {"color": "orange", "value": 100},
                        {"color": "red", "value": 200},
                    ],
                },
                "unit": "none",
            }
        },
        "options": {
            "colorMode": "background",
            "graphMode": "area",
            "textMode": "value",
        },
    },
    # --- Stat: Coches Hoy ---
    {
        "id": max_id + 3,
        "type": "stat",
        "title": "Coches Hoy",
        "gridPos": {"h": 6, "w": 6, "x": 6, "y": 27},
        "targets": [
            {
                "expr": "frigate_cars_today",
                "instant": True,
                "legendFormat": "Coches",
                "refId": "A",
            }
        ],
        "fieldConfig": {
            "defaults": {
                "thresholds": {
                    "mode": "absolute",
                    "steps": [
                        {"color": "blue", "value": None},
                        {"color": "yellow", "value": 200},
                        {"color": "orange", "value": 500},
                        {"color": "red", "value": 1000},
                    ],
                },
                "unit": "none",
            }
        },
        "options": {
            "colorMode": "background",
            "graphMode": "area",
            "textMode": "value",
        },
    },
    # --- Stat: Total Eventos Hoy ---
    {
        "id": max_id + 4,
        "type": "stat",
        "title": "Total Eventos Hoy",
        "gridPos": {"h": 6, "w": 6, "x": 12, "y": 27},
        "targets": [
            {
                "expr": "frigate_events_total_today",
                "instant": True,
                "legendFormat": "Total",
                "refId": "A",
            }
        ],
        "fieldConfig": {
            "defaults": {
                "thresholds": {
                    "mode": "absolute",
                    "steps": [
                        {"color": "green", "value": None},
                        {"color": "yellow", "value": 500},
                        {"color": "red", "value": 2000},
                    ],
                },
                "unit": "none",
            }
        },
        "options": {
            "colorMode": "background",
            "graphMode": "area",
            "textMode": "value",
        },
    },
    # --- Stat: Placas LPR Hoy ---
    {
        "id": max_id + 5,
        "type": "stat",
        "title": "Placas LPR Hoy",
        "gridPos": {"h": 6, "w": 6, "x": 18, "y": 27},
        "targets": [
            {
                "expr": 'sum(frigate_events_today{label="license_plate"}) or vector(0)',
                "instant": True,
                "legendFormat": "Placas",
                "refId": "A",
            }
        ],
        "fieldConfig": {
            "defaults": {
                "thresholds": {
                    "mode": "absolute",
                    "steps": [
                        {"color": "purple", "value": None},
                        {"color": "blue", "value": 5},
                        {"color": "green", "value": 20},
                    ],
                },
                "unit": "none",
            }
        },
        "options": {
            "colorMode": "background",
            "graphMode": "area",
            "textMode": "value",
        },
    },
    # --- Bar: Personas por Camara (hoy) ---
    {
        "id": max_id + 6,
        "type": "barchart",
        "title": "Personas por Camara (Hoy)",
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 33},
        "targets": [
            {
                "expr": 'frigate_events_today{label="person"}',
                "instant": True,
                "legendFormat": "{{camera}}",
                "refId": "A",
            }
        ],
        "fieldConfig": {
            "defaults": {
                "color": {"mode": "palette-classic"},
                "unit": "none",
            }
        },
        "options": {
            "orientation": "horizontal",
            "showValue": "always",
            "xTickLabelRotation": 0,
            "barWidth": 0.8,
        },
    },
    # --- Bar: Eventos por Tipo (hoy) ---
    {
        "id": max_id + 7,
        "type": "barchart",
        "title": "Eventos por Tipo (Hoy)",
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": 33},
        "targets": [
            {
                "expr": 'sum by (label) (frigate_events_today)',
                "instant": True,
                "legendFormat": "{{label}}",
                "refId": "A",
            }
        ],
        "fieldConfig": {
            "defaults": {
                "color": {"mode": "palette-classic"},
                "unit": "none",
            }
        },
        "options": {
            "orientation": "horizontal",
            "showValue": "always",
            "barWidth": 0.8,
        },
    },
    # --- Timeseries: Personas detectadas (historico) ---
    {
        "id": max_id + 8,
        "type": "timeseries",
        "title": "Personas Detectadas (Tendencia)",
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 41},
        "targets": [
            {
                "expr": 'frigate_events_today{label="person"}',
                "legendFormat": "{{camera}}",
                "refId": "A",
            }
        ],
        "fieldConfig": {
            "defaults": {
                "color": {"mode": "palette-classic"},
                "custom": {
                    "fillOpacity": 20,
                    "lineWidth": 2,
                    "stacking": {"mode": "normal"},
                },
                "unit": "none",
            }
        },
    },
    # --- Timeseries: Total eventos (historico) ---
    {
        "id": max_id + 9,
        "type": "timeseries",
        "title": "Total Eventos (Tendencia)",
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": 41},
        "targets": [
            {
                "expr": "frigate_events_total_today",
                "legendFormat": "Total",
                "refId": "A",
            },
            {
                "expr": "frigate_persons_today",
                "legendFormat": "Personas",
                "refId": "B",
            },
            {
                "expr": "frigate_cars_today",
                "legendFormat": "Coches",
                "refId": "C",
            },
        ],
        "fieldConfig": {
            "defaults": {
                "color": {"mode": "palette-classic"},
                "custom": {
                    "fillOpacity": 10,
                    "lineWidth": 2,
                },
                "unit": "none",
            }
        },
    },
    # --- Stat: Eventos Activos Ahora ---
    {
        "id": max_id + 10,
        "type": "stat",
        "title": "Eventos Activos Ahora",
        "gridPos": {"h": 6, "w": 24, "x": 0, "y": 49},
        "targets": [
            {
                "expr": "frigate_events_active",
                "instant": True,
                "legendFormat": "{{camera}} - {{label}}",
                "refId": "A",
            }
        ],
        "fieldConfig": {
            "defaults": {
                "thresholds": {
                    "mode": "absolute",
                    "steps": [
                        {"color": "green", "value": None},
                        {"color": "yellow", "value": 2},
                        {"color": "red", "value": 5},
                    ],
                },
                "unit": "none",
            }
        },
        "options": {
            "colorMode": "background",
            "graphMode": "none",
            "textMode": "value_and_name",
        },
    },
]

# Agregar paneles al dashboard
dashboard["panels"] = existing_panels + new_panels
dashboard["version"] += 1

# Guardar
payload = {
    "dashboard": dashboard,
    "overwrite": True,
}

result = grafana_post("/api/dashboards/db", payload)
print(f"Dashboard actualizado: {result.get('status', 'OK')}")
print(f"URL: {result.get('url', '?')}")
print(f"Total paneles: {len(dashboard['panels'])}")

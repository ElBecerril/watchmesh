# BIBLIA DEL PROYECTO - Sistema de Videovigilancia Hibrido

**Version:** v5.6.2
**Ultima actualizacion:** sesion s3 — primer deploy supervisado (capa de resiliencia/backup)

> **Estado v5.6.2:** operativo 5/6 camaras (cam6_remota forzada OFF, fallo fisico).
> Esta version añade la **capa de resiliencia desplegada**: backup diario real a pve (RES-2),
> migracion de crons a systemd-timers Persistent (RES-9), y el modelo de secretos por
> `EnvironmentFile` (SEC-7). Ver **seccion 21**. Esta biblia es la referencia tecnica completa
> de la version publica.

---

## INDICE

1. [Arquitectura General](#1-arquitectura-general)
2. [Hardware](#2-hardware)
3. [Red y Conectividad](#3-red-y-conectividad)
4. [Camaras](#4-camaras)
5. [Software y Servicios](#5-software-y-servicios)
6. [Frigate - Configuracion Completa](#6-frigate---configuracion-completa)
7. [Bot Telegram](#7-bot-telegram)
8. [Monitoring (Grafana + Prometheus)](#8-monitoring-grafana--prometheus)
9. [Display RPi5 (Visor Matriz)](#9-display-rpi5-visor-matriz)
10. [Rutas y Archivos en Servidor](#10-rutas-y-archivos-en-servidor)
11. [Credenciales](#11-credenciales)
12. [Comandos Utiles](#12-comandos-utiles)
13. [Cambio de Red](#13-cambio-de-red)
14. [Problemas Conocidos y Soluciones](#14-problemas-conocidos-y-soluciones)
15. [Lecciones Aprendidas](#15-lecciones-aprendidas)
16. [Historial de cierres y Roadmap](#16-historial-de-cierres-y-roadmap)
17. [Historial de Versiones](#17-historial-de-versiones)
18. [Auditoria de Calidad y Buenas Practicas](#18-auditoria-de-calidad-y-buenas-practicas)
19. [Contador de Personas - Analisis de Trafico Peatonal](#19-contador-de-personas---analisis-de-trafico-peatonal)
20. [Emergency Watchdog - Deteccion de Fallos en Cascada](#20-emergency-watchdog---deteccion-de-fallos-en-cascada)
21. [Resiliencia, Backup y Recuperacion de Desastres](#21-resiliencia-backup-y-recuperacion-de-desastres)

---

## 1. ARQUITECTURA GENERAL

### Diagrama

```
                         TAILSCALE VPN MESH
                               |
        +----------------------+----------------------+
        |                      |                      |
   LUGAR1 (LAN)              LUGAR1 (LAN)              LUGAR2
   192.0.2.x            192.0.2.x           198.51.100.x
        |                      |                      |
+-------+-------+      +------+------+        +------+------+
|    PROXMOX-LUGAR1      |      |   NVR Dahua  |       | proxy-lugar2  |
|  Proxmox .10   |      |    .40      |       | Proxy RTSP  |
|                |      | CAM1-4       |       | CAM5-6      |
| LXC 200 .20  |      +--------------+       | :5541/:5542 |
| Frigate+go2rtc |                             +-------------+
| Coral USB TPU  |                                    |
| Grafana+Prom   |                              (Tailscale)
| Bot Telegram   |                                    |
| face_bridge    |                                    |
+-------+--------+                              Go2rtc consume
        |                                       via 100.64.10.3
   RTSP restream -----> +-------------+
   :8554/camX           |    RPi5     |
        |               | mpv 3x2     |
   (Tailscale)          | Display     |
        |               +-------------+
+-------+--------+
| SERVIDOR PROXMOX|
| 100.64.10.6 |
|                 |
| VM 110          |
| InsightFace API |
| :5050           |
| (face recog)    |
+-----------------+
```

> ⚠️ **El bloque SERVIDOR PROXMOX / VM 110 / InsightFace del diagrama es HISTORICO.** La VM110 fue
> **borrada** y el servidor pve reutilizado; el face recognition esta muerto a nivel
> HW. El servidor pve sigue en el mesh y hoy cumple OTRO rol: **destino del backup diario** (RES-2,
> seccion 21). El `face_bridge` en el LXC esta desactivado.

### Flujo de datos

```
Camaras (NVR/ICSee) --> go2rtc (UNICO consumidor RTSP)
                              |
                              +--> Frigate + Coral TPU (deteccion IA)
                              |         |
                              |         +--> MQTT --> Bot Telegram (@tu_bot_de_telegram)
                              |         +--> MQTT --> face_bridge --> VM 110 InsightFace (face recog)
                              |         |                              (sub_label update)
                              |         +--> Prometheus --> Grafana (monitoring)
                              |
                              +--> RTSP Restream :8554 --> RPi5 mpv (display 3x2)
```

### Principio clave
**go2rtc es el UNICO consumidor RTSP** de todas las camaras. Las camaras ICSee solo soportan 1-2 conexiones RTSP simultaneas. Todo pasa por go2rtc y de ahi se redistribuye.

---

## 2. HARDWARE

### proxmox-lugar1 - Mini PC (Cerebro IA)

| Especificacion | Valor |
|---|---|
| CPU | Intel N95 (4 cores, hasta 3.4 GHz) |
| RAM | 16 GB DDR4 |
| Disco | 476 GB SSD |
| GPU | Intel integrada (VAAPI - iHD driver) |
| SO | Proxmox VE 8.4.17 (Debian 12, kernel 6.8.12-19-pve) |
| Rol | Host Proxmox con LXC 200 "vigilancia" |
| Ubicacion | Lugar 1 |

### Google Coral USB TPU

| Especificacion | Valor |
|---|---|
| Modelo | Coral USB Accelerator (via powered USB hub) |
| USB ID | `18d1:9302 Google Inc.` (runtime mode) |
| Velocidad inferencia | ~25ms por frame |
| Capacidad | ~40 inferencias/segundo |
| Uso actual | ~55% con 6 camaras a 3fps |
| Margen | ~45% para picos |
| Nota | Siempre procesa a 320x320 independiente de la resolucion detect |
| Observacion | ~5 USB resets/dia (estable, sin impacto). autosuspend DESACTIVADO via udev rule (v4.8) |

### Raspberry Pi 5

| Especificacion | Valor |
|---|---|
| RAM | 4 GB |
| SO | Raspberry Pi OS |
| Rol | Display mpv matriz 3x2 (solo visualizacion) |
| Conexion | eth0 192.0.2.51 (activa) / wlan0 192.0.2.52 (WiFi) |
| Consume | Streams restreameados de go2rtc |

### NVR Dahua

| Especificacion | Valor |
|---|---|
| Canales | 4 (cam1-cam4) |
| IP | 192.0.2.40 |
| Mainstream | 960x1080 HEVC (subtype=0) |
| Substream | 352x240 (subtype=1) |

### Servidor Proxmox (Face Recognition Remoto)

| Especificacion | Valor |
|---|---|
| CPU | Dual Xeon E5-2680 v2 (40 hilos, 28 libres) |
| RAM | 128 GB (102 GB libre) |
| IP Tailscale | 100.64.10.6 |
| SO | Proxmox VE |
| Rol | Servidor dedicado para face recognition (InsightFace) |

#### VM 110 "face-recognition"

> ⚠️ **DESMANTELADA.** La VM110 ya NO existe: el archivo `110.conf` fue
> borrado del servidor pve y el hardware se reutilizó para otros proyectos (ollama-ai,
> kali-pentest, defectdojo, etc.). Tailscale no la ve hace meses. El face recognition
> está **muerto a nivel HW**, no solo desactivado por software — para retomarlo habría
> que reconstruir la VM desde cero. Toda la sección siguiente es **histórica**.

| Especificacion | Valor |
|---|---|
| OS | Ubuntu 24.04 Server (cloud-init) |
| CPU | 8 cores |
| RAM | 8 GB |
| Disco | 50 GB (falcon-nvme) |
| IP local | 198.51.100.50 (**estatica** - netplan, cloud-init deshabilitado) |
| IP Tailscale | 100.64.10.5 |
| Puerto | 5050 |
| Servicio | Docker + FastAPI + InsightFace buffalo_l (ArcFace R100) |
| Rendimiento | ~240-480ms por cara (CPU-only, Ivy Bridge AVX sin AVX2) |
| GPU | No asignada (1080 Ti en VM 101) |

### PC proxy-lugar2 (Proxy Lugar 2)

| Especificacion | Valor |
|---|---|
| SO | Zorin OS |
| Rol | Gateway/Proxy RTSP para cam5 y cam6 del Lugar 2 |
| Puertos | 5541 (cam5), 5542 (cam6) |
| Conexion | Tailscale VPN |

---

## 3. RED Y CONECTIVIDAD

### Ubicacion LUGAR1

| Dispositivo | IP Local | IP Tailscale |
|---|---|---|
| Router | 192.0.2.1 | - |
| proxmox-lugar1 (host Proxmox) | 192.0.2.10 | 100.64.10.2 |
| LXC 200 (vigilancia) | 192.0.2.20 | - (usa NAT del host) |
| NVR Dahua | 192.0.2.40 | - |
| RPi5 | 192.0.2.51 (eth0) / .52 (wlan0) | 100.64.10.1 |
| PC Windows | - | 100.64.10.4 |
| Servidor Proxmox (face-recog) | - | 100.64.10.6 |
| VM 110 (face-recognition) | 198.51.100.50 | 100.64.10.5 |

### Ubicacion LUGAR2

| Dispositivo | IP Local | IP Tailscale |
|---|---|---|
| Router | 198.51.100.254 | - |
| proxy-lugar2 | 198.51.100.63 | 100.64.10.3 |
| CAM5 (ICSee) | 198.51.100.30 | - |
| CAM6 (ICSee) | 198.51.100.40 | - |

### LXC 200 -> Tailscale (acceso a proxy-lugar2)

El LXC 200 no tiene Tailscale propio. Accede a peers via NAT en el host Proxmox:

- **IP forwarding**: `/etc/sysctl.d/99-ip-forward.conf` (`net.ipv4.ip_forward=1`)
- **NAT masquerade**: servicio systemd `nat-tailscale.service` en host Proxmox
- **Ruta en LXC**: `100.64.0.0/10 via 192.0.2.10` en `/etc/network/if-up.d/tailscale-route`

#### NAT Tailscale persistente (v4.6)

Resuelto con servicio systemd que espera hasta 60s a que `tailscale0` exista antes de aplicar la regla iptables:

- Archivo: `/etc/systemd/system/nat-tailscale.service`
- Usa `-C` (check) para evitar reglas duplicadas
- Habilitado para arranque automatico (`multi-user.target`)
- Resuelve el problema de v4.5 donde la regla se perdia al reiniciar (vmbr0 sube antes que tailscale0)

### Puertos expuestos en LXC 200

| Puerto | Servicio | Protocolo |
|---|---|---|
| 5000 | Frigate Web UI | HTTP |
| 8554 | go2rtc RTSP restream | RTSP |
| 8555 | go2rtc WebRTC | TCP/UDP |
| 1984 | go2rtc API | HTTP |
| 1883 | Mosquitto MQTT | MQTT |
| 3000 | Grafana | HTTP |
| 9090 | Prometheus | HTTP |
| 9101 | Frigate Exporter | HTTP |

### Puertos en VM 110

| Puerto | Servicio | Protocolo |
|---|---|---|
| 5050 | InsightFace API (FastAPI) | HTTP |
| 22 | SSH | TCP |

---

## 4. CAMARAS

### Tabla completa

| ID Frigate | Tipo | Ubicacion | Detect (resolucion) | Record (resolucion) | HW Accel | FPS | Features |
|---|---|---|---|---|---|---|---|
| cam1_nvr | Dahua Bullet | Lugar 1 | 480x540 (substream) | 960x1080 HEVC (mainstream) | VAAPI | 3 | dual stream |
| cam2_nvr | Dahua Bullet | Lugar 1 | 480x540 (substream) | 960x1080 HEVC (mainstream) | VAAPI | 3 | dual stream |
| cam3_nvr | Dahua Bullet | Lugar 1 | 480x540 (substream) | 960x1080 HEVC (mainstream) | VAAPI | 3 | dual stream |
| cam4_icsee | ICSee dual lens | Lugar 1 | 800x448 | 2560x1440 H.264 | Software | 3 | single stream (ICSee no soporta 2 RTSP) |
| cam5_remota | ICSee dual lens | Lugar 2 | 800x448 | 2560x1440 HEVC | Software | 3 | dual stream |
| cam6_remota | ICSee dual lens | Lugar 2 | 800x448 | 2560x1440 HEVC | Software | 3 | dual stream |
| cam6_face | Segundo lente cam6 zoom | Lugar 2 | - | - | - | - | **DESACTIVADA** (rostros <40px, face-bridge off) |

> cam1-3 usan dual stream via go2rtc (v5.1): substream (480x540) para detect, mainstream (960x1080) para record. VAAPI (Intel iHD) para decode.
> cam4 usa single stream mainstream directo a ICSee 192.0.2.30 (v4.9/v5.1): ICSee NO soporta 2 conexiones RTSP simultaneas. Un solo stream para detect+record.
> cam5-6 usan dual stream via Tailscale. Software decode (VAAPI + ICSee HEVC = crashes).
> cam6_face desactivada (v5.1): face-bridge off, rostros demasiado pequenos (<40px).

### URLs RTSP (go2rtc)

```
# Substream (detect + display RPi5)
cam1:      rtsp://<USER>:<PASSWORD>@192.0.2.40:554/cam/realmonitor?channel=1&subtype=1
cam2:      rtsp://<USER>:<PASSWORD>@192.0.2.40:554/cam/realmonitor?channel=2&subtype=1
cam3:      rtsp://<USER>:<PASSWORD>@192.0.2.40:554/cam/realmonitor?channel=3&subtype=1
cam4:      rtsp://<USER>:<PASSWORD>@192.0.2.30:554/stream0
cam5:      rtsp://<USER>:<PASSWORD>@100.64.10.3:5541/ch0_1.h264
cam6:      rtsp://<USER>:<PASSWORD>@100.64.10.3:5542/ch0_1.h264

# Mainstream (record 2K)
cam1_main: rtsp://<USER>:<PASSWORD>@192.0.2.40:554/cam/realmonitor?channel=1&subtype=0
cam2_main: rtsp://<USER>:<PASSWORD>@192.0.2.40:554/cam/realmonitor?channel=2&subtype=0
cam3_main: rtsp://<USER>:<PASSWORD>@192.0.2.40:554/cam/realmonitor?channel=3&subtype=0
cam4_main: ELIMINADO (cam4 usa single stream mainstream para detect+record)
cam5_main: rtsp://<USER>:<PASSWORD>@100.64.10.3:5541/ch0_0.h264
cam6_main: rtsp://<USER>:<PASSWORD>@100.64.10.3:5542/ch0_0.h264

# Segundo lente (cam6_face - desactivado)
cam6_face: rtsp://<USER>:<PASSWORD>@100.64.10.3:5542/ch1_1.h264
```

### ICSee - Notas importantes

- **Dual lens**: lente 1 = gran angular, lente 2 = zoom cercano (ideal LPR)
- **cam5/cam6 soportan 2 conexiones RTSP simultaneas** (main + sub). cam4 NO soporta 2 RTSP simultaneas (descubierto v5.1)
- **URLs**: `ch0_0` = main 2K, `ch0_1` = sub, `ch1_0` = lente2 main, `ch1_1` = lente2 sub
- **Formato**: H.264 (cam4 local), HEVC (cam5/cam6 via Tailscale)
- **VAAPI incompatible**: HEVC de ICSee causa crashes con VAAPI (78 crashes/hora observados en v4.4), usar software decode

### NVR Dahua - Notas importantes

- `subtype=0` = mainstream (960x1080 HEVC) - mejor calidad
- `subtype=1` = substream (352x240) - menor calidad
- cam1-3 usan dual stream (v5.1): substream (subtype=1, 480x540) para detect, mainstream (subtype=0, 960x1080) para record. Antes usaban mainstream para ambos roles.

### Deteccion de objetos (8 objetos COCO)

Objetos rastreados: `person`, `car`, `motorcycle`, `bicycle`, `truck`, `bus`, `dog`, `cat`.

Cada uno lleva dos filtros en Frigate:

| Filtro | Que hace | Como ajustarlo |
|---|---|---|
| `min_score` | Confianza minima para aceptar la deteccion | Subirlo reduce falsos positivos y aumenta falsos negativos. Los objetos grandes y bien contrastados toleran valores altos; mascotas y objetos parciales necesitan valores mas bajos |
| `min_area` | Area minima en px del bounding box | Filtra detecciones lejanas o espurias. **Depende de la resolucion de `detect` y del encuadre**, asi que no es portable entre instalaciones |

> **Los valores concretos de este despliegue no se publican**: junto con la resolucion de
> detect describen exactamente el umbral a partir del cual el sistema deja de registrar algo.
> Calibra los tuyos con la vista de depuracion de Frigate sobre tus propios encuadres, y
> revisalos cada vez que cambies la resolucion de `detect`.

> Ampliado de 4 a 8 objetos en v4.6. motorcycle, bicycle, truck, bus agregados sin costo extra de Coral.

### Zonas configuradas

Cada camara define entre 3 y 5 **zonas** (poligonos donde un objeto detectado cuenta como
evento) y una o mas **mascaras de movimiento** (regiones ignoradas por el detector de
movimiento: normalmente el timestamp OSD y elementos que se mueven con el viento).

> El reparto concreto de zonas y mascaras depende por completo del encuadre de cada
> instalacion, y **describe el perimetro fisico del sitio**, asi que no se documenta aqui.
> Definelas en la UI de Frigate (Settings → Mask & Zone Editor) sobre tus propios encuadres.

Criterios utiles al definirlas:

- Una zona por area con **significado distinto de alerta** (p.ej. acceso propio vs via publica);
  eso permite filtrar notificaciones por zona en lugar de por camara entera.
- Enmascarar **siempre** el timestamp OSD: cambia cada segundo y dispara movimiento continuo.
- Enmascarar vegetacion y elementos oscilantes; ojo, una mascara de movimiento es un **punto
  ciego permanente**, asi que hazla lo mas pequena posible.
- Al cambiar la resolucion de `detect`, revisa las zonas: las coordenadas son normalizadas
  (0-1) y sobreviven al cambio, pero un cambio de **aspect ratio** deforma el poligono y
  conviene recalibrar.

---

## 5. SOFTWARE Y SERVICIOS

### Contenedor LXC 200 "vigilancia"

| Parametro | Valor |
|---|---|
| ID | 200 |
| Hostname | vigilancia |
| IP | 192.0.2.20 (estatica) |
| CPU | 4 cores (todo el N95) |
| RAM | **12 GB** (aumentado desde 8 GB, requiere restart LXC) |
| Disco | **200 GB** (expandido desde 50 GB) |
| Docker | 29.2.1 |
| Onboot | Si (arranca con Proxmox) |
| Privilegiado | Si (necesario para GPU + USB passthrough) |

### Servicios Docker (docker-compose.yml)

| Servicio | Imagen | Red | Persistencia |
|---|---|---|---|
| frigate | `ghcr.io/blakeblackshear/frigate:stable` | host | config, storage, tmpfs cache 256MB |
| prometheus | `prom/prometheus:v3.10.0 (pinned v5.1)` | host | prometheus_data (retencion 30d/2GB) |
| grafana | `grafana/grafana:12.4.0 (pinned v5.1)` | host | grafana_data, provisioning |

### Servicios systemd (en LXC 200)

| Servicio | Archivo | Descripcion |
|---|---|---|
| mosquitto | (paquete) | Broker MQTT en 127.0.0.1:1883 |
| telegram-bot | telegram_bot.py | Bot Telegram v4.2 securizado + face training |
| frigate-exporter | frigate_exporter.py | Exporter Prometheus v2 en puerto 9101 (limit=500) |
| face-bridge | face_bridge.py | Puente MQTT -> InsightFace API remoto (VM 110) - **DESACTIVADO v5.1** (0 reconocimientos exitosos) |
| people-counter | people_counter.py | Contador personas: SQLite + Prometheus :9102 + Telegram |

### Servicios en VM 110 (Servidor Proxmox)

| Servicio | Descripcion |
|---|---|
| Docker: face-recognition | InsightFace buffalo_l + FastAPI en puerto 5050 |

### Servicio systemd en host Proxmox

| Servicio | Archivo | Descripcion |
|---|---|---|
| nat-tailscale | /etc/systemd/system/nat-tailscale.service | NAT masquerade para LXC -> Tailscale (espera tailscale0) |
| emergency-watchdog | /etc/systemd/system/emergency-watchdog.service (en HOST proxmox-lugar1) | Watchdog v2.0: 8 checks, crash-loop por ffmpeg_pid + 0fps prolongado, MQTT, self-watchdog SIGALRM, restart Frigate por RSS, alerta por **doble canal ntfy + Telegram** (RES-8) |

### Versiones de software

| Software | Version |
|---|---|
| Frigate | 0.17.0-f0d69f7 |
| go2rtc (integrado) | 1.9.10 |
| Docker | 29.2.1 |
| Proxmox VE | 8.4.17 |
| Python | 3.x (en LXC) |
| Mosquitto | (version de Debian 12) |

---

## 6. FRIGATE - CONFIGURACION COMPLETA

### Deteccion

- **Detector**: Google Coral USB TPU (edgetpu)
- **Aceleracion video**: VAAPI (Intel iHD) solo para cam1-3 (Dahua). Software decode para cam4-6 (ICSee)
- **FPS deteccion**: 3 fps en todas las camaras
- **Objetos**: person, car, motorcycle, bicycle, truck, bus, dog, cat (8 objetos COCO)
- **Inferencia Coral**: siempre 320x320, independiente de la resolucion detect
- **CPU promedio Frigate**: ~15% (v5.2: Semantic Search off + optimizaciones previas). Host load ~0.7-1.5/4 cores
- **RAM Frigate**: crece progresivamente (~1GB/dia con crash-loops activos, ~300MB/dia sin ellos). Restart semanal programado. Watchdog v2.0 reduce restarts desactivando camaras en crash-loop

### Semantic Search (v4.6 - DESACTIVADO v5.2)

- **Estado**: **DESACTIVADO** desde v5.2
- **Modelo**: Jina CLIP v1 small
- **Motivo desactivacion**: embeddings_manager consumia 22.6% CPU (el proceso mas pesado de Frigate), procesando cada evento a ~414ms. Sin uso activo de busqueda por texto.
- **Ahorro**: CPU Frigate -50% (de 33% a 15%)
- **Re-habilitar**: Si se necesita busqueda por texto en Frigate UI, activar semantic_search.enabled: true

### Face Recognition (v4.7 - InsightFace Remoto)

- **Modo**: **REMOTO** - InsightFace en VM 110 (Servidor Proxmox) via Tailscale
- **Frigate builtin**: **DESACTIVADO** (face_recognition.enabled: false)
- **Modelo**: InsightFace buffalo_l (ArcFace R100), CPU-only
- **API**: http://100.64.10.5:5050 (FastAPI + ONNX Runtime)
- **Puente**: face_bridge.py en LXC 200 (systemd face-bridge.service)
- **Flujo**: Frigate detecta person -> MQTT -> face_bridge descarga snapshot -> POST /recognize a VM 110 -> actualiza sub_label en Frigate
- **Camaras**: Ninguna activa (antes: cam5_remota y cam6_remota)
- **Estado**: **DESACTIVADO** desde v5.1 (systemctl disable face-bridge)
- **Motivo**: 3160 llamadas API en 6h con 0 reconocimientos exitosos. Rostros <40px insuficientes.
- **Reactivar**: Cuando se entrenen rostros via /entrenar Y se mejore camara para face recog
- **Cooldown**: 30s por camara (evita saturar servidor)
- **Threshold reconocimiento**: 0.45
- **Rostros entrenados**: PERSONA1 (4 muestras, confidence 1.0 en test)
- **Rendimiento**: ~240-480ms por imagen, ~30s carga modelo al iniciar
- **Endpoints API**: POST /recognize, POST /train/{name}, GET /faces, DELETE /faces/{name}, GET /health
- **Autenticacion**: API key via header X-API-Key (key: <PASSWORD>). Endpoints /health y GET /faces son publicos.
- **Almacenamiento embeddings**: /data/faces en volumen Docker (face_data)
- **Ventaja sobre Frigate builtin**: modelo buffalo_l (ArcFace R100) vs small, mejor calidad de recortes, sin consumo CPU en proxmox-lugar1 N95

### GenAI (Gemini) - DESACTIVADO

- **Estado**: **DESACTIVADO** desde v4.5
- **Provider**: Google Gemini
- **Modelo**: gemini-2.5-flash-lite
- **API Key**: <PASSWORD>
- **Cuota real**: 20 RPD (NO 1000 como documenta Google)
- **Motivo desactivacion**: Tormenta de retries 429 (1311+ retries) causo deadlock de Frigate y cuelgue total del sistema
- **Re-habilitar**: Solo si se confirma cuota suficiente, con limites estrictos

### LPR (License Plate Recognition) - DESACTIVADO

- **Estado**: **DESACTIVADO** globalmente (enabled: false) desde v4.6
- **cam6_lpr**: desactivada (enabled: false)
- **Motivo**: OCR leia el timestamp OSD de la camara como placas
- **Ahorro**: ~13% CPU ffmpeg eliminado
- **Re-habilitar**: Cuando se resuelvan mascaras OSD

### Record y Snapshots

| Tipo | Retencion (global) | Override cam5/cam6 |
|---|---|---|
| Motion | 1 dia | 1 dia |
| Alerts | 2 dias (v5.2, antes 3d) | 1 dia |
| Detections | 1 dia (v5.2, antes 2d) | 1 dia |
| Continuous | 0 (desactivado) | - |
| Snapshots | 3 dias (v5.2, antes 7d) | - |

**Uso de disco**: ~42 GB/dia con 6 camaras a mainstream. sync_recordings habilitado. Disco estable ~49% (92GB/197GB) con retencion actual.

### MQTT

- **Host**: 127.0.0.1:1883 (Mosquitto local)
- **Topics usados**:
  - `frigate/events` - Eventos de deteccion (new/update/end)
  - `frigate/reviews` - Reviews con descripcion GenAI (cuando esta activo)

---

## 7. BOT TELEGRAM

### Informacion general

| Parametro | Valor |
|---|---|
| Bot | @tu_bot_de_telegram |
| Version | **v4.2 securizado + face training** |
| Archivo servidor | `/opt/vigilancia/telegram_bot.py` |
| Servicio | `telegram-bot.service` |
| Chat autorizado | <TELEGRAM_CHAT_ID> (configurable en AUTHORIZED_IDS) |

### Funciones

| Boton / Comando | Funcion |
|---|---|
| Estado / `/status` | Estado de camaras (fps, deteccion activa) |
| Resumen / `/resumen` | Resumen del dia (personas, coches, hora pico) |
| Ver camara / `/snap` | Snapshot en vivo (selector inline 6 cams + Todas) |
| Ultimas alertas / `/ultimas` | Ultimas 5 detecciones con snapshot |
| Sistema / `/stats` | CPU, Coral TPU, disco, temperatura, uptime |
| `/entrenar NOMBRE` | Registrar rostro (enviar foto despues) |
| `/rostros` | Listar rostros registrados y muestras |
| `/cancelar` | Cancelar entrenamiento en curso |
| `/help` o `/start` | Menu de ayuda |

### Alertas automaticas (via MQTT)

| Objeto | Comportamiento | Cooldown |
|---|---|---|
| person | Alerta inmediata con snapshot | 60s por camara |
| dog | Alerta inmediata con snapshot | 60s por camara |
| cat | Alerta inmediata con snapshot | 60s por camara |
| car | Solo si permanece detenido (`CAR_STATIONARY_THRESHOLD`) | `COOLDOWN_SECONDS` por camara |

### Resumen diario

- Se envia automaticamente una vez al dia (hora configurable con `DAILY_SUMMARY_HOUR`)
- Incluye: total personas/coches/animales, personas por camara, horas pico
- Thread con recovery automatico si falla

### Seguridad (v4.1)

- **Validacion de chat_id**: Solo AUTHORIZED_IDS pueden usar el bot
- Usuarios no autorizados son rechazados silenciosamente (mensaje) o con "No autorizado" (callback)
- Los intentos no autorizados se loguean
- Funciones compartidas `aggregate_events()` / `format_summary_lines()` refactorizadas
- Thread recovery mejorado

### Mejoras GenAI en alertas (cuando activo)

- `handle_review` enriquecido: foto + hora + objeto + zona + descripcion IA
- Solo procesa reviews con severity "alert"
- Incluye snapshot del primer detection del review

---

## 8. MONITORING (GRAFANA + PROMETHEUS)

### Prometheus

| Parametro | Valor |
|---|---|
| URL | http://192.0.2.20:9090 |
| Scrape interval | 30s |
| Retencion | 30 dias o 2 GB (lo que ocurra primero) |
| Target | localhost:9101 (frigate exporter) |

### Frigate Exporter v2

| Parametro | Valor |
|---|---|
| Puerto | 9101 |
| Limite eventos API | **500** (reducido desde 5000 en v4.6) |
| Cache TTL | 60 segundos |
| Motivo reduccion | 5000 eventos = ~627MB por ciclo, factor contribuyente al cuelgue v4.5 |

### Metricas exportadas (puerto 9101)

**Infraestructura:**
- `frigate_camera_fps{camera}` - FPS por camara
- `frigate_detection_fps{camera}` - FPS deteccion por camara
- `frigate_process_fps{camera}` - FPS proceso por camara
- `frigate_skipped_fps{camera}` - FPS saltados por camara
- `frigate_detection_enabled{camera}` - Deteccion habilitada (1/0)
- `frigate_detector_inference_ms{detector}` - Velocidad inferencia Coral
- `frigate_temperature_celsius{sensor}` - Temperaturas
- `frigate_storage_used_gb{path}` / `frigate_storage_total_gb{path}` - Disco
- `frigate_uptime_seconds` - Uptime Frigate

**Eventos:**
- `frigate_events_today{camera,label}` - Eventos hoy por camara y tipo
- `frigate_events_last_hour{camera,label}` - Eventos ultima hora
- `frigate_events_active{camera,label}` - Eventos activos ahora
- `frigate_events_total_today` - Total eventos hoy
- `frigate_persons_today` - Total personas hoy
- `frigate_cars_today` - Total coches hoy

### Grafana Dashboard

| Parametro | Valor |
|---|---|
| URL | http://192.0.2.20:3000 |
| Dashboard | "Frigate - Videovigilancia" |
| UID | f750c380-bc81-4525-a5ab-35720e0aedd6 |
| Total paneles | 30 |
| Grafana version | 12.4.0 (pinned) |
| Prometheus version | v3.10.0 (pinned) |

**Paneles (30):**

*Seccion Infraestructura:*
1-10. Camera FPS, Detection FPS, Skipped FPS, Inference Speed, Temperatures, Storage, Uptime, etc.

*Seccion Detecciones y Eventos:*
11. Personas Hoy (stat)
12. Coches Hoy (stat)
13. Total Eventos Hoy (stat)
14. Placas LPR Hoy (stat) - sin datos mientras LPR desactivado
15. Personas por Camara (barchart horizontal)
16. Eventos por Tipo (barchart horizontal)
17. Personas Detectadas Tendencia (timeseries apilado)
18. Total Eventos Tendencia (timeseries)
19. Eventos Activos Ahora (stat)
20. Fila separadora

*Seccion Metricas Lugar 2 (6 nuevos, v5.0):*
21-22. Personas por Zona (cam5/cam6)
23-24. Coches Estacionamiento
25-26. Tendencias 7 dias
27-30. People Counter paneles (personas hoy, semana, por hora, dedup)

---

## 9. DISPLAY RPi5 (VISOR MATRIZ)

### Script: matrix_camaras.sh

| Parametro | Valor |
|---|---|
| Archivo RPi5 | `/usr/local/bin/matrix_camaras.sh` |
| Servicio | `matrix-camaras.service` (Restart=always, RestartSec=10, User=pi, WantedBy=graphical.target) |
| Log | `/tmp/matrix_camaras.log` |
| Layout | 3x2 (1920x1080 total) |

> **Nota de version:** el repo conserva varios candidatos del visor
> (`matrix_camaras_v24/v25/v26.sh`). La version **desplegada en el RPi5 no se re-verifico** en la
> sesion de deploy s3 (el RPi5 requiere auth interactiva Tailscale). Ultimo estado confirmado en
> vivo: 5/6 mpv OK. Editar SIEMPRE en LF (CRLF de Windows rompe el script en el RPi5).

> IMPORTANTE: El script debe estar en `/usr/local/bin/`, NO en `/home/pi/` (causa duplicados de watchdog).

### Layout de pantalla

```
+----------+----------+----------+
|  CAM1    |  CAM2    |  CAM3    |
|  640x540 |  640x540 |  640x540 |
|  (0,0)   |  (640,0) | (1280,0) |
+----------+----------+----------+
|  CAM4    |  CAM6    |  CAM5    |
|  640x540 |  640x540 |  640x540 |
|  (0,540) | (640,540)|(1280,540)|
+----------+----------+----------+
```

### Fuente de streams

Todas via go2rtc restream: `rtsp://192.0.2.20:8554/camX`

### Watchdog features

- **Intervalo**: 30 segundos
- **Deteccion congelamiento**: CPU < 2.0% por 3 ciclos consecutivos
- **Backoff exponencial**: 1min (3+ fallos), 5min (6+), 15min (10+)
- **Reinicio periodico**: cada 4 horas
- **Ventana mantenimiento**: franja configurable (`MAINTENANCE_START`/`MAINTENANCE_END`); durante el reinicio programado del router se suprimen los checks
- **VPN check**: cada 2 minutos, auto-reinicia cam5/cam6 cuando VPN restaura
- **Limpieza huerfanos**: cada ciclo mata procesos mpv sin camara asignada
- **Limpieza duplicados**: detecta y mata procesos duplicados por camara (mantiene el mas reciente)
- **Recovery red**: reinicio total automatico al restaurarse la red local
- **SIGKILL fallback**: en start_camera, kill -9 tras SIGTERM para procesos stuck en I/O

### mpv argumentos

```bash
# Camaras normales
--vo=gpu --gpu-context=x11egl --profile=low-latency --untimed --rtsp-transport=tcp
--network-timeout=20 --no-border --no-osc --no-audio --force-window=immediate

# CAM4 (ICSee, mayor resolucion)
# Adicional: --cache=no --demuxer-max-bytes=2M --demuxer-readahead-secs=1
# --untimed es CRITICO: sin el, mpv sincroniza con reloj RTSP causando stalls
```

---

## 10. RUTAS Y ARCHIVOS EN SERVIDOR

### LXC 200 (/opt/vigilancia/)

```
/opt/vigilancia/
├── docker-compose.yml              # Frigate + Prometheus + Grafana
├── frigate_config/
│   └── config.yml                  # Config Frigate completa (6+1 camaras, zonas, etc) [directory mount since v5.0]
├── config/
│   ├── prometheus.yml              # Config Prometheus (scrape frigate exporter)
│   └── grafana/
│       └── provisioning/           # Provisioning datasources Grafana
├── storage/                        # Media Frigate (~92 GB usado de 197 GB, ~49%)
│   ├── recordings/                 # Grabaciones (~59 GB)
│   ├── clips/                      # Clips de eventos (~3 GB)
│   └── exports/                    # Exportaciones
├── prometheus_data/                # Datos Prometheus (max 2 GB)
├── grafana_data/                   # Datos Grafana
├── telegram_bot.py                 # Bot Telegram v4.2 securizado + face training
├── frigate_exporter.py             # Exporter Prometheus v2 (limit=500, puerto 9101)
├── face_bridge.py                  # Puente MQTT -> InsightFace API remoto
├── people_counter.py               # Contador de personas (SQLite + Prometheus :9102 + Telegram)
└── people_counter.db               # Base de datos SQLite eventos person
```

### VM 110 "face-recognition" (Servidor Proxmox)

```
/app/                               # Dentro del contenedor Docker
├── main.py                         # FastAPI service InsightFace
├── face_db.py                      # Gestion de embeddings (.npy + JSON)
└── requirements.txt                # Dependencias Python

/data/faces/                        # Volumen Docker face_data
├── index.json                      # Indice nombre -> archivos embedding
└── *.npy                           # Embeddings faciales (numpy arrays)
```

### RPi5

```
/usr/local/bin/
└── matrix_camaras.sh               # Script visor v3.4 (ubicacion correcta)

/home/pi/
└── matrix_camaras_autostart.sh     # Wrapper autostart
```

### Host Proxmox (proxmox-lugar1)

```
/root/
├── red_lugar1.sh                     # Script cambio red a Lugar 1
├── red_lugar2.sh                  # Script cambio red a Lugar 2
└── emergency_watchdog.py           # Emergency Watchdog v2.0 (crash-loop por PID + MQTT + self-watchdog)

/etc/pve/lxc/200.conf              # Config LXC (GPU + USB passthrough)
/etc/network/interfaces             # Config red (bridge vmbr0)
/etc/sysctl.d/99-ip-forward.conf   # IP forwarding para NAT
/etc/systemd/system/nat-tailscale.service    # NAT Tailscale persistente
/etc/systemd/system/emergency-watchdog.service  # Watchdog cascada (HOST)
/etc/udev/rules.d/99-coral-tpu.rules  # Coral USB autosuspend desactivado
```

Ver la estructura del repo en el `README.md` de la raiz.

---

## 11. CREDENCIALES

> **MODELO DE SECRETOS (SEC-5/6/7):** ningun secreto real vive en el repo. Los archivos
> versionados usan los placeholders `<USER>` / `<PASSWORD>` o leen de **variables de entorno**.
> Los scripts no llevan secretos hardcodeados: los toman de `/etc/vigilancia/vigilancia.env`
> (chmod 600, fuera del repo) via `EnvironmentFile=` en las units systemd. Plantilla:
> `.env.example` (+ `cam_urls.env.example` para el visor y `peerwatch.env.example` para el
> dead-man's-switch). Hay un **hook pre-commit anti-secretos** en `scripts/git-hooks/`:
> instalalo con `git config core.hooksPath scripts/git-hooks` antes del primer commit.
>
> Las tablas de abajo documentan **que credenciales existen y donde se usan**, no sus valores.
>
> **Deploy del env (estado s3):** creado `/etc/vigilancia/vigilancia.env` en el **HOST
> proxmox-lugar1** (consumido por backup + watchdog). **Falta** crearlo en el **LXC 200** (lo necesitan
> people_counter/bot/exporter cuando se desplieguen las versiones corregidas) y `cam_urls.env` en
> el **RPi5**.

### Acceso SSH

| Dispositivo | Usuario | Password | IP | Nota acceso |
|---|---|---|---|---|
| proxmox-lugar1 (Proxmox) | <USER> | <PASSWORD> | 192.0.2.10 / 100.64.10.2 | acepta password (no browser); `sshpass`/`pct exec 200` |
| LXC 200 | <USER> | <PASSWORD> | 192.0.2.20 | SSH directo RECHAZADO → `pct exec 200 -- <cmd>` desde proxmox-lugar1 |
| RPi5 | <USER> | <PASSWORD> | 192.0.2.51 (eth0) / 100.64.10.1 | Tailscale SSH pide **auth interactiva por URL** (tambien Linux); aprobar y queda cacheado |
| Servidor pve (Xeon) | <USER> | <PASSWORD> | 100.64.10.6 | key-auth; destino del backup (RES-2). Si se reinstala cambia host key |
| ~~VM 110 (face-recog)~~ | ~~&lt;USER&gt;~~ | — | ~~198.51.100.50 / 100.64.10.5~~ | **DESMANTELADA** (VM borrada, ver seccion 2) |

### Servicios Web

| Servicio | URL | Usuario | Password |
|---|---|---|---|
| Proxmox | https://192.0.2.10:8006 | <USER> | <PASSWORD> |
| Frigate | http://192.0.2.20:5000 | <USER> | <PASSWORD> |
| Grafana | http://192.0.2.20:3000 | <USER> | <PASSWORD> |
| go2rtc | http://192.0.2.20:1984 | - | - |
| Prometheus | http://192.0.2.20:9090 | - | - |
| InsightFace API | http://100.64.10.5:5050 | - | - |

### Camaras

| Camara | Usuario | Password |
|---|---|---|
| NVR Dahua (cam1-4) | <USER> | <PASSWORD> |
| CAM5 (Lugar 2) | <USER> | <PASSWORD> |
| CAM6 (Lugar 2) | <USER> | <PASSWORD> |

### APIs y Bots

| Servicio | Token / Key |
|---|---|
| Telegram Bot (@tu_bot_de_telegram) | <PASSWORD> |
| Telegram Chat ID | <TELEGRAM_CHAT_ID> |
| Telegram AUTHORIZED_IDS | {<TELEGRAM_CHAT_ID>} |
| GenAI Gemini API Key | <PASSWORD> |

---

## 12. COMANDOS UTILES

### Acceso al sistema

```bash
# SSH al host Proxmox (desde cualquier red via Tailscale)
ssh root@100.64.10.2

# SSH al host Proxmox (desde red Lugar 1)
ssh root@192.0.2.10

# Shell en LXC 200
pct exec 200 -- bash

# SSH a RPi5
ssh pi@100.64.10.1
```

### Frigate

```bash
# Logs en vivo
pct exec 200 -- docker logs frigate -f

# Reiniciar Frigate
pct exec 200 -- docker compose -f /opt/vigilancia/docker-compose.yml restart frigate

# Stats via API
curl -s -u <USER>:<PASSWORD> http://192.0.2.20:5000/api/stats | python3 -m json.tool

# Eventos de hoy
curl -s -u <USER>:<PASSWORD> "http://192.0.2.20:5000/api/events?limit=10" | python3 -m json.tool

# Verificar Coral TPU
pct exec 200 -- lsusb | grep 1a6e

# Streams go2rtc
curl -s http://192.0.2.20:1984/api/streams
```

### Servicios

```bash
# Estado de servicios en LXC 200
pct exec 200 -- systemctl status telegram-bot
pct exec 200 -- systemctl status frigate-exporter
pct exec 200 -- systemctl status mosquitto

# Estado NAT en host Proxmox
systemctl status nat-tailscale

# Reiniciar servicios
pct exec 200 -- systemctl restart telegram-bot
pct exec 200 -- systemctl restart frigate-exporter

# Logs
pct exec 200 -- journalctl -u telegram-bot -f
pct exec 200 -- journalctl -u frigate-exporter -f
```

### Face Recognition (InsightFace + face_bridge)

```bash
# Health check InsightFace API (desde LXC 200 o cualquier peer Tailscale)
curl -s http://100.64.10.5:5050/health | python3 -m json.tool

# Listar rostros entrenados
curl -s http://100.64.10.5:5050/faces | python3 -m json.tool

# Entrenar un rostro (enviar foto JPEG)
curl -X POST http://100.64.10.5:5050/train/NOMBRE -F "file=@foto.jpg"

# Reconocer rostros en una imagen
curl -X POST http://100.64.10.5:5050/recognize -F "file=@snapshot.jpg"

# Logs del face_bridge (LXC 200)
pct exec 200 -- journalctl -u face-bridge -f

# Estado del face_bridge
pct exec 200 -- systemctl status face-bridge

# Logs del contenedor InsightFace (VM 110)
ssh root@100.64.10.5 "docker logs face-recognition --tail 50"
```

### Docker

```bash
# Estado containers
pct exec 200 -- docker ps

# Reiniciar todo Docker
pct exec 200 -- docker compose -f /opt/vigilancia/docker-compose.yml restart

# Uso de disco
pct exec 200 -- df -h /
pct exec 200 -- du -sh /opt/vigilancia/storage/*/
```

### RPi5

```bash
# Reiniciar display
sudo systemctl restart matrix-camaras

# Ver logs watchdog
tail -f /tmp/matrix_camaras.log

# Estado del display
pgrep -c mpv   # Debe ser 6
```

### Disco

```bash
# Espacio en LXC
pct exec 200 -- df -h /

# Espacio por dia de grabaciones
pct exec 200 -- du -sh /opt/vigilancia/storage/recordings/*/

# Thin pool en host
lvs
vgs
```

### Backup y resiliencia (RES-2 / RES-9)

```bash
# --- en el HOST proxmox-lugar1 ---
# Probar el backup en seco (sourcea el env como hace systemd):
set -a; . /etc/vigilancia/vigilancia.env; set +a; /usr/local/bin/backup_to_pve.sh --dry-run
# Forzar un backup real ahora:
systemctl start backup-to-pve.service
# Estado y proxima ejecucion de los timers:
systemctl list-timers backup-to-pve.timer
journalctl -u backup-to-pve.service -n 30 --no-pager
tail -n 40 /var/log/backup_to_pve.log

# Verificar el backup en el destino (desde proxmox-lugar1 o desde la maquina del operador):
ssh root@100.64.10.6 'ls -la /var/backups/vigilancia/; cd /var/backups/vigilancia/$(date +%F) && sha256sum -c manifest.sha256'

# --- en el LXC 200 ---
pct exec 200 -- systemctl list-timers frigate-weekly-restart.timer
```

---

## 13. CAMBIO DE RED

Cuando la proxmox-lugar1 se mueve entre Lugar 1 y Lugar 2:

### Para LUGAR1 (192.0.2.10)
```bash
/root/red_lugar1.sh && reboot
```

### Para LUGAR2 (198.51.100.10)
```bash
/root/red_lugar2.sh && reboot
```

### Verificacion post-cambio
```bash
ip addr show vmbr0        # Verificar IP
ip route                   # Verificar gateway
ping -c 3 8.8.8.8         # Internet
tailscale status           # VPN
systemctl status nat-tailscale  # NAT Tailscale (solo en Lugar 1)
```

---

## 14. PROBLEMAS CONOCIDOS Y SOLUCIONES

### CUELGUE del sistema (v4.5 - RESUELTO)

- **Problema**: proxmox-lugar1 se colgo completamente, requirio hard reset
- **Causa raiz**: Tormenta de retries 429 de GenAI (1311+ retries) + exporter pesado (627MB/ciclo API) + cam4 crash loop
- **Solucion**: GenAI desactivado, exporter limit reducido a 500, cam4 estabilizada
- **Leccion**: NUNCA habilitar GenAI sin cuota confirmada y limites estrictos

### VAAPI + ICSee = crashes (v4.4 - RESUELTO)

- **Problema**: VAAPI crasheaba 78 veces/hora al decodificar HEVC de camaras ICSee
- **Causa**: Incompatibilidad driver iHD con streams HEVC de ICSee
- **Solucion**: cam4/5/6 cambiadas a software decode. VAAPI solo para cam1-3 (Dahua)

### LPR lee timestamp en vez de placas (v4.9 - RESUELTO)

- **Problema**: El OCR del LPR lee la fecha/hora superpuesta (OSD) de la camara ICSee como si fuera una placa
- **Causa**: No hay mascara sobre la zona del timestamp en cam6_lpr
- **Solucion**: cam6_lpr eliminada y reemplazada por cam6_face (zoom lens para rostros). LPR desactivado globalmente.

### NAT Tailscale se pierde al reiniciar (v4.5 - RESUELTO)

- **Problema**: Regla iptables NAT se perdia al reiniciar porque vmbr0 sube antes que tailscale0
- **Solucion**: Servicio systemd `nat-tailscale.service` que espera hasta 60s a que tailscale0 exista

### Coral TPU USB resets (RESUELTO v4.8)
- **Problema**: 15 USB resets en 46h, 1 error -71 (protocolo USB)
- **Causa**: autosuspend_delay=2000ms causaba resets al despertar
- **Solucion**: udev rule autosuspend_delay_ms=-1 + hub USB alimentado
- **Estado actual**: 1 reset/24h (estable), inferencia ~25ms

### cam4 ICSee no soporta 2 RTSP (v5.1 - RESUELTO)
- **Problema**: go2rtc abria 2 conexiones RTSP a cam4 (sub para detect, main para record), causando 2398 errores/6h en record y skipped fps
- **Causa**: ICSee cam4 solo soporta 1 conexion RTSP simultanea (diferente a cam5/cam6)
- **Solucion**: Consolidado a single stream mainstream (2560x1440) para detect+record. cam4_main eliminado de go2rtc

### Camara remota inestable tras un restart del detector (flapping de software, NO cable)
- **Problema**: cam5 cae tras cada restart de Frigate. Proxy proxy-lugar2 no entrega frames validos en frio
- **Diag remoto**: `scripts/diag_lugar2_cam.sh` la confirmo **SANA** (ping 198.51.100.30 OK, ffprobe HEVC 800x448@25fps). NO es cable ni camara muerta: es flapping de software (relay Tailscale dfw + el proxy no re-emite keyframe en frio). Cubierto por el watchdog.
- **Solucion (RES-5)**: path directo / DERP propio en el nodo remoto; reconexion robusta en go2rtc; o smart-plug para power-cycle del proxy. Leccion: el watchdog debe cubrir la ventana entre el restart del detector y la primera reconexion valida

### Camara remota offline — diagnostico de fallo FISICO
- **Problema**: cam6 (198.51.100.40) totalmente offline en su LAN local. Forzada OFF via `CAMS_NO_AUTO_RECOVERY`.
- **Diag remoto** (`diag_lugar2_cam.sh`): capa fisica caida — ping a 198.51.100.40 NO responde, pero el canary 198.51.100.30 SI (hay ruta por subnet-routing de Tailscale; la camara esta caida, no la red). ffprobe = Invalid data.
- **Hipotesis REABIERTA**: reporte in-situ del LED del eliminador encendido **pero sin speech "system starting app"**. Si cam6 tiene eliminador DC propio (RJ45 solo datos), una camara con corriente arrancaria y hablaria aunque el cable de red este cortado → apunta a **alimentacion/camara muerta**, no solo al cable RJ45 degradado por UV (hipotesis original v5.6).
- **Como cerrarlo**: PoE vs eliminador DC. Una **prueba de banco con 12V conocido-bueno** separa camara-muerta de cable cortado, sin desmontar nada mas.

### Apagon LUGAR1 + reboot loop RPi5
- **Reboot loop RPi5 (RESUELTO)**: el RPi5 se reiniciaba cada 12-38min. Causa raiz: 3 capas de auto-reboot, la culpable real `temp_watchdog.service` ejecutaba `sudo reboot` si temp>=80°C, y con cooling subperformante + ola calor entraba en ciclo. **Las 3 capas estan NEUTRALIZADAS** (HW watchdog systemd `RuntimeWatchdogSec=0`, daemon watchdog disabled, temp-watchdog disabled). **NO reactivar.** `boot-forensics` captura cada arranque. El fix aguanto 22 dias hasta el apagon.
- **Un apagon (CONFIRMADO)**: la luz se fue 2 veces en LUGAR1 → 2 SUSPECT_RESET del RPi5 (doble boot 4s = brownout) + reboot de proxmox-lugar1. Todo auto-recupero. Secuela: RPi5 `throttled=0x50000` (under-voltage+throttling ocurrieron, no activos). **Vigilar** `vcgencmd get_throttled`; si under-voltage recurre sin que haya habido corte de luz, revisar la PSU. Con UPS por isla (RES-1) este escenario no llega al equipo.

### Cooling subperformante del visor
- **Problema**: delta termico ~45°C sobre ambiente (esperado 25-30°C). Fan max 3894 RPM (Active Cooler oficial llega a ~6000).
- **Solucion**: Active Cooler oficial Pi5 + disipador limpio + pasta termica en buen estado. El kernel controla el fan por trip points (50/60/67.5/75°C), pero un cooling subdimensionado los alcanza demasiado pronto.

### Disco huerfano post-restart (v5.0 - RESUELTO)
- **Problema**: Disco LXC subio a 82% por grabaciones huerfanas tras restart de Frigate
- **Causa**: Frigate DB se recreo en restart, grabaciones anteriores quedaron sin trackear
- **Solucion**: sync_recordings habilitado + limpieza manual 80GB+. Disco 82%->30%

### Frigate memory leak progresivo (v5.5/v5.6 - MITIGADO)

- **Problema**: Frigate acumula RAM progresivamente. Medicion v5.5: ~300MB/dia. Medicion v5.6: ~1GB/dia (3x peor)
- **Causa**: Memory leak en Frigate 0.17 amplificado por crash-loops ffmpeg. Cada restart ffmpeg leak memoria en Python (allocator no devuelve al OS). cam5+cam6 via Tailscale relay: 14K restarts/dia. cam4 RTSP intermitente: 3K restarts/dia. Total: 60K+ restarts/dia
- **Solucion v5.5**: restart semanal de Frigate en LXC 200 + LXC RAM 8->12GB
- **Solucion v5.6**: Watchdog v2.0 desactiva camaras en crash-loop (reduce restarts dramaticamente). Docker log rotation 50m x 3
- **Sintoma watchdog**: check RAM falla porque `pct exec` timeout bajo presion de memoria -> SOS permanente

### cam5/cam6 crash-loop via Tailscale relay (v5.6 - MITIGADO)

- **Problema**: cam5+cam6 causan 14K+ ffmpeg restarts/dia via Tailscale relay (dfw, 64ms). Frigate reinicia ffmpeg sin backoff.
- **Causa**: Tailscale relay inestable causa desconexiones RTSP frecuentes. Watchdog v1.5 no detectaba porque las camaras ciclan tan rapido que fps>0 en checks de 30s.
- **Solucion**: Watchdog v2.0 Via 1: detecta >15 ffmpeg_pid changes en 5min y desactiva camara via MQTT. Re-enable automatico cuando RTSP vuelve.

### Frigate FPS alto despues de restart

- **Problema**: FPS se dispara a valores altos por 30-60 segundos despues de reiniciar
- **Causa**: Buffer acumulado en go2rtc se procesa de golpe
- **Solucion**: Esperar 1-2 minutos. Se estabiliza solo.

### CAM4 se congela (v3.3 - RESUELTO)

- **Problema**: Stream de CAM4 se congelaba frecuentemente
- **Causa**: mpv sincronizaba con reloj RTSP
- **Solucion**: `--untimed` + `--cache=no` en argumentos mpv para CAM4

### CAM4 substream inestable (v4.9 - RESUELTO)

- **Problema**: NVR ch4 substream pierde video intermitentemente (solo audio PCM)
- **Causa**: NVR Dahua ch4 inestable con substream de camara ICSee
- **Solucion**: go2rtc conecta directamente a ICSee en 192.0.2.30, bypassing el NVR

### ICSee limite conexiones RTSP

- **Problema**: Solo soporta 1-2 conexiones simultaneas
- **Solucion**: go2rtc es el UNICO consumidor. Todo pasa por restream.

### Coral TPU al limite (v4.3 - RESUELTO)

- **Problema**: A 5fps con 7 camaras, Coral llega al 97% y empieza a skipear
- **Solucion**: Reducido a 3fps. Coral al ~55% con margen del ~45%.

### Zonas/mascaras imprecisas tras cambiar la resolucion de detect

- **Problema**: zonas creadas con una resolucion y un aspect ratio distintos de los actuales
- **Causa**: las coordenadas son normalizadas (0-1) y sobreviven al cambio, pero el cambio de aspect ratio deforma el poligono
- **Solucion**: recalibrar en la UI de Frigate despues de cada cambio de `detect`

### RPi5 watchdog duplicado (v4.4 - RESUELTO)

- **Problema**: Dos procesos watchdog corriendo simultaneamente
- **Causa**: Script en /home/pi/ Y en /usr/local/bin/
- **Solucion**: Eliminado el de /home/pi/, solo usar /usr/local/bin/

### SSH warning "REMOTE HOST IDENTIFICATION HAS CHANGED"

- **Causa**: Key SSH cambio al reinstalar/reconfigurar Proxmox
- **Solucion**: `ssh-keygen -R <ip>` y reconectar

---

## 15. LECCIONES APRENDIDAS

### Frigate 0.17

- GenAI global NO acepta `enabled` ni `preferred_language` - solo `provider/api_key/model/base_url`
- LPR field es `lpr` no `license_plate_recognition`, camera `type: lpr`
- Detect dimensions afectan motion detection, NO Coral inference (siempre 320x320)
- Cambiar aspecto ratio detect rompe zonas/mascaras (coordenadas normalizadas 0-1)
- Semantic Search funciona con Jina CLIP v1, procesamiento 100% local
- 8 objetos COCO sin costo extra de Coral (siempre procesa todo el tensor 320x320)

### ICSee

- Dual lens: lente1=gran angular, lente2=zoom cercano
- cam5/cam6 soportan 2 RTSP simultaneas (main+sub). cam4 NO soporta (descubierto v5.1, causa errores record)
- URLs: `ch0_0`=main 2K, `ch0_1`=sub, `ch1_0`=lente2 main, `ch1_1`=lente2 sub
- **VAAPI incompatible con HEVC de ICSee**: 78 crashes/hora. Usar software decode.

### NVR Dahua

- `subtype=0` = mainstream (960x1080 HEVC) - mejor calidad
- `subtype=1` = substream (352x240) - menor calidad

### Coral USB TPU

- ~40 inf/s maximo a ~25ms cada una
- A 3fps x 6 cams = ~55% uso (seguro)
- A 5fps x 7 cams = 97% uso (peligroso, empieza a skipear)
- Post-fix autosuspend: ~5 resets/dia (estable, sin impacto operativo). autosuspend desactivado con udev rule -1 (v4.8)
- Desactivado permanentemente con udev rule: `/etc/udev/rules.d/99-coral-tpu.rules`

### InsightFace (Face Recognition Remoto)

- Face recog Frigate builtin (modelo small) = baja calidad de recortes, inutil para reconocimiento serio
- InsightFace buffalo_l (ArcFace R100) es muy superior pero pesado para N95 - moverlo a servidor dedicado
- Xeon E5-2680 v2 = Ivy Bridge (AVX, NO AVX2): numpy 2.x NO funciona (X86_V2 baseline), usar numpy<2
- onnxruntime 1.16.3 falla con "execstack" en kernel PVE, usar 1.19.2+
- InsightFace necesita build-essential (g++) para compilar extensiones Cython
- Docker build: usar PIP_CONSTRAINT="numpy<2" para forzar en build isolation tambien
- Rendimiento CPU-only Ivy Bridge: ~240-480ms por cara (aceptable para cooldown 30s)
- Confidence 1.0 con 4 muestras de entrenamiento = excelente reconocimiento

### GenAI / Gemini

- **Cuota REAL de Gemini gratuito: 20 RPD (NO 1000)**
- Tormenta de retries 429 puede colgar completamente el sistema (deadlock Frigate)
- NUNCA habilitar sin cuota confirmada y rate limiting estricto
- GenAI retry storm + exporter pesado + cam4 crash = combo letal

### Exporter Prometheus

- Limit 5000 eventos = ~627MB por ciclo de API. REDUCIR a 500 (factor del cuelgue)
- Cache TTL 60s es suficiente para Prometheus scrape cada 30s

### Face Recognition

- Resolucion detect afecta directamente la calidad: 800x448 muy bajo para rostros a distancia
- cam6 detect reducido a 800x448 (v5.1): 1280x720 era para face recog, innecesario con bridge off
- Vistas lejanas elevadas (cam4) son inutiles para face recog
- Thresholds mas bajos capturan mas rostros a costa de precision; conviene medir antes de bajarlos

### Telegram

- `ReplyKeyboardMarkup(is_persistent=True)` para teclado fijo
- `requests timeout` > `long poll timeout` (60s vs 30s) para evitar excepciones
- No usar `<>` en texto HTML, se interpreta como tags
- Validar AUTHORIZED_IDS para seguridad

### Watchdog / Monitoreo

- **Frigate 0.17 NO tiene REST API para toggle detect/record/camera**. Usar MQTT: `frigate/<cam>/set ON|OFF`
- Solo desactivar detect NO para ffmpeg restarts. Hay que desactivar camara completa (`frigate/<cam>/set OFF`)
- Frigate NO tiene backoff para ffmpeg restarts: camara muerta = crash loop infinito (~46 restarts/hora, 5683 en 3 dias)
- **Frigate 0.17 memory leak**: tasa base ~300MB/dia, pero crece a ~1GB/dia con crash-loops (60K+ restarts/dia). Cada restart ffmpeg leaks memoria en Python allocator. Watchdog v2.0 desactiva crash-loopers para reducir tasa de leak
- **Crash-loop detection por fps es insuficiente**: cam4 responde TCP pero sin video (fps=0, RTSP reachable). cam5/cam6 ciclan mas rapido que el check interval (fps>0 entre checks). Detectar por ffmpeg_pid changes es mas confiable
- **Docker logs sin rotacion crecen indefinidamente**: 259MB en 2 dias. Configurar /etc/docker/daemon.json con max-size/max-file
- Watchdog de cascada debe correr en HOST, NO en el contenedor que monitorea (sobrevive al colapso)
- Anti-falso-positivo: exigir N checks consecutivos fallidos antes de alertar (evita spikes momentaneos)
- Cooldown de mensajes Telegram: maximo 1 alerta/5min, 1 SOS/10min (evita spam si sistema ya colapso)
- Heartbeat logging cada 5 minutos para confirmar que el watchdog esta vivo

### PTZ / Patrulla

- **PTZ patrol via cron fue eliminado en v5.5.1** (nunca se elimino realmente en v3.3 como decia la documentacion)
- Camaras ICSee no tienen cruise/patrol interno en firmware (GetPresetTours vacio)
- ONVIF puerto 8899, ProfileToken "000" funciona para STOP/HOME en las 3 camaras PTZ
- Verificar siempre con `crontab -l` en RPi5 y `GetPresetTours` ONVIF antes de asumir que PTZ esta desactivado

### Linux/Proxmox

- `sed` rompe YAML -> usar Python pyyaml para editar frigate.yml
- Shell escaping con passwords especiales: usar base64 auth header para Grafana API
- Grafana uid 472, Prometheus uid 65534 para permisos de data dirs
- LXC privilegiado necesario para GPU + USB passthrough
- `pct resize` expande disco en caliente sin reiniciar
- NAT Tailscale necesita systemd service (vmbr0 sube antes que tailscale0)
- Coral USB autosuspend 2000ms causa resets al despertar -> desactivar con udev rule (-1)
- `qm guest exec` para acceder a VMs cuando SSH falla (usa qemu-guest-agent)
- `docker cp` + `docker restart` para hot-deploy sin rebuild completo
- Prometheus bind-mounted configs no se pueden sobrescribir con docker cp (device busy)

---

## 16. HISTORIAL DE CIERRES Y ROADMAP

### Completados en v5.6

- ~~Memory leak 3x peor~~ - Causa: 60K+ ffmpeg restarts/dia por crash-loops cam4+cam5+cam6
- ~~Watchdog v1.5 no detectaba crash-loops~~ - v2.0: deteccion por ffmpeg_pid changes + 0fps prolongado
- ~~cam6_remota sin crash-loop guard~~ - Agregada a CAMS_AUTO_DISABLE
- ~~Docker logs sin rotacion (259MB)~~ - daemon.json max-size 50m, max-file 3

### Completados en v5.5

- ~~Frigate memory leak 95%~~ - Restart manual + restart semanal programado
- ~~LXC 200 RAM insuficiente~~ - Aumentado 8GB -> 12GB (requiere restart del LXC para aplicar)
- ~~Watchdog SOS spam~~ - Resuelto con restart Frigate (RAM check ya pasa)
- ~~BIBLIA desactualizada v4.9~~ - Actualizada a v5.5

### Completados en v5.3-v5.4

- ~~cam4 crash loop 5683 restarts~~ - Watchdog v1.5 MQTT crash-loop-guard funcional
- ~~Watchdog v1.4 API REST no existia~~ - Migrado a MQTT mosquitto_pub

### Completados en v5.1

- ~~cam4 DTS record errors~~ - Resuelto: single stream fix, 0 errores record
- ~~Face Bridge desperdiciado~~ - Desactivado: 3160 API calls/6h con 0 reconocimientos
- ~~cam6_remota detect 1280x720 innecesario~~ - Reducido a 800x448
- ~~cam6_face sin proposito~~ - Desactivada (rostros <40px)
- ~~Docker images :latest~~ - Pinned: prometheus v3.10.0, grafana 12.4.0
- ~~CPU Frigate 374%~~ - Optimizado a ~150% con dual stream cam1-3

### Completados en v5.0

- ~~Disco 82% grabaciones huerfanas~~ - Limpiado a 30%, sync_recordings habilitado
- ~~People Counter basico~~ - v2.1 con zonas, coches, dedup cam1-3, Grafana 30 paneles
- ~~Frigate DB fragil~~ - Volumen persistente, 0% fragmentacion
- ~~Metricas Lugar 2 trafico/coches~~ - Implementado: people_count_by_zone, cars_count_today

### Completados en v4.9.x

- ~~Fix timezone LXC UTC~~ - Corregido a <TU_ZONA_HORARIA>
- ~~Datos people_counter en UTC~~ - 1647 eventos recalculados a la zona local
- ~~Disco cam5/cam6 excesivo~~ - Retencion reducida a 1d (ahorro ~54GB)
- ~~cam4 inestabilidad via NVR~~ - Conexion directa ICSee 192.0.2.30
- ~~Watchdog sin TPU monitoring~~ - v1.1 con 8 checks + TPU USB
- ~~Bot sin face training~~ - v4.2: /entrenar, /rostros, /cancelar

### Completados en v4.8

- ~~AUDITORIA COMPLETA~~ - 10 componentes, 5 fixes
- ~~CONTADOR DE PERSONAS~~ - people_counter.py + SQLite + Prometheus + Grafana + Telegram
- ~~Coral TPU autosuspend~~ - udev rule -1, persistente
- ~~IP estatica VM 110~~ - netplan 198.51.100.50/24
- ~~Disco LXC 82%~~ - Limpiado a 53%
- ~~API key face_api~~ - X-API-Key en endpoints protegidos

### Lineas de trabajo abiertas (del diseno, no de un despliegue concreto)

**Resiliencia**

- Ensayar periodicamente el restore completo, no solo el backup (RES-3).
- Backup de las **grabaciones** a disco externo, ademas del de DB/config (RES-2 cubre lo segundo).
- Ruta directa o DERP propio para el proxy RTSP remoto: tras un restart del detector, un proxy
  que no entrega frames "en frio" deja la camara caida hasta la siguiente pasada del watchdog
  (RES-5).

**Deteccion**

- Recalibrar zonas y mascaras despues de cualquier cambio de resolucion o aspect ratio de `detect`.
- Un lente con encuadre dedicado si se quiere reconocimiento facial util: por debajo de ~40 px
  de rostro el reconocimiento no aporta nada y solo gasta llamadas a la API.
- Evaluar modelos alternativos en la Coral (p.ej. EfficientDet-Lite1) para separar mejor grupos
  de personas.

**Operacion**

- Rotacion periodica de credenciales de todos los servicios y camaras.
- Mantener las imagenes Docker pinneadas y revisar upgrades de Frigate de forma controlada.
- LPR: solo tiene sentido con un lente de zoom dedicado y las mascaras de OSD bien resueltas.

### Notas sobre metricas avanzadas

**Deteccion de bolsas de compras**: El modelo COCO detecta `handbag` y `backpack` pero NO "bolsa de compras" generica. Precision baja a 800x448. No recomendado como metrica de conversion.

**Tracking de trayectoria entrada/salida**: Frigate NO hace tracking de identidad entre zonas. Para ReID se necesitaria modelo adicional que el N95 no soporta.

**Conclusion**: Los conteos de trafico peatonal + vehiculos detenidos + personas por zona/hora son datos solidos y confiables.

---

## 17. HISTORIAL DE VERSIONES

| Fecha | Version | Cambios principales |
|---|---|---|
| — | v1.0 | Sistema inicial RPi5 + mpv |
| — | v2.6 | Hardware watchdog + temperature monitor |
| — | v3.0 | Migracion a Proxmox + Frigate + Coral TPU |
| — | v3.3 | Fix CAM4 freezes, ventana mantenimiento |
| — | v4.0-prep | Arquitectura split, LXC 200, fases 0-5 |
| s1 | v4.0 | go2rtc restream operativo, Frigate 0.17 + Coral |
| s2 | v4.1 | Dual stream cam4-6, grabacion 2K |
| s3 | v4.2 | Face Recognition, GenAI Gemini, LPR, Grafana+Prometheus |
| s1 | v4.3 | Bot Telegram v4, Grafana 20 paneles, cam1-3 HD, 3fps |
| s2 | v4.4 | Auditoria: VAAPI fix ICSee (software decode), GenAI 2.5, bot securizado, LXC 200GB |
| s3 | v4.5 | Forense cuelgue: GenAI retry storm (1311+), GenAI DESACTIVADO, NAT restaurado |
| s1 | v4.6 | Semantic Search (Jina CLIP), 8 objetos COCO, face recog optimizado, LPR off, NAT persistente, exporter fix, CPU 78%->33.5% |
| **s2** | **v4.7** | **Face Recognition remoto InsightFace (VM 110 Proxmox), face_bridge MQTT, face recog Frigate desactivado, 4 muestras PERSONA1 entrenadas** |
| s1 | v4.8 | Auditoria completa (5 fixes), Contador de personas (SQLite+Grafana+Telegram), Emergency Watchdog, IP estatica VM 110, USB autosuspend fix, API key face_api |
| **s2** | **v4.9** | **cam4 directo ICSee, Watchdog v1.1 TPU monitoring (8 checks), cam6_face zoom lens, Face Bridge v1.1 smart retry, Bot v4.2 face training, retencion optimizada, backup HDD preparado** |
| s3 | v4.9.1 | Fix timezone LXC UTC-><TU_ZONA_HORARIA>, datos people_counter recalculados, docker-compose /etc/localtime |
| s1 | v4.9.2 | Diagnostico cam5 offline, retencion cam5/cam6 reducida a 1d, Coral USB verificado |
| **s2** | **v5.0** | **People Counter v2.1 dedup, Grafana 30 paneles, Frigate DB persistente, disco 82%->30%, sync_recordings, Watchdog v1.2 SIGALRM, car tracking** |
| s1 | v5.0.1 | Fix cam4 skipped fps 62.6->0 (input_args -r 3) |
| s2 | v5.1 | Auditoria infra: CPU -60% (374->150%), dual stream cam1-3, cam4 single stream fix, cam6_face off, face-bridge off, Docker pinned |
| **—** | **v5.2** | **Auditoria en vivo SSH: disco 66%->56% (retencion reducida), Docker pinned real (containers recreados), cam4 DTS fix (-an audio), Semantic Search off, CPU 33%->15%** |
| — | v5.3 | Diagnostico 3334 cam4 restarts/72h (RTSP muerto, ping OK). Watchdog v1.4 crash-loop-guard (API REST, fallida) |
| **—** | **v5.4** | **Auditoria critica: Watchdog v1.4 crash-loop-guard NUNCA FUNCIONO (API 404). Fix v1.5 con MQTT mosquitto_pub. Desactiva camara completa (no solo detect). 5683 restarts cam4 eliminados** |
| **—** | **v5.6** | **Auditoria HW completa. Memory leak 3x peor por 60K ffmpeg restarts/dia (cam5+cam6 Tailscale relay + cam4). Watchdog v2.0: deteccion crash-loop por ffmpeg_pid changes + 0fps prolongado. cam6_remota agregada. Docker log rotation 50m x 3** |
| — | v5.6.1 | Auditoria completa EN VIVO (0 cambios). VM110 confirmada BORRADA (no apagada). Un apagon confirmado (RPi5 throttled=0x50000). cam5 flapping. Repo: CLAUDE.md reestructurado, .gitignore snapshots. |
| — | v5.6.2-repo | Auditoria multi-agente (4 areas) → 39 hallazgos. Repo (sin deploy): 17 bugs corregidos (nightly_backup destructor, check_coral ciego, SQLite WAL, bot auth from.id, dedup coches…), higiene de secretos (0 inline, env/EnvironmentFile, hook pre-commit), docs reconciliadas. |
| — | v5.6.2-repo | DOC-3 resuelto (RPi5 .51=eth0/.52=wlan0). Creados RES-2/3/4b/8/9 (backup a pve, runbook, exporter temp RPi5, ntfy, systemd-timers). Diag remoto Lugar 2 (`diag_lugar2_cam.sh`): cam5 SANA, cam6 fallo fisico. |
| **s3** | **v5.6.2** | **PRIMER DEPLOY supervisado (LUGAR1, LAN directa). Fundacion: `/etc/vigilancia/vigilancia.env` (host). RES-2: backup diario REAL a pve (1er backup 282M verificado sha256, timer nocturno Persistent). RES-9: cron Frigate → systemd-timer (LXC). Servicios vivos intactos. Ver seccion 21.** |
| — | v5.5.1 | Auditoria post-apagon OK (10/10 subsistemas auto-recuperaron). PTZ patrol descubierto activo y eliminado completamente (3 crons + 2 scripts + 1 service en RPi5) |
| — | v5.5 | Auditoria completa: Frigate memory leak 7.6GB/8GB (95%) tras 20 dias uptime. Restart Frigate (1.6GB). LXC RAM 8->12GB. Restart semanal programado. Watchdog SOS resuelto (8/8 OK) |

---

## 18. AUDITORIA DE CALIDAD Y BUENAS PRACTICAS

> **Ejecutada en v4.8**. Se auditaron 10 componentes del sistema, se encontraron 5 hallazgos criticos y se corrigieron todos.

### Resultados de la Auditoria

| # | Componente | Estado | Hallazgo |
|---|---|---|---|
| 1 | **frigate.yml** | CORREGIDO | face_recognition.enabled: true a nivel GLOBAL consumia CPU innecesariamente |
| 2 | **docker-compose.yml** | OK | Health checks, restart policies, volumenes correctos |
| 3 | **telegram_bot.py** | OK | Seguridad AUTHORIZED_IDS, error handling, thread recovery |
| 4 | **frigate_exporter.py** | OK | limit=500 correcto, cache TTL 60s |
| 5 | **face_bridge.py** | CORREGIDO | Agregada autenticacion API key (X-API-Key header) |
| 6 | **InsightFace API** | CORREGIDO | Sin autenticacion -> agregado APIKeyHeader en endpoints protegidos |
| 7 | **Coral TPU** | CORREGIDO | autosuspend_delay 2000ms -> -1 via udev rule persistente |
| 8 | **go2rtc** | OK | Streams estables, reconexion automatica |
| 9 | **MQTT Mosquitto** | OK | Configuracion default, persistencia habilitada |
| 10 | **Grafana + Prometheus** | OK | 24 paneles, scrape 30s, exporter limit=500 |
| 11 | **NAT Tailscale** | OK | Persistente via systemd nat-tailscale.service |
| 12 | **RPi5 display** | CORREGIDO | Bug VPN check: pingaba host local en vez de peer Tailscale |
| 13 | **Disco LXC 200** | CORREGIDO | 82% -> 53%, retencion motion 3d->1d, detections/alerts 7d->5d |

### Fixes aplicados (v4.8)

1. **face_recognition.enabled: false** global en Frigate (ahorro CPU en N95)
2. **Disco LXC 200**: limpieza 82%->53% + retencion reducida (motion 1d, detections/alerts 5d)
3. **matrix_camaras.sh VPN check**: corregido para pingar 100.64.10.3 (proxy-lugar2 Tailscale) en vez de 192.0.2.20
4. **Coral TPU autosuspend**: udev rule `/etc/udev/rules.d/99-coral-tpu.rules` con autosuspend_delay_ms=-1
5. **API key face_api**: endpoints /recognize, /train, /delete protegidos con X-API-Key header (key: <PASSWORD>)

---

## 19. CONTADOR DE PERSONAS - ANALISIS DE TRAFICO PEATONAL

> **Implementado en v4.8**. Servicio `people-counter.service` operativo en LXC 200.

### Arquitectura

```
Frigate API (/api/events?label=person)
        |
        v (sync cada 5 min)
people_counter.py
        |
        +---> SQLite (people_counter.db) - almacenamiento persistente
        |
        +---> Prometheus metrics (:9102) --> Grafana (4 paneles)
        |
        +---> Telegram reports (diario, semanal, mensual)
```

### Script: `scripts/people_counter.py`

- **Ubicacion remota**: `/opt/vigilancia/people_counter.py` en LXC 200
- **Servicio systemd**: `people-counter.service`
- **Base de datos**: `/opt/vigilancia/people_counter.db` (SQLite)
- **Puerto Prometheus**: 9102
- **Sync**: cada 5 minutos desde Frigate API (idempotente INSERT OR IGNORE)
- **CLI**: `python3 people_counter.py --report daily|weekly|monthly`

### Zonas configuradas por camara

| Camara | Zonas filtradas | Relevancia |
|---|---|---|
| cam5_remota | (definir en `CAMERA_ZONES`) | **ALTA** |
| cam6_remota | (definir en `CAMERA_ZONES`) | **ALTA** |
| cam1_nvr | todas (sin filtro) | MEDIA |
| cam2_nvr | todas (sin filtro) | MEDIA |
| cam3_nvr | todas (sin filtro) | MEDIA |
| cam4_icsee | todas (sin filtro) | BAJA |

### Metricas Prometheus (puerto 9102)

| Metrica | Tipo | Labels |
|---|---|---|
| `people_count_today` | Gauge | camera |
| `people_count_by_hour` | Gauge | camera, hour |
| `people_count_week` | Gauge | camera |
| `people_count_month` | Gauge | camera |
| `people_count_by_zone` | Gauge | camera, zone |
| `cars_count_today` | Gauge | camera |
| `cars_count_by_hour` | Gauge | hour |
| `people_count_dedup_today` | Gauge | - |

> cam1-3 apuntan a la misma calle: se deduplicaron tomando el max en vez de sumar (v5.0). Total raw ~950 -> dedup ~470 personas. Reportes muestran "Calle Lugar 1" como grupo.

### Paneles Grafana (v5.0: 6 nuevos metricas Lugar 2, total 30)

1. **Personas Hoy por Camara** - Bar chart por camara
2. **Total Personas Hoy** - Stat panel suma total
3. **Personas Esta Semana** - Bar chart por camara
4. **Personas por Hora (Hoy)** - Time series por hora

### Reportes Telegram automaticos

| Reporte | Horario | Contenido |
|---|---|---|
| Diario | Una vez al dia (`DAILY_SUMMARY_HOUR`) | Total por camara, hora pico, top zonas |
| Semanal | Una vez por semana | Total semanal, promedio diario, dia mas activo |
| Mensual | Ultimo dia del mes | Total mensual, comparativa, tendencias |

---

## 20. EMERGENCY WATCHDOG - DETECCION DE FALLOS EN CASCADA

> **Implementado en v4.8**. Servicio `emergency-watchdog.service` operativo en HOST proxmox-lugar1.

### Contexto

En la sesion v4.5, el sistema colapso por cascada: GenAI retry storm (1311+ retries 429) -> CPU 100% -> Frigate deadlock -> todo muerto. El usuario tardo **1h30m en darse cuenta**. Este watchdog habria alertado en ~2 minutos.

### Principio clave

El watchdog corre en el **HOST proxmox-lugar1** (NO en LXC 200) para **sobrevivir al colapso** del contenedor que monitorea. No depende de Docker, Frigate ni de ningun servicio dentro del LXC.

### Script: `scripts/emergency_watchdog.py`

- **Ubicacion remota**: `/root/emergency_watchdog.py` en HOST proxmox-lugar1
- **Servicio systemd**: `emergency-watchdog.service` en HOST (no en LXC)
- **Log**: `/var/log/emergency_watchdog.log`
- **Version**: **v2.0** (crash-loop-guard por conteo de ffmpeg_pid + 0fps prolongado + CAMS_NO_AUTO_RECOVERY)
- **Intervalo checks**: cada 30 segundos
- **Dependencias**: Solo Python3 stdlib + urllib + mosquitto_pub (ya incluidos en Proxmox)
- **Estado**: corre en `/root/emergency_watchdog.py` del HOST proxmox-lugar1, activo. Heartbeat "8/8 checks OK".

### Checks realizados (8 total)

> CAMS_IGNORE: [cam6_face] (v5.1)
> Self-watchdog: SIGALRM 120s timeout, auto-restart via systemd (v5.0)
> Self-watchdog: en SIGALRM hace flush del logger antes de `os._exit` (BUG-15)

#### Crash-loop-guard v2.0 (la clave de la estabilidad actual)

Frigate 0.17 **NO tiene REST API** para toggle detect/record: todo el control es por **MQTT**
(`frigate/<cam>/set ON|OFF`). El guard protege `cam4_icsee`, `cam5_remota`, `cam6_remota` y
desactiva la **camara completa** (no solo detect) por 3 vias:

- **Via 1 — PID restarts**: >15 cambios de `ffmpeg_pid` en 300s → desactiva. (cam5/cam6 ciclan
  mas rapido que el check interval, por eso el conteo de PID es mas fiable que el fps).
- **Via 2 — 0fps + RTSP down**: 0fps con RTSP inalcanzable x4 checks (2min) → desactiva.
- **Via 3 — 0fps prolongado**: 0fps con RTSP alcanzable x12 checks (6min) → desactiva (caso cam4:
  responde TCP pero sin video).
- **Auto-recovery**: reactiva la camara (`frigate/<cam>/set ON`) cuando el RTSP vuelve y resetea
  contadores. **EXCEPCION — `CAMS_NO_AUTO_RECOVERY = {cam6_remota}`**: arranca disabled y NUNCA se
  reactiva sola (fallo fisico sospechado). Para revertir tras reparar cam6: vaciar el set,
  reiniciar el watchdog, MQTT ON.
- **RES-7**: restart de Frigate por umbral de RSS, complementa el restart semanal.

> **Leccion:** un watchdog corregido en el repo pero no desplegado no protege nada. Al tocar
> el proceso que vigila el sistema, desplegar **uno por uno** con `.bak` + restart + verify:
> es el unico componente cuyo fallo no se anuncia solo.

| Check | Metodo | Umbral Warning | Umbral SOS |
|---|---|---|---|
| CPU LXC 200 | `pct exec` + /proc/loadavg | >80% por 2min | >90% por 4min |
| RAM LXC 200 | `pct exec` + free -m | >85% | >93% |
| Disco LXC 200 | `pct exec` + df | >90% | >95% |
| Frigate API | HTTP GET /api/stats | timeout 5s | 3 fallos consecutivos |
| Camaras activas | Frigate stats camera_fps | 2+ a 0fps | 4+ a 0fps |
| Coral TPU | Frigate stats inference_speed | >100ms o 2.5x trend | >200ms |
| Docker health | `pct exec` + docker inspect | unhealthy | unhealthy 3min |
| **TPU USB** | **dmesg USB resets en 1h** | **>5 resets/h** | **>10 resets/h o error -71** |

### Sistema de escalacion (3 niveles)

| Nivel | Condicion | Accion |
|---|---|---|
| **WARNING** | 1 check falla (consecutivo >=4) | Log local, sin Telegram |
| **ALERT** | 2+ checks fallan simultaneamente | Telegram con detalle |
| **SOS** | 3+ checks fallan O 1 critico sostenido | Telegram con instrucciones de recuperacion |

### Anti-falso-positivo

- Cada check necesita fallar N veces consecutivas antes de contar como fallo:
  - `CONSEC_WARN = 4` (4 checks x 30s = 2 minutos)
  - `CONSEC_SOS = 8` (8 checks x 30s = 4 minutos)
  - `CONSEC_API = 3` (3 fallos API = ~1.5 minutos)

### Cooldown de mensajes

- **ALERT**: maximo 1 cada 5 minutos
- **SOS**: maximo 1 cada 10 minutos
- **Recuperacion**: mensaje unico cuando todos los checks vuelven a OK

### Formato mensajes Telegram

**SOS:**
```
🆘 EMERGENCIA SISTEMA VIGILANCIA

MULTIPLES FALLOS DETECTADOS:
• CPU 94% (hace 4min)
• Frigate API: NO RESPONDE (hace 2min)
• 4 camaras muertas: cam3, cam4, cam5, cam6

⚡ Accion sugerida: reiniciar LXC 200
  ssh root@100.64.10.2
  pct restart 200

Hora: 14:35:45
```

**Recuperacion:**
```
✅ SISTEMA RECUPERADO

Checks recuperados: cpu, api, cameras
Hora: 14:40:12
```

---

## 21. RESILIENCIA, BACKUP Y RECUPERACION DE DESASTRES

> Capa nacida de una auditoria de resiliencia. El nodo que concentra deteccion, grabacion y
> base de datos es, por diseno, el punto de fallo mas critico del sistema: esta seccion define
> los controles que lo respaldan.

### Mapa de IDs de resiliencia (RES-*)

Cada RES-* es un **control del diseno de referencia**. El estado de despliegue es propio de
cada instalacion y se lleva fuera del repo.

| ID | Control | Donde aplica |
|----|---------|--------------|
| RES-1 | UPS por isla (computo **y** red en el mismo UPS) + BIOS "restore on AC = power on" | Cada sitio |
| RES-2 | Backup diario de DB/config a un tercer nodo (`backup_to_pve.sh`) | Host principal → nodo de backup |
| RES-3 | Runbook de recuperacion del contenedor + ensayo periodico del restore | `docs/RUNBOOK_recuperacion_LXC200.md` |
| RES-4 / 4b | Cooling activo del visor + exportar temp/throttled a Prometheus | Visor (RPi5) |
| RES-5 | Ruta directa / DERP propio para el proxy RTSP remoto | Sitio remoto |
| RES-6 | Cableado de camaras verificado (evitar failover silencioso a WiFi) | Todos los sitios |
| RES-7 | Restart de Frigate por umbral de RSS en el watchdog | Host principal |
| RES-8 | Segundo canal de alertas independiente (ntfy) | Host principal |
| RES-9 | Crons → systemd-timers con `Persistent=true` | Todos los nodos |

> **RES-1 no es opcional.** Sin UPS, un corte de luz derriba a la vez las camaras, la deteccion,
> la grabacion **y** el canal de alertas: el fallo no se anuncia porque el que avisa cae con el
> resto. Es la razon de ser del dead-man's-switch entre sitios (RES-8 + `peer_watch.sh`), que
> cubre el caso en que una isla entera queda muda. Alimentar tambien el **router y el switch**:
> un UPS que solo sostiene el computo deja el sitio vivo pero incomunicado.

### RES-2 — Backup diario a pve (DESPLEGADO)

**Que respalda** (lo irreemplazable que NO se reconstruye): `people_counter.db` (historico del
contador), `frigate.db` (estado/metadata de grabaciones) y `frigate.yml` (config). **NO** respalda
los videos: para eso esta `nightly_backup.sh` → HDD externo, que es un control aparte.

**Como** (`scripts/backup_to_pve.sh`, corre en el **host proxmox-lugar1**):
1. Snapshot consistente de cada SQLite con `sqlite3 .backup` dentro del LXC (seguro con WAL).
2. `pct pull` al staging del host → `rsync` a un staging remoto en pve.
3. **Verificacion por checksum** sha256 origen-vs-destino ANTES de promover.
4. Promocion **atomica** (`mv`) + retencion (borra snapshots > `PVE_RETENTION_DAYS`, def 14d).
5. **NUNCA borra el origen** (a diferencia del `nightly_backup.sh` que hace tiering al HDD).
6. Alerta por Telegram (+ ntfy via RES-8) en fallo.

**Destino**: `pve:/var/backups/vigilancia/<fecha>/` (Tailscale `100.64.10.6`). Primer backup
real: **282M** (people_counter.db 23M + frigate.db 260M + config), verificado
independientemente con `sha256sum -c` en pve.

**Programacion**: `backup-to-pve.timer` → diario en horario nocturno (`OnCalendar` + `RandomizedDelaySec`
para que la hora exacta de disparo no sea predecible; ajusta la hora en tu despliegue),
`Persistent=true`. Lee secretos de `/etc/vigilancia/vigilancia.env` (`EnvironmentFile=`).

**Dependencias de infra (si el backup falla, revisar aqui):**
- **Host key de pve** en `known_hosts` de proxmox-lugar1. Si pve se **reinstala**, cambia y rompe el SSH:
  `ssh-keygen -R 100.64.10.6` + `ssh-keyscan`.
- **Pubkey de proxmox-lugar1** (`id_ed25519`, "proxmox-minipc") en `pve:/root/.ssh/authorized_keys`.
- **`sqlite3` instalado en el LXC 200** (si falta, cae a copia en frio, menos segura).
- **Path Tailscale proxmox-lugar1→pve se enfria si idle**: el ICMP NO lo despierta, un TCP connect si. El
  script hace warmup (`tailscale ping`) + 5 reintentos en el preflight (clave para el disparo
  desatendido nocturno).
- Log: `/var/log/backup_to_pve.log` en proxmox-lugar1. Prueba manual: `--dry-run`.

### RES-9 — systemd-timers Persistent (reemplazan crons)

`Persistent=true` corre el job atrasado **al volver** si el host estaba apagado a la hora del
disparo (apagon / NTP sin sincronizar) en vez de perderlo.

| Unit | Donde | Hace | Reemplaza | Estado |
|------|-------|------|-----------|--------|
| `backup-to-pve.timer` | host proxmox-lugar1 | backup nocturno diario | — (nuevo) | Host principal |
| `frigate-weekly-restart.timer` | LXC 200 | `docker restart frigate` semanal (memory leak) | cron semanal | Sustituye al cron |
| `rpi5-temp-exporter.timer` | RPi5 | temp/throttled → node_exporter cada 60s | — (nuevo) | Visor |

> Para revertir cualquiera: `systemctl disable --now <unit>.timer` y restaurar el cron.

### RES-8 — Segundo canal de alertas (`alert_notify.sh`)

Helper desplegado en `/usr/local/bin/alert_notify.sh`. Envia a **ntfy + Telegram** (devuelve 0 si
algun canal funciona), para no depender de un solo bot. **Pendiente**: definir `NTFY_URL` en el env
(canal con nombre dificil de adivinar) y cablearlo en watchdog/backup. Hoy el backup notifica solo
por Telegram.

### RES-3 — Runbook de recuperacion

`docs/RUNBOOK_recuperacion_LXC200.md`: triage, restore desde vzdump, **caso peor** (rehidratar el
LXC en el servidor pve degradado), restauracion del NAT Tailscale y go2rtc. **Pendiente del
usuario**: configurar un **vzdump programado del CT 200** (Datacenter→Backup) a un storage que
sobreviva al proxmox-lugar1 + **ensayar un restore real una vez** (el runbook lo asume pero no se ha
probado).

### Diagnostico remoto del Lugar 2 (`diag_lugar2_cam.sh`)

Sondea cam5/cam6 **por capas** desde cualquier nodo del tailnet (sin entrar al proxy): proxy
proxy-lugar2 → puerto TCP → **ping a la IP local de la camara (capa fisica)** → ffprobe video. Usa un
**canary** (`198.51.100.30`) para distinguir "camara caida" de "sin subnet-routing". Veredicto
accionable (cambiar cable / reboot camara / proxy caido / sana) + exit codes 0/1/2/3. Hallazgo de
red: `198.51.100.0/24` es alcanzable por Tailscale (subnet-router en proxy-lugar2). Regla: "puerto
abierto" o "proxy OK" NO prueban que la camara viva; el ping a su IP local y el ffprobe si.

### Gotchas del deploy a hosts vivos (leer antes del proximo deploy)

- **Divergencia de nombres repo-vs-vivo**: los servicios corren `telegram_bot.py` y
  `frigate_exporter.py`, pero el repo corrigio `telegram_bot_v3.py` y `frigate_exporter_v2.py`. NO
  es `scp` directo → comparar contenido, respaldar el vivo a `.bak`, sobrescribir o reapuntar
  `ExecStart`. (`people_counter.py` y `emergency_watchdog.py` si coinciden de nombre.)
- **Env por host antes de copiar scripts**: los scripts corregidos leen secretos de env. Crear
  `/etc/vigilancia/vigilancia.env` (600) y `EnvironmentFile=` en la unit **antes** de desplegar el
  script, o se rompe la auth de un servicio que hoy funciona. El host proxmox-lugar1 ya lo tiene; el **LXC
  200 todavia NO**.
- **Orden seguro**: desplegar servicios vivos **uno por uno**, empezando por el menos critico
  (`frigate-exporter`) para validar el mecanismo env, con `.bak` + restart + verify entre cada uno.
  Nunca "deploy todo" de golpe sobre un sistema que funciona.
- **Rutas Frigate reales** (verificadas en vivo): config = `/opt/vigilancia/config/frigate.yml`;
  db = `/opt/vigilancia/frigate_config/frigate.db`; go2rtc = `/opt/vigilancia/config/go2rtc.yaml`.
- **Acceso**: proxmox-lugar1 acepta password (`sshpass`); LXC via `pct exec`; RPi5 pide auth interactiva
  Tailscale (bloquea deploy automatizado de RES-4b/cam_urls).

### Checklist de puesta en marcha (orden sugerido)

Orden recomendado al levantar una instalacion nueva. No es una lista de deuda de ningun
despliegue concreto.

1. **Fisicos primero**: UPS por isla alimentando computo **y** red (RES-1), cooling activo del
   visor, disco de backup. Todo lo demas asume que la energia y la red no se caen solas.
2. **Modelo de secretos**: `/etc/vigilancia/vigilancia.env` (chmod 600) + `EnvironmentFile=` en
   cada unit, y `git config core.hooksPath scripts/git-hooks` antes del primer commit.
3. **Backup + ensayo de restore** (RES-2/RES-3): un backup que nunca se restauro no es un backup.
4. **Timers `Persistent=true`** en vez de crons (RES-9), para no perder un disparo tras un corte.
5. **Segundo canal de alertas** independiente del primero (RES-8) y dead-man's-switch entre
   sitios: el host que vigila tiene que poder morir sin llevarse el aviso con el.
6. **Calibracion**: zonas, mascaras y umbrales sobre tus propios encuadres (seccion 4).

# Sistema de Videovigilancia Híbrido

Sistema de videovigilancia multi-sitio con inteligencia artificial local (Frigate + Coral
TPU), sin dependencia de nube: detección de objetos, reconocimiento facial, alertas por
Telegram/ntfy, monitoreo (Grafana + Prometheus) y una capa de resiliencia tipo
dead-man's-switch entre sitios, todo sobre una malla VPN Tailscale.

> Esta es una **versión pública derivada** de un proyecto privado más completo. Ver
> [«Qué NO incluye este repo»](#qué-no-incluye-este-repo) al final.

## Aviso legal / disclaimer

Este software se publica bajo licencia MIT: **"tal cual", sin garantía, y sin responsabilidad
del autor por el uso que terceros le den** (ver [`LICENSE`](LICENSE)). Incluye capacidades de
detección de objetos, **reconocimiento facial** y **lectura de placas (LPR)** — funcionalidades
sujetas a leyes de privacidad y videovigilancia que **varían por país/estado** (consentimiento,
notificación a terceros, retención de datos biométricos, etc.). Si lo despliegas:

- Es tu responsabilidad verificar y cumplir la normativa local antes de grabar, detectar o
  identificar personas — especialmente en espacios donde terceros no esperan ser vigilados.
- El reconocimiento facial y el LPR son opcionales y están pensados para uso personal/propio
  (identificar a quienes tú autorices), no para vigilancia de terceros sin su conocimiento.
- El autor no opera, mantiene ni se hace responsable de ninguna instalación de terceros basada
  en este repositorio.

---

## Resumen

Unifica cámaras IP de dos ubicaciones físicas distintas (una LAN "Lugar 1" y una LAN
"Lugar 2") en un único punto de detección y visualización, usando hardware modesto
(mini PC con Coral USB TPU + una Raspberry Pi 5 como visor) y software 100% open source.
Sin mensualidades de nube: todo el pipeline de video, detección y almacenamiento corre en
la propia red del usuario, con acceso remoto cifrado vía Tailscale.

## Evolución del proyecto

| Fase | Hardware | Software | Estado |
|------|----------|----------|--------|
| v1.0 | Raspberry Pi 5 4GB | mpv + watchdog | Activo (display) |
| v2.0 | Mini PC (Proxmox) | Frigate + Docker + Coral | Reemplazado |
| v4.0 | Mini PC (cerebro IA) + RPi5 (display) | Frigate 0.17 + go2rtc + Coral + VAAPI | Operativo |
| v4.2 | Mini PC + RPi5 + Coral + Grafana | Face Recog + GenAI Gemini + LPR + Monitoring | Operativo |
| v4.3 | Mini PC + RPi5 + Coral + Grafana | Bot Telegram v4 + Grafana 20 paneles + cam1-3 HD | Operativo |
| v4.4 | Mini PC + RPi5 + Coral + Grafana | Auditoría + VAAPI fix + GenAI 2.5 + Bot seguro + LXC 200GB | Operativo |
| v4.5 | Mini PC + RPi5 + Coral + Grafana | GenAI desactivado, forense de cuelgue, sistema estabilizado | Operativo |
| v4.6 | Mini PC + RPi5 + Coral + Grafana | Semantic Search + 8 objetos + face recog opt + LPR off + NAT persistente | Operativo |
| v4.7 | Mini PC + RPi5 + Coral + Servidor Proxmox | Face Recognition remoto InsightFace (VM dedicada) + bridge MQTT | Operativo |
| v4.8 | Mini PC + RPi5 + Coral + Servidor Proxmox | Auditoría completa, contador de personas, emergency watchdog, IP estática VM face-recog | Operativo |
| v4.9 | Mini PC + RPi5 + Coral + Servidor Proxmox | cam4 directo, watchdog v1.1 TPU, face-bridge v1.1, entrenamiento de rostros por bot | Operativo |
| v5.0 | Mini PC + RPi5 + Coral + Servidor Proxmox | People Counter v2 (zonas + conteo de autos), watchdog v1.2, Grafana 30 paneles, DB persistente | Operativo |
| v5.1 | Mini PC + RPi5 + Coral + Servidor Proxmox | Auditoría de infra: CPU -60%, dual stream, face-bridge off, Docker pinned | Operativo |
| v5.3–v5.4 | Mini PC + RPi5 + Coral + Servidor Proxmox | Watchdog con crash-loop-guard vía MQTT (auto-desactiva cámaras con RTSP muerto) | Operativo |
| v5.5–v5.5.1 | Mini PC + RPi5 + Coral + Servidor Proxmox | Fix de memory leak en Frigate, restart semanal programado, auditoría post-incidente | Operativo |
| v5.6–v5.6.1 | Mini PC + RPi5 + Coral + Servidor Proxmox | Watchdog v2.0, neutralización de reboot-loop térmico (3 capas de auto-reboot en conflicto) | Operativo |
| v5.8–v5.9 | Mini PC + RPi5 + Coral + Servidor Proxmox | Rotación de credenciales, historial git purgado, DNS resiliente, capa 1 de dead-man's-switch | Operativo |

## Arquitectura

Dos LANs independientes unidas por una malla Tailscale. El mini PC del sitio "Lugar 1" es el
único consumidor RTSP de sus cámaras (vía go2rtc) y aloja Frigate + Coral TPU; el sitio
"Lugar 2" expone sus cámaras a través de un proxy RTSP sobre Tailscale.

```
                         TAILSCALE VPN MESH
        +----------------------+----------------------+
   LUGAR 1 (LAN A)                                  LUGAR 2 (LAN B)
        |                                              |
   +----+------------+    +-----------+         +------+------+
   |  Mini PC Proxmox |    | NVR/Cams  |         | Proxy RTSP  |
   |  LXC: Frigate +  |    |  cam1-4   |         | (Tailscale) |
   |  go2rtc + Coral  |    +-----------+         | cam5-6      |
   +----+------------+                           +------+------+
        |  go2rtc restream (RTSP unico consumidor)      |
        +----------------+ (Tailscale) <---------------+
                         |
                  +------+------+
                  |    RPi5     |  mpv 3x2 -> TV
                  +-------------+
```

Flujo: Cámaras → go2rtc (único consumidor RTSP) → Frigate + Coral TPU (detección) → MQTT →
Bot de Telegram / people_counter / Grafana. El visor (RPi5) consume el restream de go2rtc
por LAN — nunca toca las cámaras directamente, y sin credenciales embebidas.

Un tercer nodo (host Proxmox independiente, en un sitio separado) actúa como destino de
backup nocturno y como tercer vértice del dead-man's-switch (ver más abajo).

## Stack

- **[Frigate](https://frigate.video/)** — detección de objetos (persona/auto/mascota) en
  tiempo real sobre un **Google Coral USB TPU**, con grabación dual-stream (alta resolución
  para archivo, baja para detección).
- **[go2rtc](https://github.com/AlexxIT/go2rtc)** — único consumidor RTSP de cada cámara;
  todo lo demás (visor, grabación) consume su restream, evitando saturar cámaras baratas
  que no soportan múltiples conexiones simultáneas.
- **Reconocimiento facial** — servicio propio (`face_api/`) sobre InsightFace (ArcFace),
  desacoplado de Frigate vía un puente MQTT (`scripts/face_bridge.py`) que escucha eventos
  de persona, recorta el rostro y lo envía a la API para etiquetar.
- **Grafana + Prometheus** — dashboards de salud del sistema (CPU, temperatura, fps por
  cámara, resets del TPU) alimentados por un exporter propio de métricas de Frigate y por
  `people_counter.py` (conteo de personas/autos por zona con SQLite + métricas Prometheus).
- **Bot de Telegram** — alertas con foto filtradas por objeto/zona, comandos de estado,
  snapshots bajo demanda y entrenamiento de rostros conversacional.
- **AdGuard Home** — DNS filtrante para toda la LAN de Lugar 1, con doble upstream DoH y
  watchdog propio (`scripts/check_adguard.sh`) que alerta si el servicio cae.
- **Tailscale** — malla VPN que une los sitios sin abrir puertos al internet público; el
  acceso remoto se decide explícitamente sitio por sitio (no hay ruteo de subred abierto
  por defecto).
- **Dead-man's-switch (peer-watch)** — capa de resiliencia (`scripts/peer_watch.sh` +
  `systemd/peer-watch.{service,timer}`) donde cada sitio vigila a los otros por Tailscale
  (ping + TCP) y avisa por Telegram si un peer deja de responder; diseñado para el caso en
  que el propio host que corre el watchdog principal es el que se cae.
- **Watchdogs en capas** — un `emergency_watchdog.py` que corre en el host (no en el
  contenedor de Frigate) para sobrevivir al colapso del stack de detección, con
  crash-loop-guard por MQTT para cámaras con RTSP inestable.
- **Backups** — respaldo nocturno cifrado y verificado por checksum de las bases de datos y
  configuración hacia un tercer nodo fuera del sitio principal (`scripts/backup_to_pve.sh`),
  más `nightly_backup.sh` para un HDD externo local.

## Estructura del repo

```
.
├── LICENSE               # MIT
├── .env.example, cam_urls.env.example, peerwatch.env.example  # plantillas de secretos
├── face_api/            # servicio de reconocimiento facial (FastAPI + InsightFace)
├── scripts/              # watchdogs, bot de Telegram, exporters, backups, diagnóstico
├── systemd/              # units y timers para los servicios anteriores
├── config/                # ejemplo de config de Frigate + notas de cambio de red
└── docs/
    ├── BIBLIA_PROYECTO.md            # referencia técnica exhaustiva
    ├── historia_proyecto.md          # línea de tiempo del proyecto
    ├── diagrama_infraestructura.md   # arquitectura en detalle (Mermaid + ASCII)
    └── RUNBOOK_recuperacion_LXC200.md  # runbook de recuperación ante desastre
```

## Lecciones de infraestructura

Algunas de las más reutilizables (detalle completo en `docs/BIBLIA_PROYECTO.md` y
`docs/historia_proyecto.md`):

- **"Detectó el cable" ≠ "usa el cable".** La prueba decisiva de un tendido Ethernet es
  apagar el WiFi/AP y confirmar que el dispositivo sigue vivo por cable.
- **Un fix intermitente se confirma en horas, no en minutos.** Varias veces algo se dio
  por resuelto tras unos minutos estables y volvió a fallar horas después.
- **Watchdogs en capas pueden pisarse entre sí.** Un reboot-loop térmico terminó siendo
  causado por tres mecanismos de auto-reboot independientes (systemd, un daemon y un script
  propio) actuando sobre el mismo síntoma sin conocerse entre ellos.
- **El watchdog también puede ser el que se cae.** Si el proceso que vigila el sistema vive
  en el mismo host que falla, el fallo no se anuncia — de ahí la necesidad de un
  dead-man's-switch entre sitios independientes.
- **Revertir una mitigación es seguro solo cuando su causa raíz ya no aplica** — no antes.

## Qué NO incluye este repo

Esta es una copia sanitizada de un proyecto privado más completo. Deliberadamente **no**
se incluyen:

- **Bitácoras de sesión** (`sesiones/`, `session_context.json`) — el diario de trabajo día
  a día del proyecto real, con detalle operativo que no aporta valor técnico reutilizable.
- **Credenciales** de ningún tipo — el repo privado las mantiene en un archivo gitignored
  aparte; aquí solo quedan los `*.env.example` como plantilla.
- **Topología de red real** — IPs, nombres de host y direcciones Tailscale reales fueron
  reemplazados por placeholders genéricos en toda la documentación y los scripts.
- **Documentación comercial** — el proyecto privado incluye material para ofrecer
  instalaciones como servicio (cotización, playbook de venta/instalación a clientes); no
  se incluye aquí, este repo es solo la parte técnica.
- **Exploraciones de producto** y notas de compras/hardware personal — documentos internos
  de planeación que no aportan valor como referencia técnica pública.
- **Historial de git** — este repo se inicializó desde cero; no hereda el historial del
  repo privado (que en algún momento tuvo secretos en commits antiguos, ya purgados ahí,
  pero de todas formas no se reutiliza ese historial aquí).

Lo que sí queda es la parte técnica reutilizable: scripts, configuración de ejemplo,
arquitectura documentada y las lecciones de infraestructura aprendidas en meses de
operación real.

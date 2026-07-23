# Historia del proyecto — de 1 cámara a 6 con inteligencia artificial

> Cómo un visor de cámaras en una Raspberry Pi se convirtió en un sistema de
> videovigilancia con IA local, multi-sitio, auto-vigilado y sin cuotas de nube.
> Reconstruida a partir de los registros de sesión del proyecto.

---

## La línea del tiempo

### 🌱 v1.0 — El germen
Empezó humilde: una **Raspberry Pi 5 con mpv** para ver cámaras en la TV. Sin IA,
sin detección. Solo *"quiero ver mis cámaras en una pantalla"*.

### 🔧 v2.6 — Los primeros dolores
La Pi se recalentaba. Se añadió watchdog + monitor de temperatura.
*(Irónicamente, ese mismo watchdog térmico causaría el infierno de reboot-loops
cinco meses después.)*

### 🧠 v3.0 — Llegó el cerebro
El salto que lo cambió todo: migración a **Proxmox + Frigate + Google Coral TPU**.
De "visor" a **sistema con inteligencia artificial**: detección de personas, autos
y mascotas en hardware dedicado. Ya no era *ver* — era *entender*.

### 🚀 v4.0 → v4.4 — La explosión
En pocos días, de prototipo a plataforma:
- Arquitectura partida (**LXC 200** como cerebro) + **go2rtc** como único consumidor RTSP.
- **Dual stream 2K**: graba en alta resolución, detecta en baja para no ahogar la Coral.
- **Bot de Telegram** interactivo, **Grafana** (20+ paneles) y **Prometheus**.
- Detección a 3 fps, 8 objetos, face recognition, GenAI y LPR.

### 🔥 v5.6.1 — La prueba de fuego
Los **reboot-loops**: la Pi se reiniciaba sola cada 12–38 min. Se cazó con
**boot-forensics** y resultaron ser **3 capas de auto-reboot apiladas** (incluido
el propio watchdog térmico original). La sesión que demostró que esto ya era
infraestructura que había que diagnosticar como ingeniero, no un juguete.

### 🏆 6/6 — El hito
cam4 al fin por **cable gigabit** (verificado apagando el AP para forzar el
failover) y cam6 **recableada** (par TX cortado reparado). **Seis de seis
cámaras operativas, por primera vez.**

### 🛡️ Blindaje y productización
- **Seguridad endurecida**: credenciales rotadas y movidas a variables de entorno, con hook pre-commit anti-secretos.
- **Monitoreo térmico** del RPi5 (tras instalar el Active Cooler oficial).
- **Alertas por doble canal** (ntfy + Telegram): si un canal cae, el otro avisa.
- **DNS resiliente** (AdGuard con 2 upstreams + fallback).
- **Kit reproducible** para ofrecer el sistema como servicio a clientes.

---

## Lo que de verdad importa

No es haber pasado de 1 a 6 cámaras. Es haber pasado de **"ver"** a un sistema que
**entiende, avisa, se vigila a sí mismo y se recupera solo** — construido sin pagar
un integrador, documentando cada paso.

El secreto no fue el hardware (buena parte reciclada). Fue convertir **cada falla en
aprendizaje y escribirlo**: el reboot-loop, el cable de cam6, el flapping de cam5,
el hairpin de Tailscale. Meses de *"esto se rompió, ¿por qué?, ahora lo entiendo"*.
Eso es lo que separa un proyecto de fin de semana de un sistema que de verdad opera.

---

## Qué tiene hoy el sistema

| Capacidad | Detalle |
|---|---|
| 🎥 Cámaras | 6/6 operativas (Lugar 1 + Lugar 2), unificadas por VPN mesh Tailscale |
| 🧠 IA local | Detección de objetos por Google Coral TPU (persona/auto/mascota…) |
| 📲 Alertas | Telegram + ntfy con foto, filtradas por objeto y zona |
| 📊 Monitoreo | Grafana + Prometheus + watchdog que se auto-repara |
| 🔐 Acceso remoto | Cifrado por Tailscale, sin abrir puertos al internet |
| 💾 Respaldo | Backup nocturno cifrado y verificado por checksums |
| 🌐 Red | AdGuard Home filtrando ads/malware de toda la Lugar 1 |
| 💸 Costo recurrente | **$0/mes** — todo open source, nada de nube de pago |

> Detalle técnico completo en `docs/BIBLIA_PROYECTO.md`.

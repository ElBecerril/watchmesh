# Sistema de Videovigilancia Híbrido - Raspberry Pi 5

**Estado:** Operativo - subsistema display del sistema v5.1

> ℹ️ **Documento HISTÓRICO (v5.1).** Detalla el subsistema display (RPi5)
> tal como estaba en esa versión. NO refleja cambios posteriores: neutralización de las
> 3 capas de auto-reboot, eliminación del ptz_patrol (v5.5.1), un apagón.
> Para el estado mas reciente, ver `docs/BIBLIA_PROYECTO.md`.

---

## 1. Objetivo del Proyecto

Crear un sistema de monitoreo centralizado que permita visualizar en una sola pantalla (TV) las cámaras de seguridad ubicadas en dos sitios geográficos distintos (Lugar 1 y Lugar 2), utilizando una infraestructura segura, de bajo costo y alta disponibilidad.

### Requisitos cumplidos:
- [x] Visualización unificada de 6 cámaras en matriz 3x2
- [x] Acceso remoto a cámaras del Lugar 2 via Tailscale VPN
- [x] Bajo costo usando hardware existente
- [x] Sistema autónomo 24/7 sin intervención manual
- [x] Auto-recuperación ante fallas (watchdog)
- [x] Auto-reposicionamiento de ventanas
- [x] Inicio automático al encender
- [x] IPs estáticas configuradas
- [x] **Detección de ventanas encimadas** con auto-corrección
- [x] **Validación de dependencias** al inicio del script
- [x] **VPN check** con backoff exponencial para cámaras remotas
- [x] **Ventana de mantenimiento** 06:28-06:33 (reinicio router)
- [x] **Limpieza de procesos huérfanos** automática cada ciclo

> **Nota (v4.0+):** Desde la v4.0, el RPi5 ya NO se conecta directamente a las camaras. El Mini PC proxmox-lugar1 (Proxmox) es el unico consumidor RTSP. El RPi5 consume streams restreameados via go2rtc (`rtsp://192.0.2.20:8554/camX`). Ver README.md principal para la arquitectura completa.

---

## 2. Arquitectura de la Solución

Red Privada Virtual (VPN) Mesh usando **Tailscale**, unificando dos subredes locales.

```
SITIO A (192.0.2.x)                     SITIO B (198.51.100.x)
┌─────────────────────┐                    ┌─────────────────┐
│ proxmox-lugar1 (Proxmox)    │                    │ proxy-lugar2      │
│ LXC 200: Frigate    │◄── Tailscale ────►│ Proxy RTSP      │
│ + go2rtc + Coral    │    VPN Mesh        │ CAM5/CAM6       │
│ .10 / .20          │                    │ :5541/:5542     │
└────────┬────────────┘                    └─────────────────┘
         │
    go2rtc restream
    rtsp://.20:8554/camX
         │
    ┌────┴────┐      ┌──────────┐
    │  RPi5   │      │ NVR Dahua│
    │  Display│      │ CAM1-4   │
    │  mpv 3x2│      │ .40     │
    └─────────┘      └──────────┘
```

---

## 3. Hardware Requerido

### Sitio A (Visor Principal)
| Dispositivo | Función |
|-------------|---------|
| Raspberry Pi 5 (4GB+) | Visor de cámaras |
| NVR Dahua (o similar) | Grabador de cámaras locales |
| TV/Monitor 1080p | Pantalla de visualización |

### Sitio B (Remoto)
| Dispositivo | Función |
|-------------|---------|
| PC Linux (cualquiera) | Gateway VPN Tailscale |
| Cámaras IP | Cámaras a visualizar remotamente |

---

## 4. Configuración de Cámaras

### Formato RTSP típico

**NVR Dahua:**
```
rtsp://usuario:password@IP_NVR:554/cam/realmonitor?channel=X&subtype=1
```

**Cámaras genéricas H.265:**
```
rtsp://usuario:password@IP_CAMARA/ch0_1.h264
```

> **IMPORTANTE:** Configura tus propias URLs en el archivo `scripts/matrix_camaras.sh`

> **IMPORTANTE (v4.0+):** Las URLs RTSP se configuran en go2rtc dentro de proxmox-lugar1 LXC 200, NO en el script del RPi5. El RPi5 solo consume `rtsp://192.0.2.20:8554/camX`.

---

## 5. Script de Visualización (v3.4 (via go2rtc restream desde proxmox-lugar1))

### Características

| Función | Descripción |
|---------|-------------|
| Watchdog | Verifica cada 30s si las cámaras están activas |
| Auto-reinicio | Reinicia cámaras caídas individualmente |
| Reinicio total | Si hay 3+ fallas consecutivas |
| Cooldown | 5 min entre reinicios totales |
| Auto-reposicionamiento | Corrige ventanas mal ubicadas (usa xdotool + awk) |
| **VPN Check** | Detecta estado VPN y maneja CAM5/CAM6 independientemente |
| **Backoff exponencial** | 1min(3+), 5min(6+), 15min(10+ fallos) por cámara |
| **CPU Check** | Detecta streams congelados (<2.0% CPU por 90s) |
| **Network Monitor** | Detecta caída de red (ping -c 3) y reinicia al reconectar |
| **Ventana mantenimiento** | 06:28-06:33: suprime CHECK 3-6 durante reinicio del router |
| **Limpieza huérfanos** | Mata procesos mpv que no corresponden a ninguna cámara |
| **CAM4 fix** | Args especiales con --untimed para evitar stalls RTSP |
| **Reinicio Periódico** | Reinicio preventivo general cada 4 horas |
| **Validación Deps** | Verifica xdotool, bc, mpv, ping, pgrep, awk al inicio |
| Logging | Todo en `/tmp/matrix_camaras.log` |

### Protecciones del Watchdog (v3.3)

```
┌──────────────────────────────────────────────────────────────┐
│                    WATCHDOG v3.3                              │
├──────────────────────────────────────────────────────────────┤
│ 0. Dependencias   → Valida xdotool, bc, mpv, ping, pgrep,awk│
│                     Si falta alguna → error claro y sale     │
├──────────────────────────────────────────────────────────────┤
│    Huérfanos      → Mata procesos mpv sin cámara asignada    │
│    (cada ciclo)     Previene acumulación (7/6 → 6/6)         │
├──────────────────────────────────────────────────────────────┤
│ 0. Mantenimiento  → 06:28-06:33: CHECK 3-6 suprimidos        │
│                     Evita cascada por reinicio del router     │
├──────────────────────────────────────────────────────────────┤
│ 1. Network Mon    → Ping -c 3 al router (evita falsos +)     │
│                     Si falla → espera reconexión             │
│                     Al reconectar → reinicia TODO            │
├──────────────────────────────────────────────────────────────┤
│ 2. VPN Check      → Detecta estado VPN cada 120s             │
│                     Si cae → mata CAM5/CAM6                  │
│                     Si vuelve → reinicia CAM5/CAM6           │
├──────────────────────────────────────────────────────────────┤
│ 3. Proceso local  → Detecta procesos MPV caídos (CAM1-4)     │
│                     Con backoff exponencial por cámara        │
├──────────────────────────────────────────────────────────────┤
│ 4. Proceso VPN    → Detecta procesos MPV caídos (CAM5-6)     │
│                     Solo si VPN disponible                    │
├──────────────────────────────────────────────────────────────┤
│ 5. CPU local      → Si mpv usa <2.0% CPU por 3 ciclos (90s)  │
│                     = stream congelado → reinicia cámara     │
├──────────────────────────────────────────────────────────────┤
│ 6. CPU VPN        → Igual que 5, solo si VPN disponible       │
├──────────────────────────────────────────────────────────────┤
│ 7. Periódico      → Cada 4 horas reinicio general             │
│                     Evita degradación gradual                │
└──────────────────────────────────────────────────────────────┘
```

### Cámaras locales vs VPN

| Factor | Cámaras Locales (1-4) | Cámaras VPN (5-6) |
|--------|----------------------|-------------------|
| Conexión | Directa al NVR | Via Tailscale tunnel |
| Sensibilidad | Baja | Alta |
| Causa común de falla | Proceso MPV muere | Tunnel idle/reconexión |
| Backoff | Individual por cámara | Individual por cámara |
| VPN check | No aplica | Habilitado |

### Layout de Pantalla (1920x1080)

```
┌──────────────┬──────────────┬──────────────┐
│   CAM1-NVR   │   CAM2-NVR   │   CAM3-NVR   │
│   (0,0)      │   (640,0)    │   (1280,0)   │
│   640x540    │   640x540    │   640x540    │
├──────────────┼──────────────┼──────────────┤
│  CAM4-ICSEE  │ CAM5-REMOTA  │ CAM6-REMOTA  │
│   (0,540)    │   (640,540)  │   (1280,540) │
│   640x540    │   640x540    │   640x540    │
└──────────────┴──────────────┴──────────────┘
```

### Dependencias

```bash
# Instalar en Raspberry Pi
sudo apt update
sudo apt install mpv xdotool bc
```

> **Nota:** El script valida estas dependencias al inicio y muestra error claro si falta alguna.

### Comandos Útiles

```bash
# Ver cámaras activas
pgrep -c mpv  # Debe mostrar 6

# Ver log en tiempo real
tail -f /tmp/matrix_camaras.log

# Reinicio manual
pkill mpv; ~/matrix_camaras.sh

# Detener todo
pkill -f matrix_camaras; pkill mpv
```

---

## 6. Inicio Automático

**Flujo al encender la Raspberry Pi (v2.1):**

```
┌─────────────────────────────────────────────────────────────┐
│                    SECUENCIA DE ARRANQUE                    │
├─────────────────────────────────────────────────────────────┤
│ 1. Sistema arranca → Escritorio inicia                      │
│ 2. Autostart ejecuta matrix_camaras_autostart.sh            │
│ 3. Wrapper ESPERA compositor labwc (hasta 60 intentos)      │
│ 4. Espera 5 seg adicionales de estabilización               │
│ 5. Configura DISPLAY y WAYLAND_DISPLAY                      │
│ 6. Espera red local (ping router)                           │
│ 7. Espera Tailscale (para cámaras remotas)                  │
│ 8. Ejecuta script principal con 6 cámaras + watchdog        │
└─────────────────────────────────────────────────────────────┘
```

> **Importante:** El wrapper espera que `labwc` esté corriendo antes de abrir ventanas. Esto evita el bug de ventanas encimadas (v2.4.2).

### Crear archivo autostart

```bash
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/matrix-camaras.desktop << 'EOF'
[Desktop Entry]
Type=Application
Name=Matrix Camaras
Exec=/home/tu_usuario/matrix_camaras_autostart.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
```

---

## 7. Tailscale VPN

Para conectar cámaras de sitios remotos:

1. Instalar Tailscale en RPi y PC remoto
2. Configurar PC remoto como Subnet Router
3. Aprobar rutas en panel de Tailscale

```bash
# En PC remoto (Linux)
sudo tailscale up --advertise-routes=198.51.100.128/24
```

---

## 8. Troubleshooting

### Si se va la luz en el sitio remoto
**No hacer nada.** Configura la PC puente en BIOS para prender sola (`Restore on AC Power Loss: Power On`)

### Si una cámara aparece en negro
1. Esperar 30 segundos (el watchdog la reiniciará)
2. Si persiste, reiniciar RPi: `sudo reboot`
3. Verificar conectividad: `ping IP_CAMARA`

### Si el video se congela
El watchdog v3.3 detecta automáticamente streams congelados via CPU check y los reinicia.
Si persiste:
```bash
pkill mpv; ~/matrix_camaras.sh
```

### Si las ventanas aparecen encimadas
El watchdog v3.3 detecta ventanas encimadas automáticamente y hace reinicio total.
Si persiste después del arranque:
1. Verificar que labwc esté corriendo: `pgrep -x labwc`
2. Revisar log de autostart: `cat /tmp/matrix_autostart.log`
3. Reinicio manual: `pkill mpv; ~/matrix_camaras.sh`

### Si el script no ejecuta (error de formato)
```bash
# Verificar terminadores de línea
file ~/matrix_camaras.sh  # Debe decir "ASCII text", NO "CRLF"

# Corregir si tiene CRLF (Windows)
sed -i 's/\r$//' ~/matrix_camaras.sh
```

---

## 9. Descubrimientos Técnicos RPi 5

### Limitaciones de Hardware

| Característica | RPi 5 |
|----------------|-------|
| Decoder H.265 | ✅ Disponible (`/dev/video19`) |
| Encoder H.265 | ❌ NO disponible |
| Decoder H.264 | ❌ Removido |

**Implicaciones:**
- Las cámaras DEBEN transmitir en H.265 para aprovechar hardware
- Frigate Birdseye NO funciona (requiere encoder)
- Browser (Chromium) consume mucho CPU - usar mpv

### Comparativa de Recursos

| Método | Load | CPU | Temp |
|--------|------|-----|------|
| mpv directo | 0.73 | 5% | 65°C |
| Frigate (sin browser) | 0.76 | 7% | 61°C |
| Frigate + Chromium | 3.38 | 47% | 73°C |

**Conclusión:** mpv directo es la mejor opción para visualización.

---

## 10. Frigate NVR (Opcional)

### Para detección de personas con Coral TPU

```bash
# Docker command
docker run -d --name frigate \
  --restart=unless-stopped \
  --privileged \
  --shm-size=256m \
  -v /home/usuario/frigate/config:/config \
  -v /home/usuario/frigate/storage:/media/frigate \
  -v /dev/dri:/dev/dri \
  --device /dev/video19:/dev/video19 \
  --device /dev/dri/renderD128:/dev/dri/renderD128 \
  -p 5000:5000 -p 8554:8554 -p 8555:8555 \
  ghcr.io/blakeblackshear/frigate:stable
```

### Configuración óptima para RPi 5

```yaml
ffmpeg:
  hwaccel_args: preset-rpi-64-h265
```

---

## 11. Archivos del Proyecto

Ver la estructura del repo en el `README.md` de la raiz.

---

## 12. Lecciones Aprendidas

### CPU Threshold para Detección de Congelamiento
- El threshold inicial de **0.5%** era demasiado bajo
- Valor correcto: **2.0%** con **3 ciclos** (90 segundos)
- mpv consume ~5-6% CPU cuando reproduce activamente, pero puede usar 1-2% incluso congelado

### go2rtc restream + mpv funciona perfecto por LAN (v4.0)
- La prueba previa fue con go2rtc Y mpv en la RPi5, ambos tirando de las camaras (competian por RTSP)
- Con proxmox-lugar1 como unico consumidor RTSP y go2rtc restreameando por LAN, mpv en RPi5 funciona sin problemas
- **Solucion definitiva:** proxmox-lugar1 → go2rtc restream → RPi5 mpv (latencia minima por LAN)

### Audio Bidireccional en Cámaras ICSee
- Las cámaras 4, 5, 6 tienen micrófono y bocina
- El stream RTSP incluye audio (PCM A-law, 8000 Hz)
- **Problema:** Activar audio en todas las cámaras simultáneamente es impráctico (cacofonía)
- **Solución viable:** Toggle de audio individual o usar app móvil ICSee para hablar

### Desconexión de Red WiFi
- La red WiFi puede caer momentáneamente (visto a las 06:31)
- El watchdog v2.4 detecta esto y reinicia cámaras al reconectar
- **Importante:** La PC gateway del Lugar 2 debe tener autologin habilitado

---

## 13. Historial de Cambios

| Fecha | Versión | Cambios |
|-------|---------|---------|
| — | v1.0 | Sistema inicial con 6 cámaras |
| — | v2.0 | Agregado watchdog básico |
| — | v2.2 | Watchdog + auto-reposicionamiento + inicio automático |
| — | v2.3 | Fix bug: cambio de sed a awk para parsing de coordenadas |
| — | v2.3.1 | Documentación de limitaciones RPi 5, pruebas Frigate |
| — | v2.4 | Watchdog mejorado: CPU check, network monitor, reinicio periódico |
| — | v2.4.1 | Ajuste CPU threshold: 0.5%→2.0%, ciclos: 2→3 |
| — | v2.4.2 | Fix race condition: autostart espera labwc antes de iniciar cámaras |
| — | v2.5 | Watchdog con verificación de posiciones: detecta ventanas encimadas |
| — | v2.5.1 | Validación de dependencias al inicio + ping -c 3 para evitar falsos positivos |
| — | v2.6 | Hardware watchdog + temperature monitor |
| — | **v3.3** | **Fix CAM4 freezes, ventana mantenimiento, limpieza huérfanos, eliminar PTZ** |

### Lecciones Aprendidas v3.3

**Problema 1:** CAM4 (ICSee PTZ) acumuló 650 freezes en 8 días (48% del total).
- **Causa:** Faltaba `--untimed` en MPV_ARGS_CAM4. Sin este flag, mpv sincroniza con el reloj RTSP causando stalls.
- **Solución:** Agregar `--untimed`, cambiar `--cache=no`, reducir buffers.

**Problema 2:** Cascada de reinicios cada día a las 06:30.
- **Causa:** El router reinicia a las 06:30 (~28s de caída). CHECK 3-6 disparan individualmente.
- **Solución:** Ventana de mantenimiento 06:28-06:33 que suprime CHECK 3-6. CHECK 1 (red) maneja la reconexión correctamente con full_restart.

**Problema 3:** Consistentemente 7 procesos mpv cuando deberían ser 6.
- **Causa:** Procesos zombie que escapan al `pkill -f "title=$title"`.
- **Solución:** `cleanup_orphan_mpv()` al inicio de cada ciclo mata PIDs no asociados a cámaras conocidas.

**Problema 4:** PTZ patrol y PTZ stop eran innecesarios.
- **Causa:** Los scripts PTZ se crearon para patrullar cámaras, pero la función resultó inútil y molesta.
- **Solución:** Eliminar ambos scripts (`ptz_patrol.sh`, `ptz_stop_patrol.sh`) y deshabilitar `ptz-stop-patrol.service`.

---

### Lecciones Aprendidas v2.5.1

**Problema 1:** Script fallaba silenciosamente si `bc` no estaba instalado (CPU check no funcionaba).

**Solución:** Validar dependencias al inicio con mensaje de error claro:
```bash
for cmd in xdotool bc mpv ping pgrep; do
    if ! command -v $cmd &> /dev/null; then
        echo "ERROR CRÍTICO: $cmd no está instalado"
        exit 1
    fi
done
```

**Problema 2:** Ping con `-c 1` causaba falsos positivos por pérdida ocasional de paquetes.

**Solución:** Usar `ping -c 3` para requerir 3 paquetes perdidos antes de declarar red caída.

**Revisión de feedback externo:**

| Sugerencia | Veredicto | Razón |
|------------|-----------|-------|
| Usar `hwdec=auto` en mpv | PARCIAL | Sistema ya funciona bien a 35% CPU |
| Bajar CPU threshold a 0.5% | INCORRECTO | Ya probamos 0.5% y causaba falsos positivos |
| Configurar `gpu_mem` en raspi-config | OBSOLETO | RPi 5 usa CMA dinámico, no gpu_mem |
| Usar ping -c 3 en vez de -c 1 | CORRECTO | Implementado en v2.5.1 |
| Validar dependencias al inicio | CORRECTO | Implementado en v2.5.1 |

### Lecciones Aprendidas v2.5

**Mejora:** El watchdog ahora verifica que las ventanas de las cámaras estén en sus posiciones correctas.

**Nuevas funciones:**
- `check_overlapping()`: Detecta si 2+ ventanas están en la misma posición
- `check_camera_position()`: Verifica si una cámara está en su posición correcta (tolerancia 10px)
- Si se detecta encimamiento, hace reinicio total automático
- Si una ventana está mal posicionada, la corrige con xdotool

**Checks del watchdog v2.5 (cada 30s):**
1. Conectividad de red (ping router)
2. **Posiciones de ventanas (NUEVO)**
3. Procesos caídos
4. Streams congelados (CPU < 2%)
5. Reinicio periódico (cada 4h)

### Lecciones Aprendidas v2.4.2

**Problema:** Ventanas de cámaras aparecían encimadas después de un reinicio del sistema.

**Causa raíz:** Race condition - el script de cámaras iniciaba ANTES de que el compositor (labwc) estuviera listo.

**Timeline del bug:**
```
07:06:32 - Sistema arranca
07:07:00 - Script cámaras INICIA (muy pronto!)
07:07:04 - CAM1 intenta abrir ventana
07:08:XX - labwc (compositor) INICIA ← después del script
07:08:59 - CAM2 abre (~2 min delay)
```

**Solución:** Modificar `matrix_camaras_autostart.sh` para:
1. Esperar que `labwc` esté corriendo (hasta 60 intentos)
2. Esperar 5 seg adicionales de estabilización
3. Configurar variables DISPLAY/WAYLAND_DISPLAY
4. Luego esperar red y Tailscale

---

## Licencia

Este proyecto es de código abierto. Úsalo y modifícalo libremente.

## Contribuciones

¿Encontraste un bug o tienes una mejora? Abre un issue o pull request.

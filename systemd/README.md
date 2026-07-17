# systemd timers (RES-9)

Units que reemplazan crons frágiles por `systemd-timer` con `Persistent=true`
(si el host estaba apagado a la hora del disparo —apagón / NTP aún sin sincronizar—
el job corre al volver, en vez de perderse). **Nada de esto está desplegado todavía**:
son ficheros del repo para instalar de forma supervisada.

| Unit | Dónde corre | Qué hace | Reemplaza |
|------|-------------|----------|-----------|
| `backup-to-pve.{service,timer}` | HOST proxmox-lugar1 | Backup diario 02:30 de `people_counter.db` + config Frigate a pve (`scripts/backup_to_pve.sh`) | — (nuevo, RES-2) |
| `rpi5-temp-exporter.{service,timer}` | RPi5 | Cada 60s exporta temp/throttled a node_exporter textfile (`scripts/rpi5_node_textfile_temp.sh`) | — (nuevo, RES-4b) |
| `frigate-weekly-restart.{service,timer}` | LXC 200 | Restart Frigate domingo 04:00 (memory leak) | cron `dom 04:00` |
| `peer-watch.{service,timer}` | RPi5 (capa 1) | Cada 5 min vigila Lugar 2 + pve por Tailscale y alerta por Telegram solo en transición (`scripts/peer_watch.sh`) | — (nuevo, dead-man's-switch) |

> **Excepción:** `peer-watch.{service,timer}` **SÍ está desplegado** en la RPi5
> (capa 1 del dead-man's-switch). Los ficheros del repo son la copia
> versionada de lo que ya corre en vivo, para reproducibilidad / kit cliente.

## Prerrequisito común (SEC-7)
`backup-to-pve.service` lee secretos de `/etc/vigilancia/vigilancia.env`
(crear desde `.env.example`, rellenar con valores reales, `chmod 600`).

## Instalación

### proxmox-lugar1 (backup-to-pve)
```bash
sudo install -m755 scripts/backup_to_pve.sh /usr/local/bin/
sudo install -m755 scripts/alert_notify.sh /usr/local/bin/   # RES-8 (opcional, respaldo ntfy)
sudo install -d /etc/vigilancia && sudo cp .env.example /etc/vigilancia/vigilancia.env
sudo chmod 600 /etc/vigilancia/vigilancia.env   # <-- editar con valores reales
sudo cp systemd/backup-to-pve.{service,timer} /etc/systemd/system/
# Probar primero en seco:
sudo env $(grep -v '^#' /etc/vigilancia/vigilancia.env | xargs) /usr/local/bin/backup_to_pve.sh --dry-run
sudo systemctl daemon-reload && sudo systemctl enable --now backup-to-pve.timer
systemctl list-timers backup-to-pve.timer
```

### RPi5 (temp exporter)
Requiere `node_exporter` con `--collector.textfile.directory=/var/lib/node_exporter/textfile`.
```bash
sudo install -m755 scripts/rpi5_node_textfile_temp.sh /usr/local/bin/
sudo install -d -o node_exporter -g node_exporter /var/lib/node_exporter/textfile
sudo cp systemd/rpi5-temp-exporter.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now rpi5-temp-exporter.timer
# Verificar:  cat /var/lib/node_exporter/textfile/rpi5_thermal.prom
```
Luego añadir un panel Grafana con `rpi5_temp_celsius` y alerta sobre
`rpi5_under_voltage_occurred == 1`.

### LXC 200 (frigate restart) — migración del cron
Ajustar `FRIGATE_CONTAINER` en el `.service` si el contenedor no se llama `frigate`
(con docker compose, usar el nombre del stack).
```bash
sudo cp systemd/frigate-weekly-restart.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now frigate-weekly-restart.timer
sudo crontab -l   # <-- quitar la línea 'dom 04:00 ... docker restart frigate' tras verificar el timer
```

### RPi5 (peer-watch — dead-man's-switch capa 1) — YA DESPLEGADO
Lee secretos de `/etc/peerwatch/peerwatch.env` (token Telegram), no de `vigilancia.env`.
La lista de peers (`Lugar 2`, `pve`) está dentro del propio `peer_watch.sh`.
```bash
sudo install -m755 scripts/peer_watch.sh /usr/local/bin/
sudo install -d /etc/peerwatch && sudo cp peerwatch.env.example /etc/peerwatch/peerwatch.env
sudo chmod 600 /etc/peerwatch/peerwatch.env   # <-- editar con token/chat_id reales
sudo cp systemd/peer-watch.{service,timer} /etc/systemd/system/
# Probar a mano (debe loguear "<peer> OK" y, si hay caída real, mandar Telegram):
sudo /usr/local/bin/peer_watch.sh
sudo systemctl daemon-reload && sudo systemctl enable --now peer-watch.timer
systemctl list-timers peer-watch.timer
```
Notas de la capa 1:
- `reachable()` reintenta el `tailscale ping` porque el path DERP se **enfría** entre
  corridas (idle 5 min) y el 1er ping en frío falla → el reintento calienta la ruta.
- Regla anti-tormenta de **auto-aislamiento**: si caen TODOS los peers a la vez, 1 sola
  alerta "AISLADO" (problema de mi red), no N alertas por-peer.
- Para capas 2/3 (Lugar 2 / sitio 3) considerar bot/topic Telegram separado solo-infra
  para acotar el blast radius del token.

## Notas
- `Persistent=true` guarda la última ejecución en `/var/lib/systemd/timers/`; tras un
  apagón el job atrasado corre una vez al arrancar.
- `RandomizedDelaySec` evita que todo dispare exactamente al mismo segundo.
- Para revertir: `systemctl disable --now <unit>.timer` y restaurar el cron.

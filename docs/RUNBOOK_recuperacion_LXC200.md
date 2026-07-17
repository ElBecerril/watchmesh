# Runbook — Recuperación del LXC 200 (vigilancia) tras desastre

> **RES-3.** El proxmox-lugar1 es un **SPOF total**: si muere el host o se corrompe el LXC 200,
> se cae Frigate + go2rtc + Coral + Grafana + Prometheus + people_counter de golpe.
> Este runbook lleva de "LXC 200 perdido" a "operativo" paso a paso.
>
> **Estado:** La **prueba de restore real está PENDIENTE** (👤) —
> ver §6. Un runbook no probado no es un plan de recuperación.

---

## 0. Datos de referencia

| Qué | Valor |
|-----|-------|
| Host | proxmox-lugar1 (Proxmox 8.4) — `192.0.2.10` / TS `100.64.10.2` |
| Contenedor | LXC **200**, hostname `vigilancia` |
| Recursos | 4 cores, 12 GB RAM, 200 GB disco |
| Datos de app | `/opt/vigilancia/` (config Frigate, `frigate.db`, `people_counter.db`, storage) |
| Backups DB/config | servidor **pve** `100.64.10.6:/var/backups/vigilancia/<fecha>/` (RES-2) |
| Backups vzdump | (definir destino — ver §6) |
| Credenciales | `CREDENCIALES_REALES.md` (gitignored) |

Puertos del LXC 200: 5000 (Frigate), 8554 (go2rtc RTSP), 8555 (WebRTC), 1984 (go2rtc API),
1883 (MQTT), 3000 (Grafana), 9090 (Prometheus), 9101/9102 (exporters).

---

## 1. Triage — ¿qué está roto?

Desde el host proxmox-lugar1 (`ssh root@192.0.2.10`):

```bash
pct list                       # ¿existe el 200? ¿status running/stopped?
pct status 200
systemctl status nat-tailscale # NAT LXC->Tailscale (necesario para cam5/cam6)
df -h /                        # ¿disco del host lleno? (causa típica de LXC que no arranca)
tailscale status | head        # ¿el host ve a proxy-lugar2 y pve?
```

Árbol de decisión:
- **LXC existe y arranca pero Frigate falla** → §4 (recuperar servicios).
- **LXC corrupto / no arranca** → §3 (restore desde vzdump).
- **Host proxmox-lugar1 muerto (HW)** → §2 (rehidratar en otro Proxmox: pve).

---

## 2. Caso peor: host proxmox-lugar1 muerto → levantar en pve

`pve` (`100.64.10.6`, Dual Xeon, ~100 GB libres) está en el mesh y puede hospedar
temporalmente el LXC.

1. Copiar el último vzdump a pve (o restaurar desde donde se guarde, §6).
2. En pve: `pct restore <nuevo-id> <vzdump.tar.zst> --storage local-lvm`
3. Ajustar red: el LXC asume LAN `192.0.2.x` de LUGAR1. En pve (Lugar 2, `198.51.100.x`)
   necesitará IP nueva + revisar el NAT a Tailscale (§5). Las cámaras locales cam1-4 NO
   serán alcanzables desde el Lugar 2: en modo degradado solo cam5/cam6 (que ya vienen por
   Tailscale). Documentar esto como **operación degradada** hasta que vuelva el proxmox-lugar1.
4. Restaurar `people_counter.db` y config desde el backup de pve (§3.3) si el vzdump es viejo.

> Objetivo de este caso: recuperar **grabación + monitoreo del Lugar 2** y el histórico del
> contador, no la paridad total. La paridad vuelve al reparar/reemplazar el proxmox-lugar1.

---

## 3. Restore del LXC desde vzdump (host vivo, LXC perdido)

### 3.1 Localizar el backup
```bash
ls -lt /var/lib/vz/dump/vzdump-lxc-200-*.tar.zst   # o el storage de backups configurado
```

### 3.2 Restaurar
```bash
pct stop 200 2>/dev/null; pct destroy 200   # SOLO si el 200 corrupto debe reemplazarse
pct restore 200 /var/lib/vz/dump/vzdump-lxc-200-<fecha>.tar.zst \
    --storage local-lvm --rootfs local-lvm:200
pct set 200 --memory 12288 --cores 4        # confirmar recursos
pct start 200
```

### 3.3 Restaurar DB/config recientes desde pve (RES-2)
El vzdump puede tener días; el backup diario de pve es más fresco para las DB:
```bash
# en el host proxmox-lugar1
LATEST=$(ssh root@100.64.10.6 'ls -1d /var/backups/vigilancia/20* | tail -1')
ssh root@100.64.10.6 "cat $LATEST/people_counter.db" > /tmp/pc.db
ssh root@100.64.10.6 "cat $LATEST/config.yml"        > /tmp/config.yml
# parar Frigate/people_counter en el LXC ANTES de pisar las DB:
pct exec 200 -- systemctl stop people-counter
pct exec 200 -- docker stop frigate
pct push 200 /tmp/pc.db     /opt/vigilancia/people_counter.db
pct push 200 /tmp/config.yml /opt/vigilancia/config/config.yml
```

---

## 4. Recuperar servicios dentro del LXC

```bash
pct exec 200 -- docker ps -a                     # ¿frigate up?
pct exec 200 -- docker compose -f /opt/vigilancia/docker-compose.yml up -d
pct exec 200 -- systemctl start people-counter
# Validaciones:
curl -s http://192.0.2.20:5000/api/stats | head        # Frigate vivo
curl -s http://192.0.2.20:1984/api/streams             # go2rtc: ver consumidores
pct exec 200 -- mosquitto_sub -t 'frigate/#' -C 3 -W 5     # MQTT fluye
```

cam6_remota debe quedar **OFF** (watchdog la fuerza, cable UV). Si cam5/cam6 no llegan,
revisar NAT (§5).

---

## 5. NAT Tailscale (cam5/cam6 del Lugar 2)

El LXC 200 NO tiene Tailscale propio: sale por NAT del host (v4.6).
```bash
systemctl status nat-tailscale          # en el HOST proxmox-lugar1
sysctl net.ipv4.ip_forward              # debe ser 1
pct exec 200 -- ip route | grep 100.64  # ruta 100.64.0.0/10 via 192.0.2.10
# Probar alcance al proxy del Lugar 2:
pct exec 200 -- curl -s -m5 rtsp://100.64.10.3:5541 >/dev/null; echo $?
```
Si falla: `systemctl restart nat-tailscale` (espera a `tailscale0`, usa `-C` anti-duplicado).

---

## 6. PENDIENTE — probar el restore (👤)

Este runbook **no está validado**. Para cerrarlo:

1. **Definir y automatizar el vzdump del LXC 200**: hoy no hay constancia de un vzdump
   programado. Crear backup Proxmox (`Datacenter → Backup`) del CT 200 a un storage que
   sobreviva a la muerte del proxmox-lugar1 (NAS, pve, o el HDD de RES-2). Sin esto, §3 no aplica.
2. **Ensayar un restore** a un CT de prueba (id 299) desde el último vzdump y arrancarlo
   sin tocar el 200 productivo. Medir cuánto tarda y anotarlo aquí.
3. Verificar que el backup de pve (RES-2) contiene `people_counter.db` + `config.yml` y que
   abren (`sqlite3 people_counter.db 'PRAGMA integrity_check;'`).
4. Anotar el **RTO real** (tiempo hasta operativo) observado en el ensayo.

> Una vez ensayado, quitar el banner "PENDIENTE" del §6 y de la cabecera.

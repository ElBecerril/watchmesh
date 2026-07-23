# Deploy Face Recognition - VM 110 en Proxmox

## Paso 1: Crear VM 110

En el host Proxmox (100.64.10.6):

```bash
qm create 110 \
  --name face-recognition \
  --ostype l26 \
  --cores 8 \
  --memory 8192 \
  --net0 virtio,bridge=vmbr0 \
  --scsihw virtio-scsi-single \
  --scsi0 falcon-nvme:50 \
  --cdrom local:iso/ubuntu-24.04.2-live-server-amd64.iso \
  --boot order=scsi0 \
  --onboot 1 \
  --machine q35

qm start 110
```

Instalar Ubuntu 24.04 Server via VNC/console.

## Paso 2: Post-instalacion en VM 110

```bash
# IP estatica (ajustar segun la red)
# Editar /etc/netplan/00-installer-config.yaml con IP fija en 198.51.100.x

# Instalar Tailscale
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up

# Instalar Docker
curl -fsSL https://get.docker.com | sh
systemctl enable docker

# Instalar dependencias
apt install -y python3-pip git
```

## Paso 3: Desplegar el servicio

```bash
# Copiar archivos (desde la maquina local o via git)
mkdir -p /opt/face-recognition
cd /opt/face-recognition

# Copiar: Dockerfile, main.py, face_db.py, requirements.txt, docker-compose.yml
# Opcion A: scp desde la maquina local
# Opcion B: git clone del repo

# Construir y levantar
docker compose up -d --build

# Verificar
docker logs face-recognition -f
curl http://localhost:5050/health
```

## Paso 4: Desplegar face_bridge en LXC 200 (proxmox-lugar1)

```bash
# Desde el host proxmox-lugar1
pct exec 200 -- bash

# Instalar dependencia
pip3 install paho-mqtt requests

# Copiar face_bridge.py
# scp o copiar manualmente a /opt/vigilancia/face_bridge.py

# Crear servicio systemd
cat > /etc/systemd/system/face-bridge.service << 'EOF'
[Unit]
Description=Face Bridge - MQTT to InsightFace API
After=network.target mosquitto.service
Wants=mosquitto.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/vigilancia/face_bridge.py
Restart=always
RestartSec=10
Environment=MQTT_HOST=127.0.0.1
Environment=FRIGATE_URL=http://127.0.0.1:5000
Environment=FRIGATE_USER=admin
Environment=FRIGATE_PASS=<PASSWORD>
Environment=FACE_API_URL=http://<TAILSCALE_IP_VM110>:5050
Environment=COOLDOWN_SECONDS=30
Environment=MIN_CONFIDENCE=0.45

[Install]
WantedBy=multi-user.target
EOF

# IMPORTANTE: Reemplazar <TAILSCALE_IP_VM110> con la IP Tailscale real de la VM 110

systemctl daemon-reload
systemctl enable face-bridge
systemctl start face-bridge
journalctl -u face-bridge -f
```

## Paso 5: Entrenar rostros

Usar las fotos de PERSONA1 que ya estan entrenadas en Frigate:

```bash
# Desde Frigate, exportar las imagenes de entrenamiento
# Las fotos estan en el directorio de face recognition de Frigate

# Entrenar via API (desde cualquier maquina con acceso)
curl -X POST "http://<TAILSCALE_IP_VM110>:5050/train/PERSONA1" \
  -F "file=@foto_persona1_1.jpg"

# Repetir para cada muestra
curl -X POST "http://<TAILSCALE_IP_VM110>:5050/train/PERSONA1" \
  -F "file=@foto_persona1_2.jpg"

# Verificar
curl http://<TAILSCALE_IP_VM110>:5050/faces
```

## Paso 6: Desactivar face recognition en Frigate

Verificar que en frigate.yml:

```yaml
face_recognition:
  enabled: false
```

Si estaba activado, reiniciar Frigate:
```bash
docker compose -f /opt/vigilancia/docker-compose.yml restart frigate
```

## Verificacion

```bash
# 1. Face API health
curl http://<TAILSCALE_IP_VM110>:5050/health

# 2. Probar reconocimiento con imagen
curl -X POST http://<TAILSCALE_IP_VM110>:5050/recognize \
  -F "file=@test_photo.jpg"

# 3. Verificar bridge
journalctl -u face-bridge -f
# Caminar frente a cam5 o cam6 y ver logs

# 4. Verificar sub_label en Frigate UI
# Events > filtrar por cam5/cam6 > verificar sub_label
```

## Recursos esperados

| Componente | CPU | RAM | Disco |
|-----------|-----|-----|-------|
| VM 110 idle | ~1% | ~2.5GB | ~3GB |
| VM 110 inference | ~10-20% (1 cara) | ~2.5GB | ~3GB |
| face_bridge (LXC 200) | <1% | ~30MB | ~5MB |

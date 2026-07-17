#!/bin/bash
# ============================================================
# Setup HDD Backup - Ejecutar UNA VEZ en HOST proxmox-lugar1
# despues de conectar el HDD al puerto USB 3.0
#
# Uso: bash setup_hdd_backup.sh
# ============================================================

set -euo pipefail

echo "=== Setup HDD Backup ==="
echo ""

# 1. Detectar HDD
echo "--- Detectando HDD USB ---"
NEW_DISK=$(lsblk -dpno NAME,TRAN | grep usb | awk '{print $1}' | head -1)

if [ -z "$NEW_DISK" ]; then
    echo "ERROR: No se detecta disco USB. Verifica la conexion."
    echo "Discos actuales:"
    lsblk
    exit 1
fi

echo "HDD detectado: $NEW_DISK"
lsblk "$NEW_DISK"
echo ""

# 2. Confirmar formateo
PARTITION="${NEW_DISK}1"
read -p "FORMATEAR $NEW_DISK como ext4? Esto BORRA TODO el disco. (si/no): " confirm
if [ "$confirm" != "si" ]; then
    echo "Cancelado."
    exit 0
fi

# 3. Particionar y formatear
echo "Creando particion..."
parted -s "$NEW_DISK" mklabel gpt
parted -s "$NEW_DISK" mkpart primary ext4 0% 100%
sleep 2

echo "Formateando como ext4..."
mkfs.ext4 -L backup-vigilancia "$PARTITION"

# 4. Crear punto de montaje
mkdir -p /mnt/backup-hdd

# 5. Agregar a fstab para montaje automatico
UUID=$(blkid -s UUID -o value "$PARTITION")
echo "UUID del disco: $UUID"

# Verificar que no este ya en fstab
if ! grep -q "$UUID" /etc/fstab; then
    echo "UUID=$UUID /mnt/backup-hdd ext4 defaults,nofail,x-systemd.device-timeout=10 0 2" >> /etc/fstab
    echo "Agregado a /etc/fstab con nofail (no bloquea boot si no esta conectado)"
else
    echo "Ya existe en fstab"
fi

# 6. Montar
mount /mnt/backup-hdd
echo "Montado en /mnt/backup-hdd"

# 7. Crear estructura
mkdir -p /mnt/backup-hdd/recordings
mkdir -p /mnt/backup-hdd/clips
echo "Estructura creada"

# 8. Actualizar device en nightly_backup.sh
SCRIPT="/root/nightly_backup.sh"
if [ -f "$SCRIPT" ]; then
    sed -i "s|HDD_DEVICE=.*|HDD_DEVICE=\"$PARTITION\"|" "$SCRIPT"
    echo "Device actualizado en $SCRIPT"
fi

# 9. Instalar timer systemd
cat > /etc/systemd/system/nightly-backup.service << 'EOF'
[Unit]
Description=Nightly Backup - Recordings to HDD
After=network.target

[Service]
Type=oneshot
ExecStart=/root/nightly_backup.sh
StandardOutput=journal
StandardError=journal
TimeoutStartSec=3600
EOF

cat > /etc/systemd/system/nightly-backup.timer << 'EOF'
[Unit]
Description=Nightly Backup Timer - 02:00 daily

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable nightly-backup.timer
systemctl start nightly-backup.timer
echo "Timer systemd habilitado (02:00 diario)"

# 10. Verificar
echo ""
echo "=== SETUP COMPLETO ==="
echo "  HDD: $PARTITION ($UUID)"
echo "  Montaje: /mnt/backup-hdd"
echo "  Capacidad: $(df -h /mnt/backup-hdd | tail -1 | awk '{print $2}')"
echo "  Script: /root/nightly_backup.sh"
echo "  Timer: nightly-backup.timer (02:00)"
echo ""
echo "Para probar: /root/nightly_backup.sh --dry-run"
echo "Para verificar timer: systemctl list-timers nightly-backup.timer"

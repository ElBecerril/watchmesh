# Cambio de Red - proxmox-lugar1

## Opcion 1: Copiar archivo completo

### Para LUGAR1:
```bash
cat > /etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback

iface enp1s0 inet manual

auto vmbr0
iface vmbr0 inet static
        address 192.0.2.10/24
        gateway 192.0.2.1
        bridge-ports enp1s0
        bridge-stp off
        bridge-fd 0

source /etc/network/interfaces.d/*
EOF

systemctl restart networking
```

### Para LUGAR2:
```bash
cat > /etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback

iface enp1s0 inet manual

auto vmbr0
iface vmbr0 inet static
        address 198.51.100.10/24
        gateway 198.51.100.254
        bridge-ports enp1s0
        bridge-stp off
        bridge-fd 0

source /etc/network/interfaces.d/*
EOF

systemctl restart networking
```

## Opcion 2: Solo cambiar IP y gateway con sed

### Para LUGAR1:
```bash
sed -i 's/198.51.100.10/192.0.2.10/g; s/198.51.100.254/192.0.2.1/g' /etc/network/interfaces
systemctl restart networking
```

### Para LUGAR2:
```bash
sed -i 's/192.0.2.10/198.51.100.10/g; s/192.0.2.1/198.51.100.254/g' /etc/network/interfaces
systemctl restart networking
```

## Verificar conectividad

```bash
# Verificar IP
ip addr show vmbr0

# Verificar gateway
ip route

# Probar internet
ping -c 3 8.8.8.8

# Verificar Tailscale
tailscale status
```

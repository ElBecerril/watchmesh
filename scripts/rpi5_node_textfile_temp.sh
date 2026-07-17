#!/bin/bash
# ============================================================
# rpi5_node_textfile_temp.sh  (RES-4b) — Exporta temp/throttled del RPi5
#                                          a Prometheus (textfile collector)
#
# Contexto: el reboot-loop nacio de cooling subperformante
# (delta 45°C, fan tope 3894 RPM) y un apagon dejo throttled=0x50000
# (under-voltage + throttling ocurrieron). Hoy NO hay metrica historica de la
# temperatura ni del throttling del RPi5 en Grafana. Esto lo arregla.
#
# Como funciona:
#   node_exporter corre con  --collector.textfile.directory=<DIR>  y lee todos
#   los *.prom de ese dir. Este script escribe ahi (de forma atomica) las
#   metricas del Pi cada vez que se ejecuta (via systemd-timer cada 30-60s).
#
# Metricas expuestas:
#   rpi5_temp_celsius                 temperatura SoC
#   rpi5_throttled_flags              valor crudo de get_throttled (hex->dec)
#   rpi5_under_voltage_now            1 si bit0 activo AHORA
#   rpi5_throttling_now               1 si bit2 activo AHORA
#   rpi5_under_voltage_occurred       1 si bit16 (ocurrio desde el boot)
#   rpi5_throttling_occurred          1 si bit18 (ocurrio desde el boot)
#   rpi5_arm_freq_hz / rpi5_core_volt_v
#   rpi5_fan_rpm                      si hay cooling_device/fan via sysfs
#
# Despliegue (en el RPi5):
#   sudo cp rpi5_node_textfile_temp.sh /usr/local/bin/
#   sudo install -d -o node_exporter -g node_exporter /var/lib/node_exporter/textfile
#   # timer: rpi5-temp-exporter.timer (cada 60s) -> ver systemd/
#   # node_exporter:  --collector.textfile.directory=/var/lib/node_exporter/textfile
# ============================================================

set -uo pipefail

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
OUT="${TEXTFILE_DIR}/rpi5_thermal.prom"
TMP="$(mktemp "${TEXTFILE_DIR}/.rpi5_thermal.XXXXXX.prom" 2>/dev/null || mktemp)"
VCGENCMD="${VCGENCMD:-vcgencmd}"

cleanup() { rm -f "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

if ! command -v "$VCGENCMD" >/dev/null 2>&1; then
    echo "rpi5_node_textfile_temp: vcgencmd no disponible" >&2
    exit 1
fi

# --- Temperatura ---
# Formato: temp=54.3'C
temp_raw="$($VCGENCMD measure_temp 2>/dev/null || echo "temp=0'C")"
temp="${temp_raw#temp=}"; temp="${temp%\'C}"

# --- Throttled (hex) ---
# Formato: throttled=0x50000
thr_raw="$($VCGENCMD get_throttled 2>/dev/null || echo 'throttled=0x0')"
thr_hex="${thr_raw#throttled=}"
thr_dec=$(( thr_hex ))   # bash interpreta 0x...

bit() { echo $(( (thr_dec >> $1) & 1 )); }
uv_now="$(bit 0)"
thr_now="$(bit 2)"
uv_occ="$(bit 16)"
thr_occ="$(bit 18)"

# --- Frecuencia ARM (Hz) y voltaje core (V) ---
freq_raw="$($VCGENCMD measure_clock arm 2>/dev/null || echo '=0')"
arm_hz="${freq_raw##*=}"
volt_raw="$($VCGENCMD measure_volts core 2>/dev/null || echo 'volt=0V')"
core_v="${volt_raw#volt=}"; core_v="${core_v%V}"

# --- Fan RPM (best-effort via sysfs hwmon) ---
fan_rpm=""
for f in /sys/class/hwmon/hwmon*/fan1_input /sys/devices/platform/cooling_fan/hwmon/hwmon*/fan1_input; do
    [[ -r "$f" ]] && { fan_rpm="$(cat "$f" 2>/dev/null)"; break; }
done

# --- Escribir .prom (atomico) ---
{
    echo "# HELP rpi5_temp_celsius SoC temperature of the RPi5 (vcgencmd)."
    echo "# TYPE rpi5_temp_celsius gauge"
    echo "rpi5_temp_celsius ${temp:-0}"
    echo "# HELP rpi5_throttled_flags Raw get_throttled bitmask (decimal)."
    echo "# TYPE rpi5_throttled_flags gauge"
    echo "rpi5_throttled_flags ${thr_dec}"
    echo "# HELP rpi5_under_voltage_now Under-voltage active right now (bit0)."
    echo "# TYPE rpi5_under_voltage_now gauge"
    echo "rpi5_under_voltage_now ${uv_now}"
    echo "# HELP rpi5_throttling_now ARM frequency capped right now (bit2)."
    echo "# TYPE rpi5_throttling_now gauge"
    echo "rpi5_throttling_now ${thr_now}"
    echo "# HELP rpi5_under_voltage_occurred Under-voltage has occurred since boot (bit16)."
    echo "# TYPE rpi5_under_voltage_occurred gauge"
    echo "rpi5_under_voltage_occurred ${uv_occ}"
    echo "# HELP rpi5_throttling_occurred Throttling has occurred since boot (bit18)."
    echo "# TYPE rpi5_throttling_occurred gauge"
    echo "rpi5_throttling_occurred ${thr_occ}"
    echo "# HELP rpi5_arm_freq_hz Current ARM clock frequency (Hz)."
    echo "# TYPE rpi5_arm_freq_hz gauge"
    echo "rpi5_arm_freq_hz ${arm_hz:-0}"
    echo "# HELP rpi5_core_volt_v Core voltage (V)."
    echo "# TYPE rpi5_core_volt_v gauge"
    echo "rpi5_core_volt_v ${core_v:-0}"
    if [[ -n "$fan_rpm" ]]; then
        echo "# HELP rpi5_fan_rpm Cooling fan speed (RPM)."
        echo "# TYPE rpi5_fan_rpm gauge"
        echo "rpi5_fan_rpm ${fan_rpm}"
    fi
} > "$TMP"

# mktemp crea el fichero 0600; node_exporter corre como otro usuario (p.ej.
# 'prometheus') y necesita LEERLO -> 0644 o el textfile collector da scrape_error=1.
chmod 0644 "$TMP"
mv -f "$TMP" "$OUT"

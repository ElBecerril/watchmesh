#!/usr/bin/env bash
# check_hdd_smart.sh — clasifica un disco (usado) como SANO / SOSPECHOSO / RECHAZAR.
# Pensado para vetar HDD de segunda mano antes de confiarles un backup.
# Uso:  sudo ./check_hdd_smart.sh /dev/sdX        (ej. /dev/sdb)
# Nota: para discos en DOCK/case USB, el puente SATA-USB a veces oculta el SMART;
#       el script reintenta con '-d sat' automaticamente.
set -u

DEV="${1:-}"
if [ -z "$DEV" ] || [ ! -b "$DEV" ]; then
  echo "Uso: sudo $0 /dev/sdX"
  echo
  echo "Discos detectados:"
  lsblk -dpno NAME,SIZE,MODEL 2>/dev/null | grep -E '/dev/sd' || echo "  (ninguno)"
  exit 2
fi
command -v smartctl >/dev/null 2>&1 || { echo "Falta smartctl. Instala:  sudo apt install smartmontools"; exit 2; }

# --- obtener SMART (probar puente USB si hace falta) ---
OUT="$(smartctl -a "$DEV" 2>/dev/null)"
if ! echo "$OUT" | grep -qiE 'overall-health|Reallocated_Sector|Health Status|Power_On_Hours'; then
  OUT="$(smartctl -a -d sat "$DEV" 2>/dev/null)"   # dock/case USB
  BRIDGE="(leido via -d sat / puente USB)"
else
  BRIDGE=""
fi
if [ -z "$OUT" ]; then
  echo "RECHAZAR ❌  — no se pudo leer SMART de $DEV (puente USB incompatible o disco mudo)."
  exit 1
fi

# --- extraer atributos (col 10 = RAW del atributo) ---
raw() { echo "$OUT" | awk -v a="$1" 'tolower($2)==tolower(a){v=$10} END{if(v=="")print "NA"; else print v}'; }
num() { case "$1" in ''|*[!0-9]*) echo -1;; *) echo "$1";; esac; }

MODEL=$(echo "$OUT"  | grep -iE 'Device Model|Model Number' | head -1 | cut -d: -f2- | sed 's/^ *//')
SERIAL=$(echo "$OUT" | grep -iE 'Serial Number'            | head -1 | cut -d: -f2- | sed 's/^ *//')
CAP=$(echo "$OUT"    | grep -iE 'User Capacity|Total NVM'  | head -1 | cut -d: -f2- | sed 's/^ *//')
HEALTH=$(echo "$OUT" | grep -iE 'overall-health|SMART Health Status' | head -1 | awk -F: '{print $2}' | tr -d ' ')

POH=$(num "$(raw Power_On_Hours)")
REALLOC=$(num "$(raw Reallocated_Sector_Ct)")
PENDING=$(num "$(raw Current_Pending_Sector)")
UNCORR=$(num "$(raw Offline_Uncorrectable)")
REPORTED=$(num "$(raw Reported_Uncorrect)")
CRC=$(num "$(raw UDMA_CRC_Error_Count)")

echo "=================================================="
echo " Disco : $DEV  $BRIDGE"
echo " Modelo: ${MODEL:-?}   Serie: ${SERIAL:-?}"
echo " Capac.: ${CAP:-?}"
echo "--------------------------------------------------"
printf " %-26s %s\n" "Salud SMART:"            "${HEALTH:-?}"
printf " %-26s %s\n" "Horas encendido (POH):"  "$([ "$POH" -ge 0 ] && echo "$POH h (~$((POH/8760)) anios 24/7)" || echo NA)"
printf " %-26s %s\n" "Sectores reasignados:"   "$([ "$REALLOC" -ge 0 ] && echo "$REALLOC" || echo NA)"
printf " %-26s %s\n" "Sectores pendientes:"    "$([ "$PENDING" -ge 0 ] && echo "$PENDING" || echo NA)"
printf " %-26s %s\n" "Incorregibles (offline):" "$([ "$UNCORR" -ge 0 ] && echo "$UNCORR" || echo NA)"
printf " %-26s %s\n" "Errores reportados:"     "$([ "$REPORTED" -ge 0 ] && echo "$REPORTED" || echo NA)"
printf " %-26s %s\n" "Errores CRC (cable/dock):" "$([ "$CRC" -ge 0 ] && echo "$CRC" || echo NA)"
echo "--------------------------------------------------"

# --- veredicto ---
REJECT=0; SUSPECT=0; REASONS=()
echo "$HEALTH" | grep -qi FAIL          && { REJECT=1; REASONS+=("salud SMART = FAILED"); }
[ "$REALLOC" -gt 0 ] 2>/dev/null         && { REJECT=1; REASONS+=("$REALLOC sectores reasignados (disco degradandose)"); }
[ "$PENDING" -gt 0 ] 2>/dev/null         && { REJECT=1; REASONS+=("$PENDING sectores pendientes (lecturas fallando)"); }
[ "$UNCORR" -gt 0 ] 2>/dev/null          && { REJECT=1; REASONS+=("$UNCORR sectores incorregibles"); }
[ "$REPORTED" -gt 0 ] 2>/dev/null        && { SUSPECT=1; REASONS+=("$REPORTED errores reportados (vigilar)"); }
[ "$POH" -gt 40000 ] 2>/dev/null         && { SUSPECT=1; REASONS+=("muy usado (${POH}h, >4.5 anios 24/7)"); }
[ "$CRC" -gt 50 ] 2>/dev/null            && { SUSPECT=1; REASONS+=("$CRC errores CRC: suele ser el dock/cable, reprueba con otro dock"); }
[ "$HEALTH" = "" ] && { SUSPECT=1; REASONS+=("no se leyo la salud general"); }

echo
if [ "$REJECT" -eq 1 ]; then
  echo "VEREDICTO: RECHAZAR ❌  — posapapeles, NO usar para backup."
elif [ "$SUSPECT" -eq 1 ]; then
  echo "VEREDICTO: SOSPECHOSO ⚠️  — sirve para datos NO criticos / copia extra, no como unico respaldo."
else
  echo "VEREDICTO: SANO ✅  — apto para backup. Aun asi, manten >=1 copia mas (regla 3-2-1)."
fi
[ "${#REASONS[@]}" -gt 0 ] && { echo "Motivos:"; for r in "${REASONS[@]}"; do echo "  - $r"; done; }
echo "=================================================="
exit 0

#!/usr/bin/env bash
# Vérif câblage PCI pour serveurs (ex. Dell R740)
# Montre la correspondance Slot physique (DMI) ↔ BDF ↔ périphérique lspci
# et signale les cas suspects (slot marqué "In Use" sans device, device sans slot, etc.)

set -euo pipefail

need() { command -v "$1" >/dev/null 2>&1 || { echo "Erreur: commande '$1' manquante." >&2; exit 1; }; }

need dmidecode
need lspci

# -------- Récupération des infos DMI (slots physiques) ----------
# On construit des maps : designation -> status, designation -> busaddr (si présent)
declare -A DMI_STATUS DMI_BUSADDR
declare -a DMI_ORDER

# dmidecode peut nécessiter sudo
DMIOUT=$(dmidecode -t slot 2>/dev/null || sudo dmidecode -t slot)

# Parsing robuste des blocs "System Slot Information"
# On capte: Designation, Status, Bus Address
current=""
while IFS= read -r line; do
  if [[ "$line" =~ ^[[:space:]]*System\ Slot\ Information ]]; then
    current=""
    continue
  fi
  if [[ "$line" =~ ^[[:space:]]*Designation:\ (.*)$ ]]; then
    current="${BASH_REMATCH[1]}"
    DMI_ORDER+=("$current")
    continue
  fi
  [[ -z "$current" ]] && continue
  if [[ "$line" =~ ^[[:space:]]*Status:\ (.*)$ ]]; then
    DMI_STATUS["$current"]="${BASH_REMATCH[1]}"
    continue
  fi
  if [[ "$line" =~ ^[[:space:]]*Bus\ Address:\ (.*)$ ]]; then
    # Exemple: 0000:3b:00.0 ou 0000:af:00.0
    DMI_BUSADDR["$current"]="${BASH_REMATCH[1]}"
    continue
  fi
done <<< "$DMIOUT"

# -------- Inventaire des devices PCI détectés ----------
# Map: BDF (0000:bb:dd.f) -> description lspci
declare -A DEV_DESC
# Map: BDF -> physical_slot (si exposé par le kernel)
declare -A DEV_PHYSLOT

while IFS= read -r devpath; do
  bdf=$(basename "$devpath")      # ex: 0000:3b:00.0
  # description lisible
  desc=$(lspci -s "${bdf#0000:}" -nn)
  DEV_DESC["$bdf"]="$desc"
  # physical_slot si dispo
  if [[ -f "$devpath/physical_slot" ]]; then
    DEV_PHYSLOT["$bdf"]=$(<"$devpath/physical_slot")
  fi
done < <(find /sys/bus/pci/devices -maxdepth 1 -type l | sort)

# -------- Tentative de correspondance slot<->device ----------
# 1) Si DMI fournit Bus Address, on l'utilise
# 2) Sinon, on essaie via /sys/bus/pci/devices/*/physical_slot si la valeur correspond à la désignation
#    (souvent "1", "2", ... qui colle à "Slot 1", "Slot 2", etc.)

# Impression tableau
printf "\n%-20s | %-14s | %-8s | %-s\n" "Slot (DMI)" "BDF détecté" "Statut" "Périphérique"
printf -- "%-20s-+-%-14s-+-%-8s-+-%s\n" "--------------------" "--------------" "--------" "-----------------------------------------------"

declare -A MATCHED_BDF
for slot in "${DMI_ORDER[@]}"; do
  status="${DMI_STATUS[$slot]:-Unknown}"
  expected_bdf="${DMI_BUSADDR[$slot]:-}"
  found_bdf=""
  found_desc=""
  note=""

  if [[ -n "$expected_bdf" && -n "${DEV_DESC[$expected_bdf]:-}" ]]; then
    found_bdf="$expected_bdf"
    found_desc="${DEV_DESC[$found_bdf]}"
    MATCHED_BDF["$found_bdf"]=1
  else
    # Pas de bus address en DMI ou pas de match exact -> heuristique via physical_slot
    # On extrait un numéro de slot depuis la désignation (ex: "Slot 1", "PCIE Slot 2")
    if [[ "$slot" =~ ([0-9]+)$ ]]; then
      slotnum="${BASHREMATCH[1]}"
      # Chercher device dont physical_slot == slotnum
      for bdf in "${!DEV_DESC[@]}"; do
        if [[ "${DEV_PHYSLOT[$bdf]:-}" == "$slotnum" ]]; then
          found_bdf="$bdf"
          found_desc="${DEV_DESC[$bdf]}"
          MATCHED_BDF["$found_bdf"]=1
          break
        fi
      done
    fi
  fi

  # Déterminer remarques
  if [[ "$status" =~ [Ii]n\ Use ]]; then
    [[ -z "$found_bdf" ]] && note="  <-- ATTENTION: DMI dit 'In Use' mais aucun device vu"
  else
    [[ -n "$found_bdf" ]] && note="  <-- ATTENTION: device présent alors que DMI ne le signale pas"
  fi

  printf "%-20s | %-14s | %-8s | %s%s\n" "$slot" "${found_bdf:--}" "${status:0:8}" "${found_desc:-(aucun périphérique détecté)}" "$note"
done

# Devices non associés à un slot DMI (ex: mezzanine, onboard, ou DMI incomplet)
extra=false
for bdf in "${!DEV_DESC[@]}"; do
  if [[ -z "${MATCHED_BDF[$bdf]:-}" ]]; then
    $extra || { 
      echo
      echo "Périphériques détectés SANS correspondance DMI (peut être normal pour onboard/NVMe/Chipset) :"
      printf "%-14s | %-s\n" "BDF" "Périphérique"
      printf "%-14s-+-%s\n" "--------------" "-----------------------------------------------"
      extra=true
    }
    printf "%-14s | %s\n" "$bdf" "${DEV_DESC[$bdf]}"
  fi
done

echo
# -------- Suggestion OpenManage si dispo ----------
if command -v omreport >/dev/null 2>&1; then
  echo "OpenManage détecté: aperçu 'omreport chassis slots' ↓"
  echo "-----------------------------------------------------"
  omreport chassis slots 2>/dev/null || true
else
  echo "Astuce: installe 'OpenManage' (srvadmin / omreport) pour une vue Dell directe des slots."
fi
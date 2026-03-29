#!/bin/bash

set -euo pipefail

# ==============================================================================
# burn_dvd.sh
# Write a DVD-Video ISO to disc at 4x speed.
#
# Usage: ./burn_dvd.sh <isofile>
# ==============================================================================

# ==============================
# ARGUMENT CHECK
# ==============================
if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <isofile>"
    echo ""
    echo "  Writes the ISO to the first available DVD burner at 4x speed."
    echo "  After the tray reloads, verify the burn with:"
    echo "    ./verify_dvd.sh <isofile>"
    exit 1
fi

ISO="$1"

if [[ ! -f "$ISO" ]]; then
    echo "[ERROR] File not found: $ISO"
    exit 1
fi

if [[ "${ISO,,}" != *.iso ]]; then
    echo "[WARNING] File does not have a .iso extension: $ISO"
    read -r -p "Continue anyway? [y/N] " REPLY
    [[ "$REPLY" =~ ^[Yy]$ ]] || exit 1
fi

# ==============================
# DEPENDENCY CHECK
# ==============================
check_dep() {
    if ! command -v "$1" &>/dev/null; then
        echo "[ERROR] Required tool not found: $1"
        echo "        Install with: $2"
        exit 1
    fi
}

check_dep growisofs "sudo apt install dvd+rw-tools"

# ==============================
# DETECT DVD BURNER
# ==============================
DEVICE=""
for DEV in /dev/sr*; do
    if [[ ! -e "$DEV" ]]; then
        continue
    fi
    if udevadm info --query=property --name="$DEV" 2>/dev/null | grep -q "ID_CDROM_DVD=1"; then
        DEVICE="$DEV"
        break
    fi
done

if [[ -z "$DEVICE" ]]; then
    if [[ -e /dev/sr0 ]]; then
        echo "[WARNING] Could not confirm a DVD burner via udevadm — falling back to /dev/sr0"
        DEVICE="/dev/sr0"
    else
        echo "[ERROR] No optical drive found."
        exit 1
    fi
fi

echo "→ DVD burner: $DEVICE"

# ==============================
# PRE-FLIGHT SUMMARY
# ==============================
ISO_SIZE=$(du -h "$ISO" | cut -f1)
echo "→ ISO file:   $ISO ($ISO_SIZE)"
echo ""
echo "⚠️  This will permanently write to the disc in $DEVICE."
read -r -p "Insert a blank DVD and press Enter when ready, or Ctrl+C to abort... "

# ==============================
# BURN
# ==============================
echo ""
echo "=== BURNING ==="
echo "→ Running: growisofs -dvd-compat -speed=4 -Z ${DEVICE}=${ISO}"
echo ""

growisofs -dvd-compat -speed=4 -Z "${DEVICE}=${ISO}"

echo ""
echo "=== BURN COMPLETE ==="
echo ""
echo "The drive is reloading the tray. Once it has settled, verify the burn with:"
echo "  ./verify_dvd.sh \"$ISO\""
echo ""
echo "=== DONE ==="

#!/bin/bash

set -euo pipefail

# ==============================================================================
# verify_dvd.sh
# Verify a burned DVD disc matches its source ISO using MD5 checksum.
#
# Usage: ./verify_dvd.sh <isofile>
#
# Run this after burn_dvd.sh once the drive tray has fully reloaded.
# ==============================================================================

# ==============================
# ARGUMENT CHECK
# ==============================
if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <isofile>"
    echo ""
    echo "  Compares the MD5 of the source ISO against the disc currently"
    echo "  in the drive. Run after burn_dvd.sh once the tray has reloaded."
    exit 1
fi

ISO="$1"

if [[ ! -f "$ISO" ]]; then
    echo "[ERROR] File not found: $ISO"
    exit 1
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

check_dep isosize "sudo apt install util-linux"
check_dep md5sum  "sudo apt install coreutils"
check_dep dd      "sudo apt install coreutils"

# ==============================
# DETECT DVD DRIVE
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
        echo "[WARNING] Could not confirm a DVD drive via udevadm — falling back to /dev/sr0"
        DEVICE="/dev/sr0"
    else
        echo "[ERROR] No optical drive found."
        exit 1
    fi
fi

echo "→ DVD drive:  $DEVICE"
echo "→ ISO file:   $ISO"
echo ""

# ==============================
# WAIT FOR MEDIUM
# ==============================
# Poll until the drive reports a readable medium, with a timeout.
echo "→ Waiting for disc to be ready..."
MAX_WAIT=60
WAITED=0
until isosize "$DEVICE" &>/dev/null; do
    if (( WAITED >= MAX_WAIT )); then
        echo "[ERROR] Drive not ready after ${MAX_WAIT}s. Is the disc inserted and finalised?"
        exit 1
    fi
    sleep 2
    WAITED=$(( WAITED + 2 ))
done
echo "→ Disc is ready."
echo ""

# ==============================
# VERIFY
# ==============================
echo "=== VERIFYING ==="
echo "→ Computing MD5 of source ISO..."
ISO_MD5=$(md5sum "$ISO" | awk '{print $1}')
echo "   Source:  $ISO_MD5"

echo "→ Reading back from disc (this may take a few minutes)..."
SECTOR_COUNT=$(isosize -d 2048 "$DEVICE")
DISC_MD5=$(dd if="$DEVICE" bs=2048 count="$SECTOR_COUNT" status=progress 2>/dev/null | md5sum | awk '{print $1}')
echo "   Disc:    $DISC_MD5"

echo ""
if [[ "$ISO_MD5" == "$DISC_MD5" ]]; then
    echo "✅ Verification PASSED — disc matches ISO exactly."
else
    echo "❌ Verification FAILED — disc does not match ISO."
    echo "   The burn may be corrupt. Try a different disc or check the drive."
    exit 1
fi

echo ""
echo "=== DONE ==="

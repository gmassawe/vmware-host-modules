#!/usr/bin/env bash
# Build, install and sign the vmmon and vmnet modules from this repository
# for the running kernel, and handle Secure Boot key enrollment.
#
# Usage: sudo ./update.sh
set -euo pipefail

cd "$(dirname "$0")"

if (( EUID != 0 )); then
    echo "Run as root: sudo ./update.sh" >&2
    exit 1
fi

KVER="$(uname -r)"
SIGNFILE="/usr/src/linux-headers-${KVER}/scripts/sign-file"
KEYDIR="/var/lib/vmware-host-modules"

if [ ! -d vmmon-only ] || [ ! -d vmnet-only ]; then
    echo "No module sources on this branch (master carries infrastructure" >&2
    echo "only). Check out a workstation-<version> branch first." >&2
    exit 1
fi

if [ ! -x "$SIGNFILE" ]; then
    echo "Headers for running kernel ${KVER} missing. Install them first:" >&2
    echo "  sudo apt install linux-headers-${KVER}" >&2
    exit 1
fi

# Modules only need signatures when Secure Boot is enabled; without it,
# mokutil does not work at all, so use it to decide.
SB=0
if command -v mokutil >/dev/null 2>&1; then
    if mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
        SB=1
    fi
else
    echo "Note: mokutil not found. If your system uses Secure Boot," >&2
    echo "install mokutil and re-run, or the modules will not load." >&2
fi

# Warn if a newer kernel is installed but not running yet
latest="$(basename "$(ls -v /lib/modules | grep -E '^[0-9]' | tail -1)")"
if [ "$latest" != "$KVER" ]; then
    echo "WARNING: newer kernel ${latest} is installed; building only for ${KVER}." >&2
    echo "         Reboot into it and re-run this script." >&2
fi

# Build this repository's sources, then install them (vermagic check,
# strip and depmod are part of the Makefile install target).
make
make install

if (( SB )); then
    command -v openssl >/dev/null 2>&1 || {
        echo "Secure Boot is enabled but openssl is missing; cannot sign." >&2
        exit 1
    }

    # Create the signing key ONCE and reuse it, so the existing MOK
    # enrollment stays valid across runs. The key lives outside the
    # repository so it can never be committed by accident; only root
    # can read it.
    if [ ! -s "$KEYDIR/vmware.der" ] || [ ! -s "$KEYDIR/vmware.priv" ]; then
        echo "Generating new MOK key pair (one-time setup)..."
        mkdir -p "$KEYDIR"
        chmod 700 "$KEYDIR"
        openssl req -new -x509 -newkey rsa:2048 \
            -keyout "$KEYDIR/vmware.priv" -outform DER -out "$KEYDIR/vmware.der" \
            -nodes -days 36500 -subj "/CN=VMware host modules/"
        chmod 600 "$KEYDIR/vmware.priv"
    fi

    # Sign the freshly installed modules
    for mod in vmmon vmnet; do
        modpath="$(modinfo -n "$mod")"
        "$SIGNFILE" sha256 "$KEYDIR/vmware.priv" "$KEYDIR/vmware.der" "$modpath"
    done

    # Enroll only if not already in MOK
    if mokutil --test-key "$KEYDIR/vmware.der" 2>/dev/null | grep -q "already enrolled"; then
        echo "MOK key already enrolled; no reboot needed."
    else
        mokutil --import "$KEYDIR/vmware.der"
        echo "Reboot and confirm enrollment in the MOK manager to finish."
    fi
else
    echo "Secure Boot not enabled; installing unsigned modules."
fi

# Swap out stale loaded modules so the new signed ones take effect.
# Replacing the file on disk is NOT enough: a loaded module stays in the
# kernel until unloaded, and vmware-vmx keeps seeing the old version.
rmmod vmmon 2>/dev/null || true
rmmod vmnet 2>/dev/null || true
if grep -qE "^(vmmon|vmnet) " /proc/modules; then
    # The vmware-networks service usually holds vmnet - release and retry
    vmware-networks --stop >/dev/null 2>&1 || true
    rmmod vmmon 2>/dev/null || true
    rmmod vmnet 2>/dev/null || true
    vmware-networks --start >/dev/null 2>&1 || true  # reloads fresh vmnet
fi
if grep -q "^vmmon " /proc/modules; then
    echo "WARNING: old vmmon is still loaded (in use by a running process)." >&2
    echo "Close all VMs and the VMware GUI, then run:  sudo rmmod vmmon vmnet" >&2
    echo "...or simply reboot." >&2
fi

echo "Done: vmmon/vmnet built, signed and installed for ${KVER}."

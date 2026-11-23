#!/bin/bash
# Build and install the patched brcmfmac for the running kernel.
#
# This script assumes an Omarchy/Arch layout where /usr/src/linux-<flavour>
# holds only Kconfig files (all .c under drivers/net/wireless are stripped),
# so the module cannot be built in place and a vanilla source tree is needed.
#
# Usage: ./build.sh [path-to-linux-source-tree]
#   If no tree is given, extracts vanilla $KVER into ~/kbuild.
set -euo pipefail

KV=$(uname -r)                     # e.g. 7.2.15-1-omarchy
BASE=${KV%%-*}                     # 7.2.15
HERE=$(cd "$(dirname "$0")" && pwd)
PATCH="$HERE/0001-brcmfmac-learn-apple-efi-state.patch"
SRC=${1:-"$HOME/kbuild/linux-$BASE"}
MODDIR=drivers/net/wireless/broadcom/brcm80211/brcmfmac

echo "kernel:  $KV"
echo "source:  $SRC"

if [ ! -d "$SRC" ]; then
    echo "==> extracting vanilla $BASE into $HOME/kbuild"
    mkdir -p "$HOME/kbuild"
    cd "$HOME/kbuild"
    [ -f "linux-$BASE.tar.xz" ] || curl -LO "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$BASE.tar.xz"
    tar -xf "linux-$BASE.tar.xz"
fi

cd "$SRC"

# The distro tree provides .config and Module.symvers; reusing them is what
# makes the resulting vermagic and symbol CRCs match the running kernel.
DISTRO_SRC="/usr/src/linux-$(echo "$KV" | cut -d- -f2-)"
[ -f "$DISTRO_SRC/.config" ] || DISTRO_SRC="/usr/src/linux-omarchy"
echo "==> using distro config from $DISTRO_SRC"
cp "$DISTRO_SRC/.config" .config
[ -f "$DISTRO_SRC/Module.symvers" ] && cp "$DISTRO_SRC/Module.symvers" .

# CONFIG_LOCALVERSION_AUTO=y would append -g<sha> and break loading, so pin the
# local version to exactly what the running kernel reports.
sed -i 's/^CONFIG_LOCALVERSION_AUTO=y$/# CONFIG_LOCALVERSION_AUTO is not set/' .config
LOCAL=$(echo "$KV" | sed "s/^$BASE//")          # -1-omarchy
sed -i "s|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION=\"$LOCAL\"|" .config

echo "==> patching"
if grep -q 'brcmf_apple_snap_valid' "$MODDIR/pcie.c"; then
    echo "    patch already applied, skipping"
else
    patch -p1 < "$PATCH"
fi

echo "==> preparing"
make olddefconfig
command -v bc >/dev/null || { echo "ERROR: install bc (kernel build needs it)"; exit 1; }
make -j"$(nproc)" prepare
make scripts/module.lds

echo "==> building brcmfmac only (the kernel itself is never rebuilt)"
# KCFLAGS=-DDEBUG: CONFIG_BRCMDBG=y makes debug.h declare the debugfs helpers
# only under DEBUG, and M= builds skip the parent Makefile that adds it.
make -j"$(nproc)" LOCALVERSION="" KCFLAGS="-DDEBUG" M="$MODDIR" modules

strip --strip-debug "$MODDIR/brcmfmac.ko"
echo "==> built $(du -h "$MODDIR/brcmfmac.ko" | cut -f1) $MODDIR/brcmfmac.ko"

DEST="/usr/lib/modules/$KV/updates/brcmfmac"
sudo mkdir -p "$DEST"
sudo cp "$MODDIR/brcmfmac.ko" "$DEST/brcmfmac.ko"
sudo zstd -q -f "$DEST/brcmfmac.ko" -o "$DEST/brcmfmac.ko.zst"
sudo rm -f "$DEST/brcmfmac.ko"
sudo depmod -a "$KV"

echo
echo "installed: $(modinfo -n brcmfmac)"
echo "reload:    sudo modprobe -r brcmfmac_wcc brcmfmac && sudo modprobe brcmfmac"
echo "verify:    journalctl -k | grep -iE 'learned Apple EFI|restored Apple EFI'"

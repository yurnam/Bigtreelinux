#!/bin/bash
# post-build.sh – Buildroot post-build hook for BigTreeTech PandaTouch
#
# Called by Buildroot as:
#   BR2_ROOTFS_POST_BUILD_SCRIPT="$(BR2_EXTERNAL_PANDATOUCH_PATH)/board/pandatouch/post-build.sh"
#
# Arguments provided by Buildroot:
#   $1  TARGET_DIR  – staging root to be packed into the filesystem image
#
set -e

TARGET_DIR="$1"
BOARD_DIR="$(dirname "$0")"
EXTERNAL_DIR="$(realpath "$BOARD_DIR/../..")"

echo "[PandaTouch] Running post-build hook (TARGET_DIR=$TARGET_DIR)"

# ── 1. Install the Linux device tree source ────────────────────────────────
# The DTS must live in the kernel build tree so that
# BR2_LINUX_KERNEL_INTREE_DTS_NAME="esp32s3-pandatouch" resolves correctly.
# Buildroot exposes the kernel output tree via BINARIES_DIR/../build/linux-*.
LINUX_BUILD_DIR=$(find "$BASE_DIR/build" -maxdepth 1 -type d -name 'linux-*' | head -1)
if [ -n "$LINUX_BUILD_DIR" ] ; then
    DTS_DEST="$LINUX_BUILD_DIR/arch/xtensa/boot/dts"
    install -m 644 \
        "$EXTERNAL_DIR/../esp32s3-pandatouch.dts" \
        "$DTS_DEST/esp32s3-pandatouch.dts" \
        2>/dev/null || true
    echo "[PandaTouch] DTS copied to $DTS_DEST"
fi

# ── 2. Ensure /dev/fb0 is created in the root filesystem ──────────────────
install -d -m 0755 "$TARGET_DIR/dev"
# devtmpfs will create this at runtime; provide a static node for initramfs
if [ ! -e "$TARGET_DIR/dev/fb0" ] ; then
    mknod -m 0666 "$TARGET_DIR/dev/fb0" c 29 0 2>/dev/null || true
fi

# ── 3. Make display/touch init scripts executable ─────────────────────────
for s in "$TARGET_DIR/etc/init.d/S10display" \
          "$TARGET_DIR/etc/init.d/S20touchscreen" ; do
    [ -f "$s" ] && chmod 0755 "$s"
done

echo "[PandaTouch] Post-build hook complete"

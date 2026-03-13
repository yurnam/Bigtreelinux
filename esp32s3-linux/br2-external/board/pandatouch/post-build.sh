#!/bin/bash
# post-build.sh – Buildroot post-build hook for BigTreeTech PandaTouch
#
# Called by Buildroot as:
#   BR2_ROOTFS_POST_BUILD_SCRIPT="$(BR2_EXTERNAL_PANDATOUCH_PATH)/board/pandatouch/post-build.sh"
#
# NOTE: the Linux kernel DTS (esp32s3-pandatouch.dts) is handled by
# BR2_LINUX_KERNEL_CUSTOM_DTS_PATH in the defconfig.  Buildroot copies the DTS
# into the kernel source tree via a post-patch hook BEFORE compilation starts.
# No manual DTS injection is needed here.
#
# Arguments provided by Buildroot:
#   $1  TARGET_DIR  – staging root to be packed into the filesystem image
#
set -e

TARGET_DIR="$1"

echo "[PandaTouch] Running post-build hook (TARGET_DIR=$TARGET_DIR)"

# ── Make display/touch init scripts executable ────────────────────────────
# Buildroot preserves file modes from the rootfs overlay, but a belt-and-
# suspenders chmod here ensures the init scripts are runnable.
for s in "$TARGET_DIR/etc/init.d/S10display" \
          "$TARGET_DIR/etc/init.d/S20touchscreen" ; do
    [ -f "$s" ] && chmod 0755 "$s"
done

echo "[PandaTouch] Post-build hook complete"

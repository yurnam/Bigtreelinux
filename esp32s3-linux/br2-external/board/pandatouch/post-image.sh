#! /bin/sh
# post-image.sh – Buildroot post-image script for BigTreeTech PandaTouch
#
# Called by Buildroot as BR2_ROOTFS_POST_IMAGE_SCRIPT after all filesystem
# images have been built.
#
# Renames the generic rootfs.jffs2 output to etc.jffs2 so the flash script
# (rebuild-esp32s3-pandatouch.sh) can locate and write it to the dedicated
# "etc" SPI-NOR partition.
#
# Arguments provided by Buildroot:
#   $1  BINARIES_DIR – the directory where images are written

BINARIES_DIR="$1"

if [ -f "$BINARIES_DIR/rootfs.jffs2" ] ; then
    mv "$BINARIES_DIR/rootfs.jffs2" "$BINARIES_DIR/etc.jffs2"
    echo "[PandaTouch] Renamed rootfs.jffs2 -> etc.jffs2"
fi

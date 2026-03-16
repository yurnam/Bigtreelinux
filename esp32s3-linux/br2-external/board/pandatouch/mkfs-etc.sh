#! /bin/sh
# mkfs-etc.sh – Buildroot post-fakeroot script for BigTreeTech PandaTouch
#
# Called by Buildroot as BR2_ROOTFS_POST_FAKEROOT_SCRIPT for every filesystem
# image type.  It must check that it is being invoked for the jffs2 image and
# exit immediately for all other image types.
#
# When called for jffs2 it trims the staging tree so only the /etc subtree
# ends up in the resulting jffs2 image.  This mirrors the upstream
# board/espressif/esp32s3/mkfs-etc.sh behaviour.
#
# Arguments provided by Buildroot:
#   $1  STAGING_DIR – the fakeroot staging directory for this image type

echo "$1" | grep -q 'jffs2/target$' || exit 0

echo '[PandaTouch] Trimming jffs2 staging to /etc contents'
find "$1" -mindepth 1 -maxdepth 1 -not -name 'etc' -print0 | xargs -0 rm -rf
mv "$1/etc/"* "$1"
rm -rf "$1/etc"

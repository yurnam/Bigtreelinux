#! /bin/bash -x
#
# rebuild-esp32s3-pandatouch.sh
# ─────────────────────────────
# Build and flash Linux for the BigTreeTech PandaTouch (ESP32-S3, 8 MB flash,
# 8 MB Octal PSRAM, 800×480 RGB LCD).
#
# This script is a thin wrapper around rebuild-esp32s3-linux-wifi.sh that:
#   1. Selects pandatouch.conf automatically.
#   2. Passes BR2_EXTERNAL so Buildroot picks up the PandaTouch defconfig
#      and board files from br2-external/.
#   3. Copies the device tree source into the kernel tree before the build.
#   4. Provides an extra flash step for the lcd-init application.
#
# Usage:
#   cd esp32s3-linux/esp32-linux-build
#   ./rebuild-esp32s3-pandatouch.sh [options]
#
# Options (same as rebuild-esp32s3-linux-wifi.sh):
#   -c <config>   override board config (defaults to ../pandatouch.conf)
#
# Environment variables (set in settings.cfg):
#   keep_toolchain, keep_rootfs, keep_buildroot, keep_bootloader, keep_etc
#   SET_BAUDRATE (default: -b 2000000)
#
# Requirements:
#   - Docker image built from ../Dockerfile   – OR –
#   - Native host with the packages listed in esp32-linux-build/README
#   - ESP-IDF v5.x installed and IDF_PATH set (for lcd-init app)
#

SET_BAUDRATE='-b 2000000'

CTNG_VER=xtensa-fdpic
CTNG_CONFIG=xtensa-esp32s3-linux-uclibcfdpic
BUILDROOT_VER=xtensa-2024.08-fdpic
ESP_HOSTED_VER=ipc-5.1.1

# Default PandaTouch configuration
PANDATOUCH_CONF="$(dirname "$0")/../pandatouch.conf"

# Resolve the path to the br2-external tree
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BR2_EXTERNAL_DIR="$(realpath "$SCRIPT_DIR/../br2-external")"
DTS_SRC="$(realpath "$SCRIPT_DIR/../esp32s3-pandatouch.dts")"

# ── Helpers ───────────────────────────────────────────────────────────────

function die()
{
    echo "ERROR: $1" >&2
    exit 1
}

# ── Parse arguments ────────────────────────────────────────────────────────

conf="$PANDATOUCH_CONF"

while : ; do
    case "$1" in
        -c)
            conf="$2"
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

[ -f "$conf" ] || die "Config file not found: $conf"
. "$conf"

[ -n "$BUILDROOT_CONFIG" ] || die "BUILDROOT_CONFIG not set in $conf"
[ -n "$ESP_HOSTED_CONFIG" ] || die "ESP_HOSTED_CONFIG not set in $conf"

echo "=== PandaTouch Linux build ==="
echo "    BUILDROOT_CONFIG  = $BUILDROOT_CONFIG"
echo "    ESP_HOSTED_CONFIG = $ESP_HOSTED_CONFIG"
echo "    BR2_EXTERNAL      = $BR2_EXTERNAL_DIR"
echo "    DTS source        = $DTS_SRC"
echo ""

# ── Autoconf 2.71 ─────────────────────────────────────────────────────────

if [ ! -d autoconf-2.71/root/bin ] ; then
    wget https://ftp.gnu.org/gnu/autoconf/autoconf-2.71.tar.xz
    tar -xf autoconf-2.71.tar.xz
    pushd autoconf-2.71
    ./configure --prefix="$(pwd)/root"
    make && make install
    popd
fi
export PATH="$(pwd)/autoconf-2.71/root/bin:$PATH"

# ── Clean / prepare build directory ───────────────────────────────────────

if [ -z "$keep_toolchain$keep_buildroot$keep_rootfs$keep_bootloader" ] ; then
    rm -rf build
else
    [ -n "$keep_toolchain" ] || rm -rf "build/crosstool-NG/builds/$CTNG_CONFIG"
    [ -n "$keep_rootfs"    ] || rm -rf "build/build-buildroot-$BUILDROOT_CONFIG"
    [ -n "$keep_buildroot" ] || rm -rf "build/buildroot"
    [ -n "$keep_bootloader"] || rm -rf "build/esp-hosted"
fi
mkdir -p build
cd build

# ── xtensa-dynconfig ──────────────────────────────────────────────────────

if [ ! -f xtensa-dynconfig/esp32s3.so ] ; then
    git clone https://github.com/jcmvbkbc/xtensa-dynconfig -b original
    git clone https://github.com/jcmvbkbc/config-esp32s3 esp32s3
    make -C xtensa-dynconfig ORIG=1 CONF_DIR="$(pwd)" esp32s3.so
fi
export XTENSA_GNU_CONFIG="$(pwd)/xtensa-dynconfig/esp32s3.so"

# ── Cross-compiler (crosstool-NG) ─────────────────────────────────────────

if [ ! -x "crosstool-NG/builds/$CTNG_CONFIG/bin/$CTNG_CONFIG-gcc" ] ; then
    git clone https://github.com/jcmvbkbc/crosstool-NG.git -b "$CTNG_VER"
    pushd crosstool-NG
    ./bootstrap && ./configure --enable-local && make
    ./ct-ng "$CTNG_CONFIG"
    CT_PREFIX="$(pwd)/builds" nice ./ct-ng build
    popd
    [ -x "crosstool-NG/builds/$CTNG_CONFIG/bin/$CTNG_CONFIG-gcc" ] || exit 1
fi

# ── Buildroot (kernel + rootfs) ───────────────────────────────────────────

if [ ! -d buildroot ] ; then
    git clone https://github.com/jcmvbkbc/buildroot -b "$BUILDROOT_VER"
else
    pushd buildroot; git pull; popd
fi

if [ ! -d "build-buildroot-$BUILDROOT_CONFIG" ] ; then
    # Apply defconfig from br2-external
    nice make -C buildroot \
        O="$(pwd)/build-buildroot-$BUILDROOT_CONFIG" \
        BR2_EXTERNAL="$BR2_EXTERNAL_DIR" \
        "${BUILDROOT_CONFIG}_defconfig" \
        || die "Could not apply buildroot config ${BUILDROOT_CONFIG}_defconfig"

    # Inject toolchain path (same as upstream wifi script)
    buildroot/utils/config \
        --file "build-buildroot-$BUILDROOT_CONFIG/.config" \
        --set-str TOOLCHAIN_EXTERNAL_PATH \
        "$(pwd)/crosstool-NG/builds/$CTNG_CONFIG"
    buildroot/utils/config \
        --file "build-buildroot-$BUILDROOT_CONFIG/.config" \
        --set-str TOOLCHAIN_EXTERNAL_PREFIX \
        '$(ARCH)-esp32s3-linux-uclibcfdpic'
    buildroot/utils/config \
        --file "build-buildroot-$BUILDROOT_CONFIG/.config" \
        --set-str TOOLCHAIN_EXTERNAL_CUSTOM_PREFIX \
        '$(ARCH)-esp32s3-linux-uclibcfdpic'
fi

# Copy DTS into the kernel source tree so INTREE_DTS_NAME resolves
# (the kernel may not be unpacked yet; the copy is repeated if needed)
LINUX_SRC_DIR=$(find "build-buildroot-$BUILDROOT_CONFIG/build" \
    -maxdepth 1 -type d -name 'linux-*' 2>/dev/null | head -1)
if [ -n "$LINUX_SRC_DIR" ] ; then
    install -m 644 "$DTS_SRC" \
        "$LINUX_SRC_DIR/arch/xtensa/boot/dts/esp32s3-pandatouch.dts"
    echo "[pandatouch] DTS installed in kernel tree"
fi

nice make -C buildroot \
    O="$(pwd)/build-buildroot-$BUILDROOT_CONFIG" \
    BR2_EXTERNAL="$BR2_EXTERNAL_DIR"

# Re-copy DTS after kernel sources are downloaded (if not already there)
LINUX_SRC_DIR=$(find "build-buildroot-$BUILDROOT_CONFIG/build" \
    -maxdepth 1 -type d -name 'linux-*' 2>/dev/null | head -1)
if [ -n "$LINUX_SRC_DIR" ] ; then
    install -m 644 "$DTS_SRC" \
        "$LINUX_SRC_DIR/arch/xtensa/boot/dts/esp32s3-pandatouch.dts"
fi

[ -f "build-buildroot-$BUILDROOT_CONFIG/images/xipImage"   ] || exit 1
[ -f "build-buildroot-$BUILDROOT_CONFIG/images/rootfs.cramfs" ] || exit 1
[ -f "build-buildroot-$BUILDROOT_CONFIG/images/etc.jffs2"  ] || exit 1

# ── esp-hosted (WiFi co-processor / Linux loader) ─────────────────────────

[ -d esp-hosted ] || git clone https://github.com/jcmvbkbc/esp-hosted \
    -b "$ESP_HOSTED_VER"

pushd esp-hosted/esp_hosted_ng/esp/esp_driver
cmake .
cd esp-idf
. export.sh
cd ../network_adapter
idf.py set-target esp32s3
cp "$ESP_HOSTED_CONFIG" sdkconfig || die "Could not apply IDF config $ESP_HOSTED_CONFIG"
idf.py build
read -p 'Ready to flash esp-hosted... press Enter'
while ! idf.py $SET_BAUDRATE flash ; do
    read -p 'Flash failed... press Enter to retry'
done
popd

# ── Flash Linux kernel, rootfs, and /etc ──────────────────────────────────

parttool.py $SET_BAUDRATE write_partition \
    --partition-name linux  \
    --input "build-buildroot-$BUILDROOT_CONFIG/images/xipImage"

parttool.py $SET_BAUDRATE write_partition \
    --partition-name rootfs \
    --input "build-buildroot-$BUILDROOT_CONFIG/images/rootfs.cramfs"

if [ -z "$keep_etc" ] ; then
    read -p 'Ready to flash /etc... press Enter'
    parttool.py $SET_BAUDRATE write_partition \
        --partition-name etc   \
        --input "build-buildroot-$BUILDROOT_CONFIG/images/etc.jffs2"
fi

echo ""
echo "=== PandaTouch build and flash complete! ==="
echo ""
echo "Next steps:"
echo "  1. Build and flash the lcd-init app from esp32s3-linux/lcd-init/"
echo "     (see esp32s3-linux/docs/PANDATOUCH_LINUX.md for instructions)"
echo "  2. Power-cycle the PandaTouch – the display should show the splash,"
echo "     then Linux should boot on the serial console (USB-C, 115200 baud)."

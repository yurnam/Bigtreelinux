#! /bin/bash -x
#
# rebuild-esp32s3-pandatouch-fb.sh
# ─────────────────────────────────
# Build and flash the framebuffer Linux image for the BigTreeTech PandaTouch.
#
# What you get
# ────────────
# • LCD framebuffer (/dev/fb0) via simple-framebuffer DT node
# • fbcon – kernel text console rendered on the LCD
# • fbset  – userspace tool to inspect / set display modes
# • BusyBox init + shell + standard utilities
# • Serial console (UART0, ttyS0, 115200 baud, via USB-C → CH340K)
# • Writable /etc (jffs2)
#
# What is SKIPPED vs the full rebuild-esp32s3-pandatouch.sh
# ──────────────────────────────────────────────────────────
# • WiFi (wpa_supplicant)                   – no wireless networking
# • Touchscreen userspace (tslib, evtest)   – kernel GT911 driver is present
#                                             but no calibration tools
# • Network tools (iproute2)
# • Flash tools (mtd-utils)
# • USB utilities (usbutils)
# • MMIO debug tool (devmem2)
#
# Build time
# ──────────
# First run: ~60 min (toolchain + Buildroot + esp-hosted all built from scratch)
# Subsequent runs: ~5–10 min (incremental; only changed parts rebuild)
#
# Designed to run:
#   a) Inside the Docker container (esp32linuxbase) with esp32s3-linux/ as /app
#   b) Natively on a host with the packages in esp32-linux-build/README
#
# Usage (from esp32s3-linux/):
#   ./esp32-linux-build/rebuild-esp32s3-pandatouch-fb.sh [OPTIONS]
#
# Options:
#   -c <file>    Override board config (default: ../pandatouch-fb.conf)
#   --no-flash   Build images only, skip all flashing steps
#
# Environment variables:
#   keep_toolchain=y   skip toolchain rebuild
#   keep_rootfs=y      skip rootfs rebuild
#   keep_buildroot=y   skip buildroot re-download
#   keep_bootloader=y  skip esp-hosted re-download
#   keep_etc=y         skip reflashing /etc partition
#   ESP_PORT=<dev>     serial port (e.g. /dev/ttyUSB0); auto-detected if unset

SET_BAUDRATE='-b 2000000'

CTNG_VER=xtensa-fdpic
CTNG_CONFIG=xtensa-esp32s3-linux-uclibcfdpic
BUILDROOT_VER=xtensa-2024.08-fdpic
ESP_HOSTED_VER=ipc-5.1.1

# ── Resolve paths ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINUX_DIR="$(realpath "$SCRIPT_DIR/..")"

PANDATOUCH_CONF="$LINUX_DIR/pandatouch-fb.conf"
BR2_EXTERNAL_DIR="$LINUX_DIR/br2-external"
PARTITIONS_CSV="$LINUX_DIR/lcd-init/partitions.csv"
SDKCONFIG_DEFAULTS="$SCRIPT_DIR/sdkconfig.pandatouch.defaults"

# ── Helpers ────────────────────────────────────────────────────────────────
function die() { echo "ERROR: $1" >&2; exit 1; }

PORT_ARGS=()
[ -n "${ESP_PORT:-}" ] && PORT_ARGS=("-p" "$ESP_PORT")

# ── Argument parsing ────────────────────────────────────────────────────────
conf="$PANDATOUCH_CONF"
NO_FLASH=0

while : ; do
    case "$1" in
        -c)
            conf="$2"
            shift 2
            ;;
        --no-flash)
            NO_FLASH=1
            shift
            ;;
        *)
            break
            ;;
    esac
done

[ -f "$conf" ]               || die "Config not found: $conf"
[ -f "$PARTITIONS_CSV" ]     || die "partitions.csv not found: $PARTITIONS_CSV"
[ -f "$SDKCONFIG_DEFAULTS" ] || die "sdkconfig.pandatouch.defaults not found: $SDKCONFIG_DEFAULTS"

. "$conf"

[ -n "$BUILDROOT_CONFIG" ] || die "BUILDROOT_CONFIG not set in $conf"

echo "=== PandaTouch Linux framebuffer build ==="
echo "    BUILDROOT_CONFIG  = $BUILDROOT_CONFIG"
echo "    BR2_EXTERNAL      = $BR2_EXTERNAL_DIR"
echo "    partitions.csv    = $PARTITIONS_CSV"
echo "    NO_FLASH          = $NO_FLASH"
[ -n "${ESP_PORT:-}" ] && echo "    ESP_PORT          = $ESP_PORT"
echo ""
echo "    This build includes framebuffer LCD support and fbset."
echo "    WiFi, touch userspace, and heavy networking tools are skipped."
echo ""

# ── Autoconf 2.71 ─────────────────────────────────────────────────────────
cd "$SCRIPT_DIR"

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
if [ -z "${keep_toolchain:-}${keep_buildroot:-}${keep_rootfs:-}${keep_bootloader:-}" ] ; then
    rm -rf build
else
    [ -n "${keep_toolchain:-}"  ] || rm -rf "build/crosstool-NG/builds/$CTNG_CONFIG"
    [ -n "${keep_rootfs:-}"     ] || rm -rf "build/build-buildroot-$BUILDROOT_CONFIG"
    [ -n "${keep_buildroot:-}"  ] || rm -rf "build/buildroot"
    [ -n "${keep_bootloader:-}" ] || rm -rf "build/esp-hosted"
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

# ── Buildroot (kernel + framebuffer rootfs) ───────────────────────────────
if [ ! -d buildroot ] ; then
    git clone https://github.com/jcmvbkbc/buildroot -b "$BUILDROOT_VER"
else
    pushd buildroot; git pull; popd
fi

# ── BusyBox MMU fix ────────────────────────────────────────────────────────
# The real fix is in br2-external/external.mk: BUSYBOX_SET_MMU is redefined
# there to unconditionally disable CONFIG_NOMMU (MMU path), overriding the
# jcmvbkbc fork's broken ifeq ($(BR2_USE_MMU),y) guard.
# See br2-external/external.mk for the full root-cause explanation.

if [ ! -d "build-buildroot-$BUILDROOT_CONFIG" ] || \
   [ ! -f "build-buildroot-$BUILDROOT_CONFIG/images/xipImage" ] ; then
    nice make -C buildroot \
        O="$(pwd)/build-buildroot-$BUILDROOT_CONFIG" \
        BR2_EXTERNAL="$BR2_EXTERNAL_DIR" \
        "${BUILDROOT_CONFIG}_defconfig" \
        || die "Could not apply buildroot config ${BUILDROOT_CONFIG}_defconfig"

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

    # Force BusyBox reconfigure: any stale stamps from a previous failed
    # build (where CONFIG_NOMMU may have been set) prevent re-running the
    # kconfig fixup.  Delete them so Buildroot reruns the fixup and compile.
    rm -f "build-buildroot-$BUILDROOT_CONFIG"/build/busybox-*/.stamp_kconfig_fixup_done \
          "build-buildroot-$BUILDROOT_CONFIG"/build/busybox-*/.stamp_configured \
          "build-buildroot-$BUILDROOT_CONFIG"/build/busybox-*/.stamp_built
fi

nice make -C buildroot \
    O="$(pwd)/build-buildroot-$BUILDROOT_CONFIG" \
    BR2_EXTERNAL="$BR2_EXTERNAL_DIR"

[ -f "build-buildroot-$BUILDROOT_CONFIG/images/xipImage"     ] || exit 1
[ -f "build-buildroot-$BUILDROOT_CONFIG/images/rootfs.cramfs" ] || exit 1
[ -f "build-buildroot-$BUILDROOT_CONFIG/images/etc.jffs2"     ] || exit 1

# ── esp-hosted: WiFi co-processor + Linux loader ──────────────────────────
[ -d esp-hosted ] || git clone \
    https://github.com/jcmvbkbc/esp-hosted -b "$ESP_HOSTED_VER"

pushd esp-hosted/esp_hosted_ng/esp/esp_driver
cmake .
cd esp-idf
. export.sh
cd ../network_adapter

cp "$PARTITIONS_CSV" partitions.csv
rm -f sdkconfig sdkconfig.defaults
cp "$SDKCONFIG_DEFAULTS" sdkconfig.defaults
idf.py set-target esp32s3
idf.py build

if [ "$NO_FLASH" -eq 0 ] ; then
    read -p 'Ready to flash esp-hosted (Linux loader)... press Enter'
    while ! idf.py "${PORT_ARGS[@]}" $SET_BAUDRATE flash ; do
        read -p 'Flash failed. Press Enter to retry, Ctrl-C to abort'
    done
fi

popd

# ── Flash Linux kernel, rootfs, and /etc ──────────────────────────────────
if [ "$NO_FLASH" -eq 0 ] ; then
    parttool.py "${PORT_ARGS[@]}" $SET_BAUDRATE write_partition \
        --partition-name linux \
        --input "build-buildroot-$BUILDROOT_CONFIG/images/xipImage"

    parttool.py "${PORT_ARGS[@]}" $SET_BAUDRATE write_partition \
        --partition-name rootfs \
        --input "build-buildroot-$BUILDROOT_CONFIG/images/rootfs.cramfs"

    if [ -z "${keep_etc:-}" ] ; then
        read -p 'Ready to flash /etc... press Enter'
        parttool.py "${PORT_ARGS[@]}" $SET_BAUDRATE write_partition \
            --partition-name etc \
            --input "build-buildroot-$BUILDROOT_CONFIG/images/etc.jffs2"
    fi

    echo ""
    echo "=== PandaTouch framebuffer flash complete! ==="
    echo ""
    echo "Power-cycle the board and connect a serial terminal at 115200 baud."
    echo "(USB-C port → CH340K UART bridge → ttyUSB0 or ttyACM0)"
    echo ""
    echo "The LCD should display the Linux console (fbcon) on boot."
else
    echo ""
    echo "=== PandaTouch framebuffer build complete (--no-flash) ==="
    echo "Built images in: build/build-buildroot-$BUILDROOT_CONFIG/images/"
    echo "  xipImage       Linux kernel (XIP, with framebuffer + fbcon)"
    echo "  rootfs.cramfs  cramfs root filesystem (BusyBox + fbset)"
    echo "  etc.jffs2      writable /etc partition"
    echo "esp-hosted binary: build/esp-hosted/esp_hosted_ng/esp/esp_driver/network_adapter/build/"
fi

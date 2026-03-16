#! /bin/bash -x
#
# rebuild-esp32s3-pandatouch-minimal.sh
# ──────────────────────────────────────
# MINIMAL build + flash script for BigTreeTech PandaTouch (ESP32-S3).
#
# Produces the smallest image that gets Linux booting on the device:
#   • Serial console (ttyS0, 115200 baud, via USB-C → CH340K)
#   • BusyBox shell + standard utilities
#   • Writable /etc (jffs2)
#
# What is SKIPPED vs the full rebuild-esp32s3-pandatouch.sh:
#   • Framebuffer / LCD display drivers   (no /dev/fb0)
#   • Goodix GT911 touch driver           (no touch input)
#   • USB host / mass-storage drivers     (no USB thumb-drive root)
#   • WiFi (wpa_supplicant)
#   • Userspace tools: iproute2, tslib, evtest, devmem2, mtd-utils, usbutils
#
# Expected build time (first run, everything from scratch):
#   ≈ 35–45 minutes  (vs ≈ 60–75 minutes for the full build)
#   The toolchain and esp-hosted take a fixed ≈ 30 min regardless.
#   The minimal Buildroot step takes ≈ 8–12 min (vs ≈ 25–35 min full).
#
# Designed to run:
#   a) Inside the Docker container (esp32linuxbase) with esp32s3-linux/ as /app
#   b) Natively on a host with the packages in esp32-linux-build/README
#
# Usage (inside Docker or natively, from esp32s3-linux/):
#   ./esp32-linux-build/rebuild-esp32s3-pandatouch-minimal.sh [OPTIONS]
#
# Options:
#   -c <file>    Override board config (default: ../pandatouch-minimal.conf)
#   --no-flash   Build images only, skip all flashing steps
#
# Environment variables:
#   keep_toolchain=y   skip toolchain rebuild
#   keep_rootfs=y      skip rootfs rebuild
#   keep_buildroot=y   skip buildroot re-download
#   keep_bootloader=y  skip esp-hosted re-download
#   ESP_PORT=<dev>     serial port (e.g. /dev/ttyUSB0); auto-detected if unset
#
# After flashing, connect a serial terminal at 115200 baud to the USB-C port:
#   screen /dev/ttyUSB0 115200
#   minicom -D /dev/ttyUSB0 -b 115200
#
# To upgrade to the full image later, run rebuild-esp32s3-pandatouch.sh
# with keep_toolchain=y keep_bootloader=y to reuse built artefacts.

SET_BAUDRATE='-b 2000000'

CTNG_VER=xtensa-fdpic
CTNG_CONFIG=xtensa-esp32s3-linux-uclibcfdpic
BUILDROOT_VER=xtensa-2024.08-fdpic
ESP_HOSTED_VER=ipc-5.1.1

# ── Resolve paths ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINUX_DIR="$(realpath "$SCRIPT_DIR/..")"

PANDATOUCH_CONF="$LINUX_DIR/pandatouch-minimal.conf"
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

echo "=== PandaTouch Linux MINIMAL build ==="
echo "    BUILDROOT_CONFIG  = $BUILDROOT_CONFIG"
echo "    BR2_EXTERNAL      = $BR2_EXTERNAL_DIR"
echo "    partitions.csv    = $PARTITIONS_CSV"
echo "    NO_FLASH          = $NO_FLASH"
[ -n "${ESP_PORT:-}" ] && echo "    ESP_PORT          = $ESP_PORT"
echo ""
echo "    This build skips WiFi, framebuffer, touch and USB drivers."
echo "    You will get a serial-console-only BusyBox Linux."
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

# ── Buildroot (kernel + minimal rootfs) ───────────────────────────────────
if [ ! -d buildroot ] ; then
    git clone https://github.com/jcmvbkbc/buildroot -b "$BUILDROOT_VER"
else
    pushd buildroot; git pull; popd
fi

# ── BusyBox MMU fix ────────────────────────────────────────────────────────
# Three complementary fixes ensure ash compiles (BB_MMU=1) on ESP32-S3:
#
# 1. br2-external/external.mk overrides BUSYBOX_SET_MMU to disable CONFIG_NOMMU
#    (prevents ENABLE_NOMMU=1 which is the first condition for BB_MMU=0).
#
# 2. br2-external/external.mk appends BUSYBOX_CFLAGS += -D__ARCH_USE_MMU__
#    (PRIMARY fix for BB_MMU=0 from the uClibc condition).
#    BUSYBOX_CFLAGS is a deferred Make variable; the append runs after
#    busybox.mk is loaded, and passes -D__ARCH_USE_MMU__ to all BusyBox
#    compilation units via Buildroot's CFLAGS="..." make invocation.
#    This bypasses Kconfig/syncconfig entirely.
#
# 3. busybox-mmu.config adds CONFIG_EXTRA_CFLAGS="-D__ARCH_USE_MMU__"
#    (belt-and-suspenders via BusyBox's Makefile.flags CONFIG_EXTRA_CFLAGS
#    mechanism – a secondary path for the same define).
#
# 4. BR2_USE_MMU=y is passed on the make command line so the ifeq guard in
#    busybox.mk takes the MMU branch unconditionally.

if [ ! -d "build-buildroot-$BUILDROOT_CONFIG" ] || \
   [ ! -f "build-buildroot-$BUILDROOT_CONFIG/images/xipImage" ] ; then
    nice make -C buildroot \
        O="$(pwd)/build-buildroot-$BUILDROOT_CONFIG" \
        BR2_EXTERNAL="$BR2_EXTERNAL_DIR" \
        BR2_USE_MMU=y \
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
    # build prevent re-running the kconfig fixup and compile.
    rm -f "build-buildroot-$BUILDROOT_CONFIG"/build/busybox-*/.stamp_kconfig_fixup_done \
          "build-buildroot-$BUILDROOT_CONFIG"/build/busybox-*/.stamp_configured \
          "build-buildroot-$BUILDROOT_CONFIG"/build/busybox-*/.stamp_built
fi

nice make -C buildroot \
    O="$(pwd)/build-buildroot-$BUILDROOT_CONFIG" \
    BR2_EXTERNAL="$BR2_EXTERNAL_DIR" \
    BR2_USE_MMU=y

[ -f "build-buildroot-$BUILDROOT_CONFIG/images/xipImage"      ] || exit 1
[ -f "build-buildroot-$BUILDROOT_CONFIG/images/rootfs.cramfs"  ] || exit 1
[ -f "build-buildroot-$BUILDROOT_CONFIG/images/etc.jffs2"      ] || exit 1

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

    parttool.py "${PORT_ARGS[@]}" $SET_BAUDRATE write_partition \
        --partition-name etc \
        --input "build-buildroot-$BUILDROOT_CONFIG/images/etc.jffs2"

    echo ""
    echo "=== PandaTouch minimal flash complete! ==="
    echo ""
    echo "Connect a serial terminal at 115200 baud to the USB-C port:"
    echo "  screen /dev/ttyUSB0 115200"
    echo "  minicom -D /dev/ttyUSB0 -b 115200"
    echo ""
    echo "Power-cycle the board to boot Linux."
    echo ""
    echo "To upgrade to the full image (WiFi, display, touch) later, run:"
    echo "  keep_toolchain=y keep_bootloader=y \\"
    echo "    ./esp32-linux-build/rebuild-esp32s3-pandatouch.sh"
else
    echo ""
    echo "=== PandaTouch minimal build complete (--no-flash) ==="
    echo "Built images in: build/build-buildroot-$BUILDROOT_CONFIG/images/"
    echo "  xipImage       Linux kernel (XIP)"
    echo "  rootfs.cramfs  cramfs root filesystem (BusyBox only)"
    echo "  etc.jffs2      writable /etc partition"
    echo "esp-hosted binary: build/esp-hosted/esp_hosted_ng/esp/esp_driver/network_adapter/build/"
fi

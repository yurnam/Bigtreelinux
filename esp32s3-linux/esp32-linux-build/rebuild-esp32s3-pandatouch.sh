#! /bin/bash -x
#
# rebuild-esp32s3-pandatouch.sh
# ─────────────────────────────
# Build and flash Linux for the BigTreeTech PandaTouch (ESP32-S3, 8 MB flash,
# 8 MB Octal PSRAM, 800×480 RGB LCD).
#
# Designed to run:
#   a) Inside the Docker container (esp32linuxbase) with esp32s3-linux/ as /app
#   b) Natively on a host with the packages in esp32-linux-build/README
#
# Usage (inside Docker or natively, from esp32s3-linux/):
#   ./esp32-linux-build/rebuild-esp32s3-pandatouch.sh [OPTIONS]
#
# Options:
#   -c <file>    Override board config (default: ../pandatouch.conf)
#   --no-flash   Build images only, skip all flashing steps
#
# Environment variables (set in settings.cfg before running build.sh):
#   keep_toolchain=y   skip toolchain rebuild
#   keep_rootfs=y      skip rootfs rebuild (still applies overlay changes)
#   keep_buildroot=y   skip buildroot re-download
#   keep_bootloader=y  skip esp-hosted re-download
#   keep_etc=y         skip reflashing /etc partition
#   ESP_PORT=<dev>     serial port to use for flashing (e.g. /dev/ttyUSB0)
#                      if unset, idf.py/parttool.py will auto-detect
#
# PSRAM NOTE
# ──────────
# PandaTouch has 8 MB Octal-SPI (OPI) PSRAM.  The generic jcmvbkbc configs
# use QUAD-SPI mode.  Running Linux with QUAD init on OPI hardware causes
# the kernel to crash immediately (boot loop, rst:0xc).
# sdkconfig.pandatouch.defaults sets CONFIG_SPIRAM_MODE_OCT=y to fix this.
#
# DTS NOTE
# ────────
# The device tree source is handled by BR2_LINUX_KERNEL_CUSTOM_DTS_PATH in
# esp32s3_pandatouch_defconfig.  Buildroot copies the DTS into the kernel
# source tree via a post-patch hook, BEFORE the kernel is compiled.  No
# manual DTS injection is needed here.

SET_BAUDRATE='-b 2000000'

CTNG_VER=xtensa-fdpic
CTNG_CONFIG=xtensa-esp32s3-linux-uclibcfdpic
BUILDROOT_VER=xtensa-2024.08-fdpic
ESP_HOSTED_VER=ipc-5.1.1

# ── Resolve paths ─────────────────────────────────────────────────────────
# SCRIPT_DIR is esp32s3-linux/esp32-linux-build/ (or /app/esp32-linux-build/)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# LINUX_DIR is esp32s3-linux/ (one level up)
LINUX_DIR="$(realpath "$SCRIPT_DIR/..")"

PANDATOUCH_CONF="$LINUX_DIR/pandatouch.conf"
BR2_EXTERNAL_DIR="$LINUX_DIR/br2-external"
PARTITIONS_CSV="$LINUX_DIR/lcd-init/partitions.csv"
SDKCONFIG_DEFAULTS="$SCRIPT_DIR/sdkconfig.pandatouch.defaults"

# ── Helpers ────────────────────────────────────────────────────────────────
function die() { echo "ERROR: $1" >&2; exit 1; }

# Build the optional -p PORT arguments for idf.py / parttool.py.
# Usage:  idf.py "${PORT_ARGS[@]}" -b 2000000 flash
# Avoids unquoted word-splitting while still working when ESP_PORT is unset.
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

[ -f "$conf" ]              || die "Config not found: $conf"
[ -f "$PARTITIONS_CSV" ]    || die "partitions.csv not found: $PARTITIONS_CSV"
[ -f "$SDKCONFIG_DEFAULTS" ]|| die "sdkconfig.pandatouch.defaults not found: $SDKCONFIG_DEFAULTS"

. "$conf"

[ -n "$BUILDROOT_CONFIG" ] || die "BUILDROOT_CONFIG not set in $conf"

echo "=== PandaTouch Linux build ==="
echo "    BUILDROOT_CONFIG  = $BUILDROOT_CONFIG"
echo "    BR2_EXTERNAL      = $BR2_EXTERNAL_DIR"
echo "    partitions.csv    = $PARTITIONS_CSV"
echo "    NO_FLASH          = $NO_FLASH"
[ -n "${ESP_PORT:-}" ] && echo "    ESP_PORT          = $ESP_PORT"
echo ""

# ── Autoconf 2.71 ─────────────────────────────────────────────────────────
# Must be run from within esp32-linux-build/ (the script's CWD is reset below)
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

# ── Buildroot (kernel + rootfs) ───────────────────────────────────────────
# The DTS (esp32s3-pandatouch.dts) is handled entirely by Buildroot via
# BR2_LINUX_KERNEL_CUSTOM_DTS_PATH.  Buildroot copies it into the kernel
# source tree as a post-patch hook, before kernel compilation starts.
# No manual DTS injection is needed.

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

[ -f "build-buildroot-$BUILDROOT_CONFIG/images/xipImage"     ] || exit 1
[ -f "build-buildroot-$BUILDROOT_CONFIG/images/rootfs.cramfs" ] || exit 1
[ -f "build-buildroot-$BUILDROOT_CONFIG/images/etc.jffs2"     ] || exit 1

# ── esp-hosted: WiFi co-processor + Linux loader ──────────────────────────
#
# PSRAM fix applied here:
#   1. Copy partitions.csv so idf.py uses OUR partition layout.
#   2. Copy sdkconfig.pandatouch.defaults → sdkconfig.defaults so IDF
#      applies our overrides (OPI PSRAM, QIO flash, custom partition table)
#      when `idf.py set-target esp32s3` regenerates sdkconfig.
#
[ -d esp-hosted ] || git clone \
    https://github.com/jcmvbkbc/esp-hosted -b "$ESP_HOSTED_VER"

pushd esp-hosted/esp_hosted_ng/esp/esp_driver
cmake .
cd esp-idf
. export.sh
cd ../network_adapter

# --- Apply PandaTouch hardware config ---
# Step 1: Our partition table (linux at 0x120000, matching jcmvbkbc's default)
cp "$PARTITIONS_CSV" partitions.csv

# Step 2: sdkconfig.defaults with OPI PSRAM fix + custom partition pointer.
#         idf.py set-target reads this and merges it into the generated sdkconfig.
rm -f sdkconfig sdkconfig.defaults
cp "$SDKCONFIG_DEFAULTS" sdkconfig.defaults

# Step 3: Regenerate sdkconfig from IDF defaults + our sdkconfig.defaults
idf.py set-target esp32s3

# Step 4: Build
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
    echo "=== PandaTouch flash complete! ==="
    echo ""
    echo "Power-cycle the board and connect a serial terminal at 115200 baud."
    echo "(USB-C port → CH340K UART bridge → ttyUSB0 or ttyACM0)"
else
    echo ""
    echo "=== PandaTouch build complete (--no-flash) ==="
    echo "Built images in: build/build-buildroot-$BUILDROOT_CONFIG/images/"
    echo "  xipImage      Linux kernel (XIP)"
    echo "  rootfs.cramfs cramfs root filesystem"
    echo "  etc.jffs2     writable /etc partition"
    echo "esp-hosted binary: build/esp-hosted/esp_hosted_ng/esp/esp_driver/network_adapter/build/"
fi

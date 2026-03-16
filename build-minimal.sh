#!/usr/bin/env bash
# build-minimal.sh – Incremental minimal build + flash for BigTreeTech PandaTouch
#
# Run this script from the repository root:
#   ./build-minimal.sh
#   ./build-minimal.sh -p /dev/ttyUSB0
#   ./build-minimal.sh --no-flash
#   ./build-minimal.sh --clean        # force full rebuild from scratch
#
# What this builds (minimal + framebuffer)
# ─────────────────────────────────────────
# • Linux kernel with framebuffer (simple-fb, fbcon) + GT911 touch driver
# • LCD display initialised via /etc/init.d/S10display
# • BusyBox init + shell + fbset
# • Serial console (UART0, ttyS0, 115200 baud)
# • Writable /etc (jffs2)
#
# What is SKIPPED vs the full build.sh:
# • WiFi (wpa_supplicant)
# • Touchscreen userspace (tslib, evtest)
# • Network tools (iproute2)
# • Flash tools (mtd-utils)
# • USB utilities (usbutils)
# • MMIO debug tool (devmem2)
#
# Incremental by default
# ──────────────────────
# On first run everything is built from scratch (~60 min).
# On subsequent runs only the kernel/rootfs are rebuilt if files changed.
# The toolchain (crosstool-NG), Buildroot download, and esp-hosted are all
# reused automatically – no need to set keep_* flags manually.
# Use --clean to force a full rebuild from scratch.
#
# Options
# ───────
#   -p, --port  PORT        Serial port  (default: auto-detect)
#   -b, --baud  BAUD        Baud rate    (default: 2000000)
#   --no-flash              Build images only; do not flash the device
#   --skip-build            Flash pre-built images only (skip Docker build)
#   --clean                 Delete all build artefacts and rebuild from scratch
#   --docker-image  NAME    Docker image name (default: esp32linuxbase)
#   --rebuild-docker        Force rebuild of Docker image
#   -h, --help              Show this help

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
LINUX_DIR="$REPO_ROOT/esp32s3-linux"
DOCKER_IMAGE="esp32linuxbase"

# ── Defaults ──────────────────────────────────────────────────────────────
PORT=""
BAUD=2000000
NO_FLASH=0
SKIP_BUILD=0
REBUILD_DOCKER=0
CLEAN=0

# ── Colour helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[build-minimal]${NC} $*"; }
success() { echo -e "${GREEN}[build-minimal]${NC} $*"; }
warn()    { echo -e "${YELLOW}[build-minimal]${NC} $*"; }
die()     { echo -e "${RED}[build-minimal] ERROR:${NC} $*" >&2; exit 1; }

# ── Usage ─────────────────────────────────────────────────────────────────
usage() {
cat <<EOF
${BOLD}build-minimal.sh${NC} – Incremental minimal build + flash for BigTreeTech PandaTouch

${BOLD}Usage:${NC}
  ./build-minimal.sh [OPTIONS]

${BOLD}Options:${NC}
  -p, --port  PORT        Serial port  (default: auto-detect)
  -b, --baud  BAUD        Baud rate    (default: 2000000)
  --no-flash              Build images only; do not flash the device
  --skip-build            Flash pre-built images only (skip Docker build)
  --clean                 Delete all build artefacts and rebuild from scratch
  --docker-image  NAME    Docker image name (default: esp32linuxbase)
  --rebuild-docker        Force rebuild of Docker image
  -h, --help              Show this help

${BOLD}Examples:${NC}
  ./build-minimal.sh                   # incremental build + flash (auto-detect port)
  ./build-minimal.sh -p /dev/ttyUSB0  # specify serial port
  ./build-minimal.sh --no-flash        # incremental build only, no flashing
  ./build-minimal.sh --clean           # full rebuild from scratch
  ./build-minimal.sh --skip-build -p /dev/ttyUSB0  # flash pre-built images

${BOLD}Build times:${NC}
  First run:       ~60 min (toolchain + kernel + esp-hosted)
  Subsequent runs: ~5–10 min (incremental; only changed parts rebuild)

${BOLD}What is built (minimal + framebuffer):${NC}
  • Linux kernel: framebuffer, GT911 touch driver, serial console
  • Rootfs: BusyBox + fbset
  • Writable /etc (jffs2)
  • esp-hosted Linux loader (OPI PSRAM fix)
  Skipped: WiFi, tslib, iproute2, mtd-utils, usbutils, devmem2
EOF
}

# ── Argument parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--port)          PORT="$2";          shift 2 ;;
        -b|--baud)          BAUD="$2";          shift 2 ;;
        --no-flash)         NO_FLASH=1;         shift ;;
        --skip-build)       SKIP_BUILD=1;       shift ;;
        --clean)            CLEAN=1;            shift ;;
        --docker-image)     DOCKER_IMAGE="$2";  shift 2 ;;
        --rebuild-docker)   REBUILD_DOCKER=1;   shift ;;
        -h|--help)          usage; exit 0 ;;
        *)  die "Unknown option: $1  (run with --help for usage)" ;;
    esac
done

# ── Prerequisite checks ─────────────────────────────────────────────────────
check_prereqs() {
    info "Checking prerequisites..."
    local missing=0

    if ! command -v docker &>/dev/null; then
        warn "Docker not found. Install Docker: https://docs.docker.com/get-docker/"
        missing=1
    fi

    if [[ "$NO_FLASH" -eq 0 && "$SKIP_BUILD" -eq 0 ]] || [[ "$SKIP_BUILD" -eq 1 ]]; then
        if ! command -v python3 &>/dev/null; then
            warn "python3 not found (needed by esptool/parttool)"
            missing=1
        fi
    fi

    [[ "$missing" -eq 0 ]] || die "Please install the missing prerequisites and re-run."
    success "Prerequisites OK"
}

# ── Port auto-detection ─────────────────────────────────────────────────────
detect_port() {
    local candidates=(
        /dev/ttyUSB0 /dev/ttyUSB1
        /dev/ttyACM0 /dev/ttyACM1
        /dev/cu.usbserial-* /dev/cu.usbmodem*
    )
    for p in "${candidates[@]}"; do
        for dev in $p; do  # intentional unquoted glob expansion
            if [[ -c "$dev" ]]; then
                echo "$dev"
                return
            fi
        done
    done
    return 1
}

resolve_port() {
    if [[ -n "$PORT" ]]; then
        [[ -c "$PORT" ]] || die "Serial port not found: $PORT"
        info "Using serial port: $PORT"
        return
    fi

    info "Auto-detecting serial port..."
    PORT=$(detect_port) || \
        die "No serial port detected. Connect the PandaTouch USB-C cable and retry, or use -p /dev/ttyUSBx"
    info "Detected serial port: $PORT"
}

# ── Docker image build ──────────────────────────────────────────────────────
build_docker_image() {
    if [[ "$REBUILD_DOCKER" -eq 1 ]]; then
        info "Rebuilding Docker image $DOCKER_IMAGE..."
        docker build \
            --build-arg DOCKER_USER="$(id -un)" \
            --build-arg DOCKER_USERID="$(id -u)" \
            -t "$DOCKER_IMAGE" \
            "$LINUX_DIR"
        return
    fi

    if docker image inspect "$DOCKER_IMAGE" &>/dev/null; then
        info "Docker image $DOCKER_IMAGE already exists (use --rebuild-docker to force rebuild)"
        return
    fi

    info "Building Docker image $DOCKER_IMAGE (first time only)..."
    docker build \
        --build-arg DOCKER_USER="$(id -un)" \
        --build-arg DOCKER_USERID="$(id -u)" \
        -t "$DOCKER_IMAGE" \
        "$LINUX_DIR"
    success "Docker image built"
}

# ── settings.cfg ───────────────────────────────────────────────────────────
ensure_settings() {
    if [[ ! -f "$LINUX_DIR/settings.cfg" ]]; then
        info "Creating $LINUX_DIR/settings.cfg from defaults..."
        cp "$LINUX_DIR/settings.cfg.default" "$LINUX_DIR/settings.cfg"
    fi
}

# ── Flash-only (skip Docker build) ─────────────────────────────────────────
flash_prebuilt() {
    local build_dir
    build_dir="$LINUX_DIR/esp32-linux-build/build/build-buildroot-esp32s3_pandatouch_fb"

    [[ -d "$build_dir" ]] || \
        die "No pre-built images found at $build_dir. Run without --skip-build first."

    local xip="$build_dir/images/xipImage"
    local rootfs="$build_dir/images/rootfs.cramfs"
    local etc="$build_dir/images/etc.jffs2"

    [[ -f "$xip"    ]] || die "xipImage not found:      $xip"
    [[ -f "$rootfs" ]] || die "rootfs.cramfs not found: $rootfs"
    [[ -f "$etc"    ]] || die "etc.jffs2 not found:     $etc"

    local esphosted_bin
    esphosted_bin="$LINUX_DIR/esp32-linux-build/build/esp-hosted/esp_hosted_ng/esp/esp_driver/network_adapter/build/network_adapter.bin"

    info "Flashing esp-hosted..."
    if [[ -f "$esphosted_bin" ]]; then
        esptool.py -p "$PORT" -b "$BAUD" \
            --before default_reset --after hard_reset write_flash \
            --flash_mode qio --flash_freq 80m --flash_size 8MB \
            0x10000 "$esphosted_bin" \
            || die "esp-hosted flash failed"
    else
        warn "esp-hosted binary not found, skipping"
        warn "Run without --skip-build if this is your first flash"
    fi

    info "Flashing Linux kernel (xipImage)..."
    parttool.py -p "$PORT" -b "$BAUD" write_partition \
        --partition-name linux \
        --input "$xip" \
        || die "Linux kernel flash failed"

    info "Flashing rootfs..."
    parttool.py -p "$PORT" -b "$BAUD" write_partition \
        --partition-name rootfs \
        --input "$rootfs" \
        || die "rootfs flash failed"

    info "Flashing /etc..."
    parttool.py -p "$PORT" -b "$BAUD" write_partition \
        --partition-name etc \
        --input "$etc" \
        || die "/etc flash failed"

    success "All partitions flashed!"
}

# ── Docker build + flash ───────────────────────────────────────────────────
run_docker_build() {
    local docker_args=(
        run --rm -it
        --name pandatouch-linux-build-minimal
        --user "$(id -u):$(id -g)"
        --group-add dialout
        -v "$LINUX_DIR:/app"
        --env-file "$LINUX_DIR/settings.cfg"
    )

    # ── Incremental mode (default) ─────────────────────────────────────────
    # Pass keep_* flags to preserve already-built components so only changed
    # parts of the build are re-run.  --clean skips these, causing the inner
    # script to wipe the build directory and start from scratch.
    if [[ "$CLEAN" -eq 0 ]]; then
        docker_args+=(
            -e keep_toolchain=y
            -e keep_buildroot=y
            -e keep_bootloader=y
            -e keep_rootfs=y
        )
        info "Incremental mode: toolchain, Buildroot source, and esp-hosted will be reused."
        info "Use --clean to force a full rebuild from scratch."
    else
        warn "Clean build: all artefacts will be deleted and rebuilt from scratch."
    fi

    if [[ "$NO_FLASH" -eq 0 ]]; then
        docker_args+=(--device "$PORT")
        docker_args+=(-e "ESP_PORT=$PORT")
    fi

    docker_args+=("$DOCKER_IMAGE")
    docker_args+=("./esp32-linux-build/rebuild-esp32s3-pandatouch-fb.sh")

    if [[ "$NO_FLASH" -eq 1 ]]; then
        docker_args+=("--no-flash")
    fi

    info "Starting Docker build..."
    info "  Image   : $DOCKER_IMAGE"
    info "  Config  : pandatouch-fb.conf (esp32s3_pandatouch_fb)"
    info "  Volume  : $LINUX_DIR → /app"
    [[ "$NO_FLASH" -eq 0 ]] && info "  Device  : $PORT (ESP_PORT=$PORT)"
    echo ""

    docker "${docker_args[@]}"
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  PandaTouch Linux – Minimal + Framebuffer    ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    check_prereqs
    ensure_settings

    if [[ "$SKIP_BUILD" -eq 1 ]]; then
        resolve_port
        flash_prebuilt
        print_done
        return
    fi

    build_docker_image

    if [[ "$NO_FLASH" -eq 0 ]]; then
        resolve_port
    fi

    run_docker_build
    print_done
}

print_done() {
    echo ""
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════${NC}"
    if [[ "$NO_FLASH" -eq 1 ]]; then
        success "Build complete! Images are in:"
        echo "  $LINUX_DIR/esp32-linux-build/build/build-buildroot-esp32s3_pandatouch_fb/images/"
        echo ""
        echo "  To flash later, run:"
        echo "    ./build-minimal.sh --skip-build -p /dev/ttyUSB0"
    else
        success "Build and flash complete!"
        echo ""
        echo "  Next steps:"
        echo "  1. Power-cycle the PandaTouch"
        echo "  2. Open a serial terminal at 115200 baud on $PORT"
        echo "     e.g.:  minicom -b 115200 -D $PORT"
        echo "            screen $PORT 115200"
        echo "  3. Linux kernel messages appear, then a BusyBox shell"
        echo "  4. The LCD backlight should turn on via /etc/init.d/S10display"
        echo ""
        echo "  To add WiFi and tools later (incremental):"
        echo "    keep_toolchain=y keep_bootloader=y ./build.sh"
    fi
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════${NC}"
    echo ""
}

main "$@"

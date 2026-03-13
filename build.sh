#!/usr/bin/env bash
# build.sh – Build and flash Linux on the BigTreeTech PandaTouch
#
# Run this script from the repository root:
#   ./build.sh
#   ./build.sh -p /dev/ttyUSB0
#   ./build.sh --no-flash
#   ./build.sh --skip-build -p /dev/ttyACM0
#
# What it does
# ────────────
# 1. Checks prerequisites (Docker, Python/esptool).
# 2. Auto-detects the serial port if -p is not given.
# 3. Builds the Docker image (esp32linuxbase) if not already present.
# 4. Creates settings.cfg if it does not exist.
# 5. Runs rebuild-esp32s3-pandatouch.sh inside Docker, which:
#      a. Builds the Xtensa cross-compiler (crosstool-NG)
#      b. Builds the Linux kernel + cramfs rootfs + jffs2 /etc (Buildroot)
#      c. Builds the esp-hosted Linux-loader firmware (ESP-IDF)
#         with the OPI PSRAM fix for PandaTouch
#      d. Flashes everything to the device
#
# Serial port
# ────────────
# Connect the PandaTouch USB-C port to the build host.
# The CH340K USB-UART bridge presents as /dev/ttyUSB0 or /dev/ttyACM0.
# Use -p to specify the port if auto-detection fails.
#
# Build time / disk
# ─────────────────
# First build: ~35-45 min, ~20 GB disk space (inside the Docker volume).
# Subsequent builds with keep_* flags: ~5-10 min.
#
# Options
# ───────
#   -p, --port PORT     Serial port    (default: auto-detect)
#   -b, --baud BAUD     Baud rate      (default: 2000000)
#   --no-flash          Build images only, do not flash the device
#   --skip-build        Flash pre-built images only (skip Docker build)
#   --docker-image IMG  Docker image name  (default: esp32linuxbase)
#   --rebuild-docker    Force rebuild of Docker image even if it exists
#   -h, --help          Show this help and exit

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

# ── Colour helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[build]${NC} $*"; }
success() { echo -e "${GREEN}[build]${NC} $*"; }
warn()    { echo -e "${YELLOW}[build]${NC} $*"; }
die()     { echo -e "${RED}[build] ERROR:${NC} $*" >&2; exit 1; }

# ── Usage ─────────────────────────────────────────────────────────────────
usage() {
cat <<EOF
${BOLD}build.sh${NC} – Build and flash Linux for the BigTreeTech PandaTouch

${BOLD}Usage:${NC}
  ./build.sh [OPTIONS]

${BOLD}Options:${NC}
  -p, --port  PORT        Serial port  (default: auto-detect)
  -b, --baud  BAUD        Baud rate    (default: 2000000)
  --no-flash              Build images only; do not flash the device
  --skip-build            Flash pre-built images only (skip Docker build)
  --docker-image  NAME    Docker image name (default: esp32linuxbase)
  --rebuild-docker        Force rebuild of Docker image
  -h, --help              Show this help

${BOLD}Examples:${NC}
  ./build.sh                         # full build + flash (auto-detect port)
  ./build.sh -p /dev/ttyUSB0        # specify serial port
  ./build.sh --no-flash              # build only, no flashing
  ./build.sh --skip-build -p /dev/ttyUSB0  # flash pre-built images

${BOLD}Speed up rebuilds${NC} (edit esp32s3-linux/settings.cfg):
  keep_toolchain=y
  keep_buildroot=y
  keep_rootfs=y
  keep_bootloader=y
  keep_etc=y
EOF
}

# ── Argument parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--port)          PORT="$2";          shift 2 ;;
        -b|--baud)          BAUD="$2";          shift 2 ;;
        --no-flash)         NO_FLASH=1;         shift ;;
        --skip-build)       SKIP_BUILD=1;       shift ;;
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
        # Expand glob pattern; nullglob-safe: iterate over literal if no match
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
    build_dir="$LINUX_DIR/esp32-linux-build/build/build-buildroot-esp32s3_pandatouch"

    [[ -d "$build_dir" ]] || \
        die "No pre-built images found at $build_dir. Run without --skip-build first."

    local xip="$build_dir/images/xipImage"
    local rootfs="$build_dir/images/rootfs.cramfs"
    local etc="$build_dir/images/etc.jffs2"

    [[ -f "$xip"    ]] || die "xipImage not found:      $xip"
    [[ -f "$rootfs" ]] || die "rootfs.cramfs not found: $rootfs"
    [[ -f "$etc"    ]] || die "etc.jffs2 not found:     $etc"

    local esphosted_elf
    esphosted_elf="$LINUX_DIR/esp32-linux-build/build/esp-hosted/esp_hosted_ng/esp/esp_driver/network_adapter/build/network_adapter.bin"

    info "Flashing esp-hosted..."
    if [[ -f "$esphosted_elf" ]]; then
        esptool.py -p "$PORT" -b "$BAUD" \
            --before default_reset --after hard_reset write_flash \
            --flash_mode qio --flash_freq 80m --flash_size 8MB \
            0x10000 "$esphosted_elf" \
            || die "esp-hosted flash failed"
    else
        warn "esp-hosted binary not found at expected path, skipping"
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
        --name pandatouch-linux-build
        --user "$(id -u):$(id -g)"
        # Grant dialout group access so idf.py/parttool.py can open the serial port.
        # The container user is created with --user uid:gid which drops supplementary
        # groups; --group-add dialout restores serial-port access.
        --group-add dialout
        # Mount esp32s3-linux/ as /app so the script can reach
        # pandatouch.conf, br2-external/, lcd-init/, etc. via ../
        -v "$LINUX_DIR:/app"
        --env-file "$LINUX_DIR/settings.cfg"
    )

    if [[ "$NO_FLASH" -eq 0 ]]; then
        docker_args+=(--device "$PORT")
        # Pass the detected port into the container so idf.py/parttool.py use it
        docker_args+=(-e "ESP_PORT=$PORT")
    fi

    docker_args+=("$DOCKER_IMAGE")
    docker_args+=("./esp32-linux-build/rebuild-esp32s3-pandatouch.sh")

    if [[ "$NO_FLASH" -eq 1 ]]; then
        docker_args+=("--no-flash")
    fi

    info "Starting Docker build..."
    info "  Image  : $DOCKER_IMAGE"
    info "  Volume : $LINUX_DIR → /app"
    [[ "$NO_FLASH" -eq 0 ]] && info "  Device : $PORT (ESP_PORT=$PORT)"
    echo ""

    docker "${docker_args[@]}"
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  PandaTouch Linux Builder                    ║${NC}"
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
        echo "  $LINUX_DIR/esp32-linux-build/build/build-buildroot-esp32s3_pandatouch/images/"
        echo ""
        echo "  To flash later, run:"
        echo "    ./build.sh --skip-build -p /dev/ttyUSB0"
    else
        success "Build and flash complete!"
        echo ""
        echo "  Next steps:"
        echo "  1. Power-cycle the PandaTouch"
        echo "  2. Open a serial terminal at 115200 baud on $PORT"
        echo "     e.g.:  minicom -b 115200 -D $PORT"
        echo "            screen $PORT 115200"
        echo "  3. Linux kernel messages should appear, followed by a shell"
    fi
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════${NC}"
    echo ""
}

main "$@"

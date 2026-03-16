# Linux on BigTreeTech PandaTouch – Build & Flash Guide

> **Status**: Pre-alpha / bring-up.  The build infrastructure is complete;
> end-to-end testing on hardware is the next milestone.

## Table of Contents

1. [Overview](#overview)
2. [Hardware Summary](#hardware-summary)
3. [Architecture](#architecture)
4. [Prerequisites](#prerequisites)
5. [Quick Start](#quick-start)
6. [Detailed Build Steps](#detailed-build-steps)
7. [Flash Layout](#flash-layout)
8. [Framebuffer Display](#framebuffer-display)
9. [Touchscreen](#touchscreen)
10. [USB Storage (larger rootfs)](#usb-storage-larger-rootfs)
11. [WiFi](#wifi)
12. [GPIO / Backlight](#gpio--backlight)
13. [Iterative Rebuilds](#iterative-rebuilds)
14. [Troubleshooting](#troubleshooting)
15. [Known Limitations](#known-limitations)
16. [Roadmap](#roadmap)

---

## Overview

The PandaTouch is based on the **ESP32-S3** micro-controller.  The
[jcmvbkbc](http://wiki.osll.ru/doku.php/etc:users:jcmvbkbc:linux-xtensa:esp32s3)
Linux port already supports the ESP32-S3 family; this guide documents
the PandaTouch-specific adaptations that were added to this repository:

| Component | What was added |
|---|---|
| **Device tree** | `esp32s3-pandatouch.dts` – full hardware description |
| **Display** | `simple-framebuffer` DT node + `lcd-init` ESP-IDF pre-loader |
| **Touchscreen** | GT911 driver enabled via kernel config fragment |
| **Buildroot config** | `esp32s3_pandatouch_defconfig` in `br2-external/` |
| **Kernel config** | `linux-extras.config` – FB, GT911, USB storage |
| **Init scripts** | `S10display`, `S20touchscreen` in rootfs overlay |
| **Build script** | `rebuild-esp32s3-pandatouch.sh` with BR2_EXTERNAL support |

---

## Hardware Summary

| Item | Detail |
|---|---|
| SoC | ESP32-S3, dual-core Xtensa LX7 @ 240 MHz |
| Flash | 8 MB QIO @ 80 MHz (kernel XIP + cramfs rootfs) |
| PSRAM | 8 MB Octal OPI @ 80 MHz (main Linux RAM + framebuffer) |
| Display | 7″ 800 × 480 RGB565 parallel LCD (DE mode) |
| Touch | Goodix GT911, I²C0 @ 0x5D, GPIO1/2/40/41 |
| USB | USB-C (CH340K UART bridge) + USB-A (native OTG host) |
| WiFi | 2.4 GHz via esp-hosted SPI driver |

Full pinout: see [`PandaTouch_PlatformIO/docs/PINOUT.md`](../../PandaTouch_PlatformIO/docs/PINOUT.md)

---

## Architecture

```
Flash (8 MB)
┌────────────────────────────────────────────────────────────────────┐
│ 0x000000  ROM bootloader  (Espressif ROM – not stored in flash)    │
│ 0x008000  partition table                                          │
│ 0x009000  nvs (WiFi credentials, boot flags)                       │
│ 0x010000  bootloader_app  ← lcd-init + esp-hosted (chain-loader)  │
│ 0x110000  linux           ← xipImage (kernel XIP, 2.5 MB)         │
│ 0x390000  rootfs          ← cramfs root filesystem (2.5 MB)       │
│ 0x610000  etc             ← jffs2 writable /etc (512 KB)          │
│ 0x690000  reserved                                                 │
└────────────────────────────────────────────────────────────────────┘

PSRAM (8 MB, mapped at 0x3C000000)
┌────────────────────────────────────────────────────────────────────┐
│ 0x3C000000  framebuffer  800 × 480 × 2 = 768 000 B (0xBB800)      │
│ 0x3C0BB800  Linux RAM    ~7.25 MB heap, stack, process memory      │
└────────────────────────────────────────────────────────────────────┘

Boot sequence
  ROM → lcd-init (initialises LCD_CAM, draws splash in PSRAM fb)
      → esp-hosted network_adapter (loads xipImage from flash)
      → Linux kernel
          ├─ mounts cramfs rootfs from flash
          ├─ mounts jffs2 /etc from flash
          ├─ registers /dev/fb0 via simple-framebuffer DT node
          ├─ probes GT911 touch → /dev/input/event0
          └─ S10display + S20touchscreen init scripts run
```

---

## Prerequisites

### Option A – Docker (recommended)

```bash
# From the repo root:
docker build \
    --build-arg DOCKER_USER=$USER \
    --build-arg DOCKER_USERID=$UID \
    -t esp32linuxbase \
    esp32s3-linux/
```

### Option B – Native build host (Debian/Ubuntu)

```bash
sudo apt-get install -y \
    autoconf automake bash bc bison build-essential cmake flex \
    gawk git gperf help2man libncurses-dev libtool libusb-1.0-0 \
    python3 python3-pip python3-venv rsync texinfo unzip wget cpio
```

### ESP-IDF (for lcd-init and esp-hosted)

```bash
git clone --recursive https://github.com/espressif/esp-idf.git ~/esp/esp-idf
cd ~/esp/esp-idf
./install.sh esp32s3
. export.sh
```

---

## Quick Start

```bash
# 1. Clone (with submodules)
git clone --recursive https://github.com/yurnam/Bigtreelinux.git
cd Bigtreelinux

# 2. Build + flash with a single command (recommended)
./build.sh -p /dev/ttyACM0

# Or, step by step inside Docker:
cd esp32s3-linux
cp settings.cfg.default settings.cfg
docker build --build-arg DOCKER_USER=$USER --build-arg DOCKER_USERID=$UID -t esp32linuxbase .
docker run --rm -it \
    --name pandatouch-linux \
    --user="$(id -u):$(id -g)" \
    -v "$PWD:/app" \
    --env-file settings.cfg \
    --device=/dev/ttyACM0 \
    esp32linuxbase \
    ./esp32-linux-build/rebuild-esp32s3-pandatouch.sh

# 3. Power-cycle → Linux boots on the serial console (USB-C, 115200 baud)
```

---

## Detailed Build Steps

### Step 1 – Build the Linux image

Run the build script inside the Docker container (or natively):

```bash
cd esp32s3-linux/esp32-linux-build

# Docker:
docker run --rm -it \
    --name pandatouch-linux \
    --user="$(id -u):$(id -g)" \
    -v $(pwd):/app \
    --env-file ../settings.cfg \
    --device=/dev/ttyACM0 \
    esp32linuxbase \
    ./rebuild-esp32s3-pandatouch.sh

# Native:
./rebuild-esp32s3-pandatouch.sh
```

The script will:
1. Download and build autoconf 2.71
2. Build the xtensa-dynconfig overlay for ESP32-S3
3. Build the xtensa-esp32s3-linux-uclibcfdpic cross-compiler with crosstool-NG
4. Clone jcmvbkbc/buildroot, apply `esp32s3_pandatouch_defconfig` with `BR2_EXTERNAL`
5. Copy `esp32s3-pandatouch.dts` into the kernel source tree
6. Build the Linux kernel (`xipImage`) and rootfs (`cramfs` + `jffs2`)
7. Build and flash esp-hosted (WiFi co-processor firmware + Linux loader)
8. Flash `xipImage`, `rootfs.cramfs`, and `etc.jffs2`

**Expected build time:** ~35–45 minutes on a modern machine.
**Disk space required:** ~20 GB.

### Step 2 – Build and flash the lcd-init pre-loader

```bash
cd esp32s3-linux/lcd-init
. ~/esp/esp-idf/export.sh       # or wherever IDF is installed

idf.py set-target esp32s3
idf.py build

# Flash to the board (use the correct port)
idf.py -p /dev/ttyACM0 -b 2000000 flash
```

The lcd-init application:
1. Performs a hard reset of the LCD panel (GPIO46)
2. Allocates 768 KB at the start of PSRAM (0x3C000000)
3. Configures the ESP32-S3 LCD_CAM peripheral for 800 × 480 RGB565 output
4. Draws a splash screen and shows a colour-bar test pattern
5. Leaves the display scanning autonomously from PSRAM

> **Note:** In production the lcd-init code should be merged into the
> esp-hosted `network_adapter` firmware so only one application needs to
> be flashed.  The standalone application is provided here for display
> verification and development convenience.

### Step 3 – Boot Linux

1. Power-cycle (or reset via RST button).
2. The display should light up and show the splash screen.
3. Connect a serial terminal to the USB-C port at **115200 8N1**.
4. Linux kernel messages appear, then a BusyBox shell prompt.

---

## Flash Layout

| Partition | Offset | Size | Content |
|---|---|---|---|
| nvs | 0x009000 | 16 KB | NVS (WiFi creds, etc.) |
| otadata | 0x00D000 | 8 KB | OTA metadata |
| phy_init | 0x00F000 | 4 KB | RF calibration |
| bootloader_app | 0x010000 | 1 MB + 64 KB | esp-hosted Linux loader |
| linux | **0x120000** | 2.4375 MB | Linux `xipImage` (XIP addr `0x42120000`) |
| rootfs | 0x390000 | 2.5 MB | cramfs root filesystem |
| etc | 0x610000 | 512 KB | jffs2 writable `/etc` |
| reserved | 0x690000 | ~1.4 MB | future use |

> **Why 0x120000?**  The esp-hosted firmware reports `linux ptr = 0x42120000` at
> boot. `0x42000000` is the ESP32-S3 flash XIP base, so the Linux partition must
> be at flash offset `0x120000`. The factory-app partition is sized `0x110000`
> (1 MB + 64 KB) so that it ends exactly at `0x120000`.

Partition table: [`lcd-init/partitions.csv`](../lcd-init/partitions.csv)

---

## Framebuffer Display

### How it works

The ESP32-S3's **LCD_CAM** peripheral drives the parallel RGB bus.  It
performs autonomous DMA scan-out from a region in PSRAM without CPU
intervention.  The lcd-init app configures this peripheral and allocates
the framebuffer at the start of PSRAM (physical address `0x3C000000`).

The Linux device tree node:

```dts
framebuffer0: framebuffer@3c000000 {
    compatible = "simple-framebuffer";
    reg = <0x3c000000 0x000bb800>;   /* 800 × 480 × 2 bytes */
    width  = <800>;
    height = <480>;
    stride = <1600>;
    format = "r5g6b5";
    status = "okay";
};
```

The kernel's `simplefb` driver maps this region and registers `/dev/fb0`.
`fbcon` then uses `/dev/fb0` as the virtual text console.

### Verifying the display

```bash
# Check framebuffer device
fbset -fb /dev/fb0

# Draw a test pattern (writes raw RGB565 data)
cat /dev/urandom > /dev/fb0   # random noise – confirms fb0 is working

# Clear to black
dd if=/dev/zero of=/dev/fb0 bs=768000 count=1

# Show framebuffer info
cat /sys/class/graphics/fb0/virtual_size
```

### Backlight

The backlight is controlled by **GPIO21** (active HIGH).  It is turned on
during the `S10display` init script via GPIO sysfs:

```bash
echo 21   > /sys/class/gpio/export
echo out  > /sys/class/gpio/gpio21/direction
echo 1    > /sys/class/gpio/gpio21/value   # on
echo 0    > /sys/class/gpio/gpio21/value   # off
```

For brightness control (PWM), use `devmem` to write to the LEDC
peripheral registers, or wait for a Linux PWM driver to be added.

---

## Touchscreen

The **Goodix GT911** driver (`CONFIG_TOUCHSCREEN_GOODIX=y`) is included in
the kernel config fragment.  The I²C device is declared in the DTS at
address `0x5D` on I²C bus 0.

```bash
# List input devices
ls -la /dev/input/
cat /sys/class/input/event0/device/name   # should print "Goodix Capacitive TouchScreen"

# Monitor raw touch events
evtest /dev/input/event0

# Calibrate (if tslib is installed)
ts_calibrate
ts_test
```

Touch events are delivered as standard Linux multi-touch protocol B
events via the input subsystem.

---

## USB Storage (larger rootfs)

The USB-A port (GPIO19/20, native OTG PHY) supports USB host mode.
`CONFIG_USB_STORAGE=y` and `CONFIG_VFAT_FS=y` / `CONFIG_EXT4_FS=y` are
enabled so a USB thumb drive can be mounted.

```bash
# Plug a FAT32 / ext4 USB drive into the USB-A port
dmesg | tail -20         # should show usb 1-1: new USB device...
ls /dev/sda*             # sda, sda1, ...
mount /dev/sda1 /mnt
ls /mnt

# To use USB storage as root (edit /etc/cmdline):
echo 'console=ttyS0,115200n8 root=/dev/sda1 rootfstype=ext4 rw rootwait fbcon=map:0' \
    > /etc/cmdline
reboot
```

> **Status:** USB host mode depends on the esp-hosted firmware correctly
> exposing the OTG port.  This has not been tested on PandaTouch yet.

---

## WiFi

WiFi is provided by the ESP32-S3 radio via the **esp-hosted** SPI driver
(same as other ESP32-S3 Linux boards).

```bash
# Configure WiFi credentials
cat > /etc/wpa_supplicant.conf <<EOF
network={
    ssid="YOUR-SSID"
    psk="YOUR-PASSWORD"
}
EOF

# Start WiFi
wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf
udhcpc -i wlan0

# SSH in
ip addr show wlan0
```

---

## GPIO / Backlight

Direct register access (same as other ESP32-S3 Linux boards):

```bash
# Enable GPIO21 output (bit 21 = 0x200000)
devmem 0x60004020 32 0x200000   # output enable
devmem 0x60004004 32 0x200000   # drive high (backlight on)
devmem 0x60004008 32 0x200000   # drive low  (backlight off)
```

Full GPIO register reference:
[ESP32-S3 Technical Reference Manual §5](https://www.espressif.com/sites/default/files/documentation/esp32-s3_technical_reference_manual_en.pdf)

---

## Iterative Rebuilds

Edit `settings.cfg` to skip unchanged components:

```bash
keep_toolchain=y
keep_buildroot=y
keep_rootfs=y      # re-run the build but skip defconfig + clean
keep_bootloader=y
keep_etc=y         # don't reflash /etc
```

Then re-run:

```bash
docker run --rm -it \
    --name pandatouch-linux \
    --user="$(id -u):$(id -g)" \
    -v ./esp32-linux-build:/app \
    --env-file settings.cfg \
    --device=/dev/ttyACM0 \
    esp32linuxbase \
    ./rebuild-esp32s3-pandatouch.sh
```

---

## Troubleshooting

### Display blank after boot

- Check that the `lcd-init` app was flashed **before** the esp-hosted firmware.
- Verify the `simple-framebuffer` node in the DTS matches the physical
  address of the PSRAM buffer allocated by lcd-init.  The address is
  printed over UART: `Framebuffer: 768000 bytes at 0x3c000000 (PSRAM)`.
- Run `dmesg | grep -i fb` to confirm the driver registered `/dev/fb0`.

### No serial output

- Ensure USB-C is connected to a computer (provides UART via CH340K).
- Open a terminal at **115200 8N1** (e.g., `minicom -b 115200 -D /dev/ttyUSB0`).
- Check `bootargs` in `esp32s3-pandatouch.dts` – `console=ttyS0,115200n8`.

### Build fails: `esp32s3_pandatouch_defconfig` not found

The defconfig is in `br2-external/configs/` and requires `BR2_EXTERNAL` to
be set.  The `rebuild-esp32s3-pandatouch.sh` script sets this automatically.
If running manually:

```bash
make -C buildroot \
    O=$PWD/build-buildroot-esp32s3_pandatouch \
    BR2_EXTERNAL=/absolute/path/to/br2-external \
    esp32s3_pandatouch_defconfig
```

### DTS errors: `esp32s3.dtsi` not found

The base DTSI must exist in the ESP32-S3 Linux kernel source.  It is
provided by jcmvbkbc's `linux-xtensa` tree (`xtensa-fdpic` branch) at
`arch/xtensa/boot/dts/esp32s3.dtsi`.  If the node names (`&uart0`,
`&i2c0`, etc.) differ in the kernel version being used, adjust
`esp32s3-pandatouch.dts` accordingly.

### Touch not working

```bash
dmesg | grep -i goodix    # driver should probe at i2c0-0x5d
ls /dev/input/            # event0 should appear
evtest /dev/input/event0  # touch the screen
```

If the driver fails to probe, check the I²C address (it may be `0x14`
instead of `0x5D` if the ADDR pin is pulled high).  Update the `reg`
property in the DTS.

---

## Known Limitations

| Area | Status |
|---|---|
| LCD_CAM kernel driver | Using `simple-framebuffer` (display init in pre-loader) |
| PWM backlight | GPIO-only for now; PWM dimming via devmem |
| USB host | Untested on PandaTouch; depends on esp-hosted OTG support |
| Touchscreen rotation | Not calibrated; may need `xinput` transform |
| Audio | No audio hardware on PandaTouch |
| DRM/KMS | Not implemented; `simple-framebuffer` used instead |

---

## Roadmap

- [ ] Test full boot on PandaTouch hardware
- [ ] Merge lcd-init into esp-hosted network_adapter
- [ ] Add PWM backlight via Linux `pwm-backlight` driver
- [ ] Verify USB host / USB storage on PandaTouch
- [ ] Calibrate GT911 touch for correct X/Y mapping
- [ ] Write an ESP32-S3 LCD_CAM DRM/KMS driver for mainline Linux
- [ ] Add framebuffer splash image with PandaTouch logo
- [ ] Document USB rootfs procedure once USB host is confirmed

# Bigtreelinux

Resources for running Linux on the **BigTreeTech PandaTouch** (ESP32-S3 based 7″ 800×480 touchscreen).

## Repository structure

| Directory | Contents |
|---|---|
| [`PandaTouch_PlatformIO/`](PandaTouch_PlatformIO/) | Arduino / PlatformIO template for the PandaTouch (LVGL 9, GT911 touch, RGB LCD) |
| [`esp32s3-linux/`](esp32s3-linux/) | Docker-based Linux build environment for ESP32-S3 |
| [`esp32s3-linux/br2-external/`](esp32s3-linux/br2-external/) | Buildroot external tree with PandaTouch-specific config |
| [`esp32s3-linux/lcd-init/`](esp32s3-linux/lcd-init/) | ESP-IDF app that initialises the RGB LCD before Linux boots |
| [`esp32s3-linux/esp32s3-pandatouch.dts`](esp32s3-linux/esp32s3-pandatouch.dts) | Linux device tree for PandaTouch |
| [`esp32s3-linux/docs/PANDATOUCH_LINUX.md`](esp32s3-linux/docs/PANDATOUCH_LINUX.md) | Full Linux build & flash guide |

## Linux on PandaTouch – quick start

```bash
git clone --recursive https://github.com/yurnam/Bigtreelinux.git
cd Bigtreelinux/esp32s3-linux

# Build Docker image
docker build --build-arg DOCKER_USER=$USER --build-arg DOCKER_USERID=$UID -t esp32linuxbase .

# Build Linux with framebuffer display + GT911 touch support
cp settings.cfg.default settings.cfg
docker run --rm -it --name pandatouch-linux \
    --user="$(id -u):$(id -g)" \
    -v ./esp32-linux-build:/app \
    --env-file settings.cfg \
    --device=/dev/ttyACM0 \
    esp32linuxbase \
    ./rebuild-esp32s3-pandatouch.sh

# Flash the LCD pre-loader (requires ESP-IDF v5)
cd lcd-init && idf.py set-target esp32s3 && idf.py -p /dev/ttyACM0 flash
```

See **[esp32s3-linux/docs/PANDATOUCH_LINUX.md](esp32s3-linux/docs/PANDATOUCH_LINUX.md)** for the full guide.

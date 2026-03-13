#! /bin/bash -x

if [ ! -d autoconf-2.71/root/bin ] ; then
	wget https://ftp.gnu.org/gnu/autoconf/autoconf-2.71.tar.xz
	tar -xf autoconf-2.71.tar.xz
	pushd autoconf-2.71
	./configure --prefix=`pwd`/root
	make && make install
	popd
fi      
export PATH=`pwd`/autoconf-2.71/root/bin:$PATH
rm -rf build
mkdir build && cd build

#
# dynconfig
#
git clone https://github.com/jcmvbkbc/xtensa-dynconfig -b original
git clone https://github.com/jcmvbkbc/config-esp32s3 esp32s3
make -C xtensa-dynconfig ORIG=1 CONF_DIR=`pwd` esp32s3.so
export XTENSA_GNU_CONFIG=`pwd`/xtensa-dynconfig/esp32s3.so

#
# toolchain
#
git clone https://github.com/jcmvbkbc/crosstool-NG.git -b xtensa-fdpic
pushd crosstool-NG
./bootstrap && ./configure --enable-local && make
./ct-ng xtensa-esp32s3-linux-uclibcfdpic
CT_PREFIX=`pwd`/builds nice ./ct-ng build
popd
[ -e crosstool-NG/builds/xtensa-esp32s3-linux-uclibcfdpic/bin/xtensa-esp32s3-linux-uclibcfdpic-gcc ] || exit 1

#
# kernel and rootfs
#
git clone https://github.com/jcmvbkbc/buildroot -b xtensa-2023.02-fdpic

#
# Patch Buildroot's busybox.mk for Xtensa-MMU targets
#
# In the jcmvbkbc xtensa-fdpic fork the BR2_XTENSA_USE_MMU → BR2_USE_MMU
# Kconfig chain is broken.  busybox.mk's BUSYBOX_KCONFIG_FIXUP_CMDS runs
# KCONFIG_DISABLE_OPT,CONFIG_MMU *after* any config fragment, overriding
# CONFIG_MMU=y and causing ash to fail:
#   shell/ash.c: #error "Do not even bother, ash will not run on NOMMU machine"
# This sed is idempotent; it is safe to apply on every run.
if ! grep -q 'BR2_XTENSA_USE_MMU' buildroot/package/busybox/busybox.mk 2>/dev/null; then
	sed -i 's#\$(if \$(BR2_USE_MMU),,#$(if $(or $(BR2_USE_MMU),$(BR2_XTENSA_USE_MMU)),,#' \
		buildroot/package/busybox/busybox.mk
fi

nice make -C buildroot O=`pwd`/build-xtensa-2023.02-fdpic-esp32s3 esp32s3_defconfig
buildroot/utils/config --file build-xtensa-2023.02-fdpic-esp32s3/.config --set-str TOOLCHAIN_EXTERNAL_PATH `pwd`/crosstool-NG/builds/xtensa-esp32s3-linux-uclibcfdpic
buildroot/utils/config --file build-xtensa-2023.02-fdpic-esp32s3/.config --set-str TOOLCHAIN_EXTERNAL_PREFIX '$(ARCH)-esp32s3-linux-uclibcfdpic'
buildroot/utils/config --file build-xtensa-2023.02-fdpic-esp32s3/.config --set-str TOOLCHAIN_EXTERNAL_CUSTOM_PREFIX '$(ARCH)-esp32s3-linux-uclibcfdpic'
nice make -C buildroot O=`pwd`/build-xtensa-2023.02-fdpic-esp32s3
[ -f build-xtensa-2023.02-fdpic-esp32s3/images/xipImage -a -f build-xtensa-2023.02-fdpic-esp32s3/images/rootfs.cramfs ] || exit 1

#
# bootloader
#
git clone https://github.com/jcmvbkbc/esp-idf -b linux-5.0.1
pushd esp-idf
. export.sh
cd examples/get-started/linux_boot
idf.py set-target esp32s3
cp sdkconfig.defaults.esp32s3 sdkconfig
idf.py build
read -p 'ready to flash... press enter'
idf.py flash
popd

#
# flash
#
parttool.py write_partition --partition-name linux  --input build-xtensa-2023.02-fdpic-esp32s3/images/xipImage
parttool.py write_partition --partition-name rootfs --input build-xtensa-2023.02-fdpic-esp32s3/images/rootfs.cramfs

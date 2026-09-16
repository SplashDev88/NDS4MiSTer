#!/bin/sh
set -eu
mkdir -p /build/kernel /build/toolchain /build/module
tar -xf /inputs/Linux-Kernel_MiSTer-794e6f.tar.gz -C /build/kernel --strip-components=1
python3 -c 'import lzma,shutil,sys; shutil.copyfileobj(lzma.open("/inputs/gcc-arm-10.2-2020.11-aarch64-arm-none-linux-gnueabihf.tar.xz"), sys.stdout.buffer)' | tar -xf - -C /build/toolchain --strip-components=1
cp /source/kernel/nds_mem_wc/config-5.15.1-MiSTer /build/kernel/.config
cp /source/kernel/nds_mem_wc/nds_mem_wc.c /source/kernel/nds_mem_wc/Makefile /build/module/
export ARCH=arm
export CROSS_COMPILE=/build/toolchain/bin/arm-none-linux-gnueabihf-
export KBUILD_BUILD_TIMESTAMP='2026-09-16 00:00:00 UTC'
export KBUILD_BUILD_USER=nds4mister
export KBUILD_BUILD_HOST=reproducible
"${CROSS_COMPILE}gcc" --version > /output/compiler.txt
make -C /build/kernel olddefconfig
make -C /build/kernel -j2 modules_prepare
cp /build/kernel/.config /output/prepared.config
cp /build/kernel/include/generated/utsrelease.h /output/utsrelease.h
make -C /build/module KDIR=/build/kernel KBUILD_MODPOST_WARN=1
cp /build/module/nds_mem_wc.ko /output/nds_mem_wc.ko
cp /build/module/nds_mem_wc.mod.c /output/nds_mem_wc.mod.c
"${CROSS_COMPILE}readelf" -a /output/nds_mem_wc.ko > /output/readelf.txt
"${CROSS_COMPILE}nm" -u /output/nds_mem_wc.ko > /output/imports.txt
sha256sum /output/nds_mem_wc.ko > /output/nds_mem_wc.ko.sha256
strings /output/nds_mem_wc.ko | sed -n '/^vermagic=/p' > /output/vermagic.txt
cp /build/kernel/COPYING /output/KERNEL_COPYING
cp /build/kernel/LICENSES/preferred/GPL-2.0 /output/GPL-2.0.txt

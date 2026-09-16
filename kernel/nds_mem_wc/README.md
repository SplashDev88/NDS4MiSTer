# Restricted write-combined publication mapping

This small GPL-2.0 Linux module exposes `/dev/nds_mem_wc` for NDS4MiSTer's
side-effect-free HPS pixel publication RAM only: physical `0x3fd00000` through
`0x3fffffff`. It rejects mappings outside that fixed three-MiB aperture. It
does not allocate RAM, modify the FPGA, change clocks, or map H3D control words.

The source preserves the NDS4MiSTer restricted implementation used in local
August 2026 testing. Its approach was inspired by skmp's DreamSTer/minicast
[`mem_wc`](https://github.com/skmp/minicast/blob/934b374fa0a7f3cccb2c56c0ca72ec935300a8a3/mem_wc/mem_wc.c).
Keep this source and its GPL-2.0 license with any distributed module binary.

The ARM helper must map control and pixels without overlapping memory types,
drain pixel stores with `dsb sy` before publishing a descriptor, and retain
the existing bank/session/quiesce ownership checks. WC is Normal Non-Cacheable,
not write-back cached RAM and not a substitute for coherency management.

## Building for the tested kernel

The release was tested on a target running `5.15.1-MiSTer SMP mod_unload ARMv7 p2v8`,
compiled with Arm GNU Toolchain 10.2-2020.11 / GCC 10.2.1. The module build uses
Linux-Kernel_MiSTer commit
`794e6f002d0f655c504733c126a01f8c1f0bc1d4`. The exact prepared kernel configuration
is included as `config-5.15.1-MiSTer`. Kernel preparation added only the disabled
`CONFIG_HID_VADER4` entry relative to the target's configuration.
Do not substitute the current default kernel branch or force an incompatible
module to load. The helper's GCC 13.3 renderer build is independent and must
retain its accepted compiler/options.

On a Linux build host, prepare that pinned kernel source using the saved live
config and the matching ARM cross compiler, then build this directory:

```sh
export ARCH=arm
export CROSS_COMPILE=/path/to/gcc-arm-10.2-2020.11/bin/arm-none-linux-gnueabihf-
cp kernel/nds_mem_wc/config-5.15.1-MiSTer /path/to/pinned-kernel/.config
make -C /path/to/pinned-kernel olddefconfig
make -C /path/to/pinned-kernel modules_prepare
make -C kernel/nds_mem_wc KDIR=/path/to/pinned-kernel
```

Kernel preparation also needs ordinary host build dependencies including
flex, bison, bc, OpenSSL and the GMP/MPFR/MPC development headers for this
configuration's GCC plugin. Compare the prepared config to the saved target
config and verify the result's vermagic, ELF architecture and imported symbols.

`modules_prepare` does not generate `Module.symvers`. Prefer the matching
kernel build's symbol table when available. The shipped module build has
`CONFIG_MODVERSIONS` and module signing disabled; its otherwise unresolved
modpost warnings were individually checked against live kernel symbol names
and the matching source's `EXPORT_SYMBOL` definitions. Normal `insmod`, restricted
mapping-boundary checks and unloading passed on
the physical test MiSTer. Compatibility with every other kernel is unproven.
Never use `--force` to bypass that gate.

`tools/stage_hybrid_3d_hps_payload.sh SERVICE NEW_DIRECTORY MODULE.ko` stages
the existing optional module/hash pair. Kickstart verifies both hashes before
loading and falls back to ordinary Device publication if a compatible module
is unavailable. There is no kernel replacement or permanent boot hook.

## Recorded release build

`BUILD_PROVENANCE.json` records the exact kernel, compiler archives, config,
module identity and build metadata. `build-release.sh` preserves the release
commands and fixed build timestamp/user/host. It expects a disposable Linux
container with `/source` holding this source checkout, `/inputs` holding the two
archives named in the provenance, an empty `/build`, and writable `/output`.
The cross-compiler archive runs on an AArch64 Linux host. For example:

```sh
docker build --platform linux/arm64/v8 -t nds-wc-builder kernel/nds_mem_wc
docker run --rm --platform linux/arm64/v8 --network none \
  -v "$PWD:/source:ro" -v /path/to/downloads:/inputs:ro \
  -v /path/to/output:/output nds-wc-builder \
  sh /source/kernel/nds_mem_wc/build-release.sh
```

Verify both downloaded archive hashes before building. The script uses
`KBUILD_MODPOST_WARN=1` because the recorded kernel preparation did not have
`Module.symvers`; this does not bypass the kernel's runtime module loader.
The six imported symbols were checked against the live kernel and the pinned
source export declarations. Matching vermagic alone does not prove another
kernel build is compatible. Never force loading a rejected module.

The main project license does not replace this module's GPL-2.0 license.
See `COPYING`. The installer carries that license and links to this complete
module source in the matching GitHub release's automatic source archives.

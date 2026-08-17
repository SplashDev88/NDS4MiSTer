# CMake toolchain for the DE10-Nano's HPS: Cyclone V SoC, dual Cortex-A9 with
# NEON, armhf (32-bit, hard-float). Used by build-armhf.sh inside a Debian
# container that has crossbuild-essential-armhf.
#
# -mcpu=cortex-a9 -mfpu=neon is not decoration: this bench exists to predict
# whether the A9 can rasterize a DS frame, and a generic armv7 build without
# NEON would answer a question about a CPU nobody is shipping.
#
# Static, because MiSTer's userland is a minimal image with no promise about
# glibc version or which shared libraries exist. A dynamically linked binary
# that fails to start on the board wastes a round trip to find out. glibc 2.34+
# folds libpthread into libc, so static std::thread works on bookworm and later.
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)

set(CMAKE_C_COMPILER   arm-linux-gnueabihf-gcc)
set(CMAKE_CXX_COMPILER arm-linux-gnueabihf-g++)

set(CMAKE_FIND_ROOT_PATH /usr/arm-linux-gnueabihf)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(A9_FLAGS "-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard")
set(CMAKE_C_FLAGS_INIT   "${A9_FLAGS}")
set(CMAKE_CXX_FLAGS_INIT "${A9_FLAGS}")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static")

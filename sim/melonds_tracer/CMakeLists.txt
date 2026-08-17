# Headless melonDS tracer for the M3 differential trace (docs/TRACE_DIFF.md).
# Consumes the melonDS core as a subproject; point MELONDS_DIR at a checkout
# of melonDS 1.1 with tracer.patch applied (build.sh does all of this).
cmake_minimum_required(VERSION 3.15)
project(melonds_tracer CXX C)

set(MELONDS_DIR "" CACHE PATH "Path to melonDS 1.1 source checkout")
if (NOT MELONDS_DIR)
    message(FATAL_ERROR "set -DMELONDS_DIR=/path/to/melonDS")
endif()

list(APPEND CMAKE_MODULE_PATH "${MELONDS_DIR}/cmake")

set(BUILD_QT_SDL OFF CACHE BOOL "" FORCE)
set(ENABLE_JIT OFF CACHE BOOL "" FORCE)
set(ENABLE_OGLRENDERER OFF CACHE BOOL "" FORCE)
set(ENABLE_GDBSTUB OFF CACHE BOOL "" FORCE)
set(ENABLE_LTO_RELEASE OFF CACHE BOOL "" FORCE)

add_subdirectory(${MELONDS_DIR} melonds-core EXCLUDE_FROM_ALL)

add_executable(melonds_tracer main.cpp Platform.cpp)
target_compile_features(melonds_tracer PRIVATE cxx_std_17)
target_include_directories(melonds_tracer PRIVATE ${MELONDS_DIR}/src)
target_link_libraries(melonds_tracer PRIVATE core)

# framebuffer dump for the M5 frame diff (tb_top_frame vs melonDS)
add_executable(melonds_fbdump main_fbdump.cpp Platform.cpp)
target_compile_features(melonds_fbdump PRIVATE cxx_std_17)
target_include_directories(melonds_fbdump PRIVATE ${MELONDS_DIR}/src)
target_link_libraries(melonds_fbdump PRIVATE core)

# A9 rasterizer timing bench (sim/melonds_tracer/main_gxbench.cpp). Built for
# armhf by build-armhf.sh and run on the DE10-Nano; builds natively too, which
# is how the scene savestate gets captured.
add_executable(melonds_gxbench main_gxbench.cpp Platform.cpp)
target_compile_features(melonds_gxbench PRIVATE cxx_std_17)
target_include_directories(melonds_gxbench PRIVATE ${MELONDS_DIR}/src)
target_link_libraries(melonds_gxbench PRIVATE core)

# default-firmware image dump for the RTL SPI flash (sim/tests/nds_firmware.hex)
add_executable(melonds_fwdump main_fwdump.cpp Platform.cpp)
target_compile_features(melonds_fwdump PRIVATE cxx_std_17)
target_include_directories(melonds_fwdump PRIVATE ${MELONDS_DIR}/src)
target_link_libraries(melonds_fwdump PRIVATE core)

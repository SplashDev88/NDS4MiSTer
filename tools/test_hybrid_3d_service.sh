#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/h3d-service.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

repo_real=$(cd "$repo_dir" && pwd -P)
build_dir=
for candidate in \
    "${H3D_BUILD_DIR:-}" \
    "$repo_dir/build-mac-melonds" \
    "$repo_dir/build-host" \
    "$repo_dir/build"; do
    [[ -n "$candidate" ]] || continue
    cache=$candidate/CMakeCache.txt
    [[ -f "$cache" ]] || continue
    source_dir=$(sed -n \
        's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$cache" | tail -1)
    [[ -n "$source_dir" && -d "$source_dir" ]] || continue
    source_real=$(cd "$source_dir" && pwd -P)
    if [[ "$source_real" == "$repo_real" && \
          -f "$candidate/third_party/melonDS/src/libcore.a" && \
          -f "$candidate/third_party/melonDS/src/teakra/src/libteakra.a" ]]; then
        build_dir=$candidate
        break
    fi
done

if [[ -z "$build_dir" ]]; then
    cmake_bin=${CMAKE:-$(command -v cmake || true)}
    ninja_bin=${NINJA:-$(command -v ninja || true)}
    git_common=$(git -C "$repo_dir" rev-parse --path-format=absolute \
        --git-common-dir 2>/dev/null || true)
    project_root=${git_common%/.git}
    for tooling in "$project_root/.tooling/bin" \
        "$(dirname "$project_root")/.tooling/bin"; do
        if [[ -z "$cmake_bin" && -x "$tooling/cmake" ]]; then
            cmake_bin=$tooling/cmake
        fi
        if [[ -z "$ninja_bin" && -x "$tooling/ninja" ]]; then
            ninja_bin=$tooling/ninja
        fi
    done
    if [[ -z "$cmake_bin" || -z "$ninja_bin" ]]; then
        echo "FAIL: a source-matched melonDS build needs cmake and ninja" >&2
        exit 1
    fi

    build_dir=$tmp_dir/core-build
    "$cmake_bin" -S "$repo_dir" -B "$build_dir" -G Ninja \
        -DCMAKE_MAKE_PROGRAM="$ninja_bin" \
        -DCMAKE_BUILD_TYPE=Release \
        -DNDS4MISTER_USE_MELONDS=ON \
        -DNDS4MISTER_ENABLE_JIT=OFF \
        -DBUILD_QT_SDL=OFF \
        -DENABLE_OGLRENDERER=OFF >/dev/null
    "$cmake_bin" --build "$build_dir" --target core -j 8 >/dev/null
fi

link_options=(-pthread)
if [[ $(uname -s) != Darwin ]]; then
    link_options+=(-ldl)
fi

"${CXX:-c++}" \
    -std=c++17 -O2 -fwrapv -Wall -Wextra -Werror -pedantic \
    -DNDS4MISTER_CORE_TIMING=0 \
    -DNDS4MISTER_NO_2D_RENDER=0 \
    -DNDS4MISTER_NO_3D_RENDER=0 \
    -DNDS4MISTER_NO_AUDIO_MIX=0 \
    -DNDS4MISTER_NO_VIDEO_RENDER=0 \
    -I"$repo_dir/src" \
    -isystem "$repo_dir/third_party/melonDS/src" \
    -isystem "$build_dir/third_party/melonDS/src" \
    "$repo_dir/src/replay/Hybrid3DService.cpp" \
    "$repo_dir/src/replay/Hybrid3DFramePacket.cpp" \
    "$repo_dir/src/replay/ArmVideoShadow.cpp" \
    "$repo_dir/src/replay/ArmCrashDump.cpp" \
    "$repo_dir/src/replay/FpgaCrashMonitor.cpp" \
    "$repo_dir/src/melonds/HeadlessPlatform.cpp" \
    "$build_dir/third_party/melonDS/src/libcore.a" \
    "$build_dir/third_party/melonDS/src/teakra/src/libteakra.a" \
    "${link_options[@]}" \
    -o "$tmp_dir/nds_hybrid_3d_service"

"$tmp_dir/nds_hybrid_3d_service" --self-test
python3 "$repo_dir/tools/test_h3d_fake_memory_lifecycle.py" \
    "$tmp_dir/nds_hybrid_3d_service"

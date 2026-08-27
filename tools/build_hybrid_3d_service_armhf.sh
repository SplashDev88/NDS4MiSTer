#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
image=${IMAGE:-nds4mister-armhf:ubuntu-24.04}
build_dir=${BUILD_DIR:-build-mister-hybrid-3d-armhf}
parallel=${PARALLEL:-2}
claim=/private/tmp/nds4mister-docker-exclusive-claim

if [[ -e "$claim" || -L "$claim" || -n "$(docker ps -q)" ]]; then
  echo "FAIL: Docker or the global Docker claim is busy" >&2
  exit 3
fi
if ! mkdir "$claim" 2>/dev/null; then
  echo "FAIL: could not acquire the global Docker claim" >&2
  exit 3
fi
printf 'owner=hybrid_3d_service_armhf pid=%s utc=%s\n' \
  "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$claim/owner"
cleanup() {
  rm -f "$claim/owner"
  rmdir "$claim" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

if ! docker image inspect "$image" >/dev/null 2>&1; then
  docker build --platform linux/arm64/v8 \
    -f "$repo_root/tools/Dockerfile.mister-armhf" \
    -t "$image" "$repo_root"
fi

docker run --rm --network none \
  -v "$repo_root:/work" \
  -w /work \
  "$image" \
  sh -lc "
    set -eu
    cmake -S . -B '$build_dir' \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/arm-linux-gnueabihf.cmake \
      -DNDS4MISTER_USE_MELONDS=ON \
      -DNDS4MISTER_ENABLE_LTO_RELEASE=ON \
      -DNDS4MISTER_ENABLE_JIT=OFF \
      -DNDS4MISTER_CORE_TIMING=OFF \
      -DNDS4MISTER_NO_2D_RENDER=OFF \
      -DNDS4MISTER_NO_3D_RENDER=OFF \
      -DNDS4MISTER_NO_AUDIO_MIX=ON \
      -DCMAKE_C_FLAGS_RELEASE='-O3 -DNDEBUG' \
      -DCMAKE_CXX_FLAGS_RELEASE='-O3 -DNDEBUG'
    cmake --build '$build_dir' \
      --target nds_hybrid_3d_service --parallel '$parallel'
    file '$build_dir/nds_hybrid_3d_service' |
      grep -q 'ELF 32-bit LSB executable, ARM.*statically linked'
    '$build_dir/nds_hybrid_3d_service' --self-test
    sha256sum '$build_dir/nds_hybrid_3d_service'
  "

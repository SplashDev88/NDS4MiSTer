#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd "$(dirname "$0")" && pwd)
python3 "$source_dir/generate_menu.py"
image=${IMAGE:-nds4mister-armhf:ubuntu-24.04}
docker run --rm --network none -v "$source_dir:/work" -w /work "$image" \
 arm-linux-gnueabihf-g++ -std=c++17 -O2 -Wall -Wextra -Werror -static \
 -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard host.cpp -o nds_standalone_host

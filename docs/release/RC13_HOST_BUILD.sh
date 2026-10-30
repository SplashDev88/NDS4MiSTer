#!/bin/sh
set -eu
cd /src/tools/standalone_host
g++ -std=c++17 -O2 -Wall -Wextra -Werror test_fmv_rom_reader.cpp -o /out/test_fmv_rom_reader
/out/test_fmv_rom_reader /src/tools/standalone_host/fmv
g++ -std=c++17 -O2 -Wall -Wextra -Werror test_host_framed.cpp -o /out/test_host_framed
/out/test_host_framed
arm-linux-gnueabihf-g++ -std=c++17 -O2 -Wall -Wextra -Werror -static -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard host.cpp -o /out/nds_standalone_host

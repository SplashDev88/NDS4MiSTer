set -eu
cd /src/tools/standalone_host
arm-linux-gnueabihf-g++ -std=c++17 -O2 -Wall -Wextra -Werror -static -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard host.cpp -o /out/nds_standalone_host-issue43

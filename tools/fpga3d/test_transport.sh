#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
mkdir -p build-fpga3d
${CXX:-c++} -std=c++17 -O2 -Itools/fpga3d tools/fpga3d/transport_test.cpp -o build-fpga3d/transport_test
build-fpga3d/transport_test

#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu
cd "$(dirname "$0")/../.."
mkdir -p build-fpga3d
${CXX:-c++} -std=c++17 -O2 -Itools/fpga3d tools/fpga3d/span_test.cpp -o build-fpga3d/span_test
build-fpga3d/span_test

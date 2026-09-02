#pragma once

#include <cstdint>
#include <string>

namespace nds4mister {

struct Options {
    std::string rom_path;
    std::string json_path;
    std::string trace_2d_path;
    std::uint32_t frames = 600;
    std::uint32_t warmup_frames = 0;
};

bool parse_options(int argc, char** argv, Options& options, std::string& error);
void print_usage(const char* argv0);

} // namespace nds4mister

#include "bench/Options.h"

#include <charconv>
#include <iostream>
#include <system_error>

namespace nds4mister {
namespace {

bool parse_u32(const char* text, std::uint32_t& value)
{
    const std::string input(text);
    const char* begin = input.data();
    const char* end = input.data() + input.size();
    const auto result = std::from_chars(begin, end, value);
    return result.ec == std::errc() && result.ptr == end;
}

} // namespace

bool parse_options(int argc, char** argv, Options& options, std::string& error)
{
    for (int i = 1; i < argc; ++i) {
        const std::string arg(argv[i]);

        if (arg == "--rom") {
            if (++i >= argc) {
                error = "--rom requires a path";
                return false;
            }
            options.rom_path = argv[i];
        } else if (arg == "--frames") {
            if (++i >= argc || !parse_u32(argv[i], options.frames) || options.frames == 0) {
                error = "--frames requires a positive integer";
                return false;
            }
        } else if (arg == "--warmup-frames") {
            if (++i >= argc || !parse_u32(argv[i], options.warmup_frames)) {
                error = "--warmup-frames requires a non-negative integer";
                return false;
            }
        } else if (arg == "--json") {
            if (++i >= argc) {
                error = "--json requires a path";
                return false;
            }
            options.json_path = argv[i];
        } else if (arg == "--trace-2d") {
            if (++i >= argc) {
                error = "--trace-2d requires a path";
                return false;
            }
            options.trace_2d_path = argv[i];
        } else if (arg == "--help" || arg == "-h") {
            print_usage(argv[0]);
            return false;
        } else {
            error = "unknown argument: " + arg;
            return false;
        }
    }

    if (options.rom_path.empty()) {
        error = "--rom is required";
        return false;
    }

    return true;
}

void print_usage(const char* argv0)
{
    std::cout << "Usage: " << argv0
              << " --rom game.nds [--frames 600] [--warmup-frames 60]"
              << " [--json result.json] [--trace-2d trace.bin]\n";
}

} // namespace nds4mister

#include "melonds/MelonDsBackend.h"

#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

struct TouchWindow {
    std::uint32_t first = 0;
    std::uint32_t last = 0;
    std::uint16_t x = 0;
    std::uint16_t y = 0;
};

TouchWindow parse_window(const char* text)
{
    TouchWindow out {};
    char tail = 0;
    if (std::sscanf(text, "%u:%u:%hu:%hu%c", &out.first, &out.last,
                    &out.x, &out.y, &tail) != 4 || out.first > out.last ||
        out.x > 255 || out.y > 191)
        throw std::runtime_error(
            "touch window must be first:last:x:y in native DS coordinates");
    return out;
}

struct Capture {
    std::uint32_t target = 0;
    std::array<std::uint32_t, 256 * 192> top {};
    std::array<std::uint32_t, 256 * 192> bottom {};
    std::array<bool, 192> lines {};

    static void receive(std::uint32_t frame, std::uint16_t line,
                        const std::uint32_t* top,
                        const std::uint32_t* bottom, void* userdata)
    {
        auto& self = *static_cast<Capture*>(userdata);
        if (frame != self.target || line >= 192) return;
        std::copy_n(top, 256, self.top.data() + line * 256);
        std::copy_n(bottom, 256, self.bottom.data() + line * 256);
        self.lines[line] = true;
    }
};

void write_ppm(const std::string& path,
               const std::array<std::uint32_t, 256 * 192>& pixels)
{
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    out << "P6\n256 192\n255\n";
    for (const auto pixel : pixels) {
        const std::array<char, 3> rgb {
            static_cast<char>(pixel & 0xffu),
            static_cast<char>((pixel >> 8) & 0xffu),
            static_cast<char>((pixel >> 16) & 0xffu),
        };
        out.write(rgb.data(), static_cast<std::streamsize>(rgb.size()));
    }
    if (!out) throw std::runtime_error("failed to write " + path);
}

} // namespace

int main(int argc, char** argv) try
{
    if (argc < 4) {
        std::cerr << "usage: nds_touch_oracle_probe ROM OUTPUT_PREFIX FRAMES "
                     "[FIRST:LAST:X:Y ...]\n";
        return 2;
    }
    const auto frames = static_cast<std::uint32_t>(std::strtoul(argv[3], nullptr, 10));
    if (!frames) throw std::runtime_error("FRAMES must be nonzero");
    std::vector<TouchWindow> windows;
    for (int index = 4; index < argc; ++index)
        windows.push_back(parse_window(argv[index]));

    nds4mister::MelonDsBackend backend;
    std::string error;
    if (!backend.load_rom(argv[1], error)) throw std::runtime_error(error);
    Capture capture;
    capture.target = frames - 1;
    backend.set_output_line_sink(&Capture::receive, &capture);
    nds4mister::FrameTimings timings {};
    for (std::uint32_t frame = 0; frame < frames; ++frame) {
        const auto active = std::find_if(
            windows.begin(), windows.end(), [frame](const TouchWindow& window) {
                return frame >= window.first && frame <= window.last;
            });
        if (active == windows.end()) backend.set_touch(false);
        else backend.set_touch(true, active->x, active->y);
        if (!backend.run_frame(timings, error)) throw std::runtime_error(error);
    }
    backend.set_output_line_sink(nullptr, nullptr);
    const auto captured = std::count(capture.lines.begin(), capture.lines.end(), true);
    if (captured != 192)
        throw std::runtime_error("final framebuffer capture was incomplete");
    const std::string prefix = argv[2];
    write_ppm(prefix + "-top.ppm", capture.top);
    write_ppm(prefix + "-bottom.ppm", capture.bottom);
    std::cout << "frames=" << frames << " screen_swap=" << backend.screen_swap()
              << " touch_windows=" << windows.size() << '\n';
    return 0;
} catch (const std::exception& error) {
    std::cerr << "nds_touch_oracle_probe: " << error.what() << '\n';
    return 1;
}

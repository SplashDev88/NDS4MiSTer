#include "core/NullEmulatorBackend.h"

#include <chrono>
#include <fstream>
#include <thread>

namespace nds4mister {
namespace {

double elapsed_seconds(std::chrono::steady_clock::time_point start,
                       std::chrono::steady_clock::time_point end)
{
    return std::chrono::duration<double>(end - start).count();
}

} // namespace

const char* NullEmulatorBackend::name() const
{
    return "null";
}

bool NullEmulatorBackend::load_rom(const std::string& path, std::string& error)
{
    std::ifstream rom(path, std::ios::binary);
    if (!rom) {
        error = "failed to open ROM: " + path;
        return false;
    }

    return true;
}

bool NullEmulatorBackend::run_frame(FrameTimings& timings, std::string& error)
{
    (void)error;

    const auto cpu_start = std::chrono::steady_clock::now();
    std::this_thread::sleep_for(std::chrono::microseconds(100));
    const auto cpu_end = std::chrono::steady_clock::now();

    const auto gpu_start = std::chrono::steady_clock::now();
    std::this_thread::sleep_for(std::chrono::microseconds(40));
    const auto gpu_end = std::chrono::steady_clock::now();

    const auto audio_start = std::chrono::steady_clock::now();
    std::this_thread::sleep_for(std::chrono::microseconds(20));
    const auto audio_end = std::chrono::steady_clock::now();

    timings.cpu_seconds = elapsed_seconds(cpu_start, cpu_end);
    timings.gpu_seconds = elapsed_seconds(gpu_start, gpu_end);
    timings.audio_seconds = elapsed_seconds(audio_start, audio_end);
    return true;
}

} // namespace nds4mister


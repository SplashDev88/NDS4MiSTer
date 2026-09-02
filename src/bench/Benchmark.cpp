#include "bench/Benchmark.h"

#include <chrono>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>

namespace nds4mister {
namespace {

constexpr double kDsFps = 60.0;

double elapsed_seconds(std::chrono::steady_clock::time_point start,
                       std::chrono::steady_clock::time_point end)
{
    return std::chrono::duration<double>(end - start).count();
}

bool run_frames(IEmulatorBackend& backend,
                std::uint32_t frames,
                BenchmarkResult* result,
                std::string& error)
{
    const auto start = std::chrono::steady_clock::now();

    for (std::uint32_t frame = 0; frame < frames; ++frame) {
        FrameTimings frame_timings;
        if (!backend.run_frame(frame_timings, error)) {
            return false;
        }

        if (result != nullptr) {
            result->cpu_seconds += frame_timings.cpu_seconds;
            result->gpu_seconds += frame_timings.gpu_seconds;
            result->audio_seconds += frame_timings.audio_seconds;
        }
    }

    const auto end = std::chrono::steady_clock::now();
    if (result != nullptr) {
        result->total_seconds = elapsed_seconds(start, end);
        const double measured = result->cpu_seconds + result->gpu_seconds + result->audio_seconds;
        result->other_seconds = result->total_seconds > measured
            ? result->total_seconds - measured
            : 0.0;
    }

    return true;
}

std::string json_escape(const std::string& value)
{
    std::ostringstream out;
    for (const char ch : value) {
        switch (ch) {
        case '\\':
            out << "\\\\";
            break;
        case '"':
            out << "\\\"";
            break;
        case '\n':
            out << "\\n";
            break;
        case '\r':
            out << "\\r";
            break;
        case '\t':
            out << "\\t";
            break;
        default:
            out << ch;
            break;
        }
    }
    return out.str();
}

} // namespace

bool run_benchmark(IEmulatorBackend& backend,
                   const Options& options,
                   BenchmarkResult& result,
                   std::string& error)
{
    if (!options.trace_2d_path.empty()
        && !backend.set_2d_trace_path(options.trace_2d_path, error)) {
        return false;
    }

    if (!backend.load_rom(options.rom_path, error)) {
        return false;
    }

    if (options.warmup_frames > 0 && !run_frames(backend, options.warmup_frames, nullptr, error)) {
        return false;
    }

    return run_frames(backend, options.frames, &result, error);
}

void print_report(const IEmulatorBackend& backend,
                  const Options& options,
                  const BenchmarkResult& result)
{
    const double target_seconds = static_cast<double>(options.frames) / kDsFps;
    const double fps = static_cast<double>(options.frames) / result.total_seconds;
    const double speed_percent = target_seconds / result.total_seconds * 100.0;

    std::cout << std::fixed << std::setprecision(4);
    std::cout << "NDS4MiSTer benchmark\n";
    std::cout << "backend: " << backend.name() << "\n";
    std::cout << "rom: " << options.rom_path << "\n";
    std::cout << "frames: " << options.frames << "\n";
    std::cout << "warmup_frames: " << options.warmup_frames << "\n";
    std::cout << "total_seconds: " << result.total_seconds << "\n";
    std::cout << "target_seconds: " << target_seconds << "\n";
    std::cout << "effective_fps: " << fps << "\n";
    std::cout << "speed_percent: " << speed_percent << "\n";
    std::cout << "cpu_seconds: " << result.cpu_seconds << "\n";
    std::cout << "gpu_seconds: " << result.gpu_seconds << "\n";
    std::cout << "audio_seconds: " << result.audio_seconds << "\n";
    std::cout << "other_seconds: " << result.other_seconds << "\n";
    std::cout << "full_speed: " << (result.total_seconds <= target_seconds ? "yes" : "no") << "\n";
}

bool write_json_report(const IEmulatorBackend& backend,
                       const Options& options,
                       const BenchmarkResult& result,
                       std::string& error)
{
    if (options.json_path.empty()) {
        return true;
    }

    std::ofstream out(options.json_path);
    if (!out) {
        error = "failed to open JSON report for writing: " + options.json_path;
        return false;
    }

    const double target_seconds = static_cast<double>(options.frames) / kDsFps;
    const double fps = static_cast<double>(options.frames) / result.total_seconds;
    const double speed_percent = target_seconds / result.total_seconds * 100.0;

    out << std::fixed << std::setprecision(6);
    out << "{\n";
    out << "  \"backend\": \"" << json_escape(backend.name()) << "\",\n";
    out << "  \"rom\": \"" << json_escape(options.rom_path) << "\",\n";
    out << "  \"frames\": " << options.frames << ",\n";
    out << "  \"warmup_frames\": " << options.warmup_frames << ",\n";
    out << "  \"total_seconds\": " << result.total_seconds << ",\n";
    out << "  \"target_seconds\": " << target_seconds << ",\n";
    out << "  \"effective_fps\": " << fps << ",\n";
    out << "  \"speed_percent\": " << speed_percent << ",\n";
    out << "  \"cpu_seconds\": " << result.cpu_seconds << ",\n";
    out << "  \"gpu_seconds\": " << result.gpu_seconds << ",\n";
    out << "  \"audio_seconds\": " << result.audio_seconds << ",\n";
    out << "  \"other_seconds\": " << result.other_seconds << ",\n";
    out << "  \"full_speed\": " << (result.total_seconds <= target_seconds ? "true" : "false") << "\n";
    out << "}\n";

    return true;
}

} // namespace nds4mister

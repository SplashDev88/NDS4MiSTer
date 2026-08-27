#pragma once

#include <cstdint>
#include <string>

namespace nds4mister {

struct FrameTimings {
    double cpu_seconds = 0.0;
    double gpu_seconds = 0.0;
    double audio_seconds = 0.0;
};

class IEmulatorBackend {
public:
    virtual ~IEmulatorBackend() = default;

    virtual const char* name() const = 0;
    virtual bool set_2d_trace_path(const std::string& path, std::string& error)
    {
        (void)path;
        error = "backend does not support 2D trace output";
        return false;
    }
    virtual bool load_rom(const std::string& path, std::string& error) = 0;
    virtual bool run_frame(FrameTimings& timings, std::string& error) = 0;
};

} // namespace nds4mister

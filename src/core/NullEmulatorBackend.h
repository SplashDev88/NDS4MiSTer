#pragma once

#include "core/EmulatorBackend.h"

namespace nds4mister {

class NullEmulatorBackend final : public IEmulatorBackend {
public:
    const char* name() const override;
    bool load_rom(const std::string& path, std::string& error) override;
    bool run_frame(FrameTimings& timings, std::string& error) override;
};

} // namespace nds4mister


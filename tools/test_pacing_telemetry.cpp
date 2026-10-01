// SPDX-License-Identifier: GPL-3.0-only
#include "replay/FpgaCrashMonitor.h"
#include "replay/Hybrid3DAbi.h"
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <unistd.h>

namespace {
std::atomic<bool> requested {false};
void require(bool ok, const char* message)
{
    if (!ok) throw std::runtime_error(message);
}
}
namespace nds4mister::crash {
// Exercise the real recorder without installing signals or mapping hardware.
bool consume_manual_fpga_snapshot_request() { return requested.exchange(false); }
}

int main()
try {
    using namespace nds4mister::crash;
    namespace fs = std::filesystem;
    char pattern[] = "/tmp/nds-pacing-recorder-test-XXXXXX";
    const char* name = mkdtemp(pattern);
    require(name != nullptr, "temporary directory");
    const fs::path directory(name);
    setenv("NDS4MISTER_CRASH_REPORT_DIR", name, 1);
    FpgaRuntimeTelemetry runtime;
    for (bool enabled : {true, false}) {
        const auto session = enabled ? 7u : 8u;
        runtime.reset(session);
        for (const auto& value : runtime.pacing)
            require(value.load() == 0, "session reset retained pacing values");
        runtime.pacing[static_cast<std::size_t>(PacingMetric::Enabled)] = enabled;
        runtime.pacing[static_cast<std::size_t>(PacingMetric::Admitted)] = 42;
        runtime.pacing[static_cast<std::size_t>(PacingMetric::DrawUs)] = 12345;
        nds4mister::h3d::Header header {};
        header.magic = nds4mister::h3d::Magic;
        header.fpga_session = session;
        header.accepted_session = session;
        header.service_state = static_cast<std::uint32_t>(nds4mister::h3d::ServiceState::Ready);
        std::string report;
        {
            FpgaCrashMonitor monitor(&header, true, &runtime);
            requested = true;
            const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(3);
            while (std::chrono::steady_clock::now() < until) {
                for (const auto& entry : fs::directory_iterator(directory)) {
                    if (entry.path().filename().string().find("_s" + std::to_string(session) + "_") == std::string::npos)
                        continue;
                    std::ifstream file(entry.path());
                    std::ostringstream text;
                    text << file.rdbuf();
                    report = text.str();
                }
                if (report.find("samples_csv=") != std::string::npos &&
                    (!enabled || report.find(",7,1,2a,0,0,0,0,3039,") != std::string::npos)) break;
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
            }
        }
        require(report.find("reason=manual_state_dump") != std::string::npos, "manual report missing");
        require(report.find("publication_replacements,publication_high_water\n") != std::string::npos,
                "original CSV columns changed");
        require((report.find("pacing_csv=elapsed_ms,session,enabled,admitted,") != std::string::npos) == enabled,
                "pacing table enabled state wrong");
        if (enabled) require(report.find(",7,1,2a,0,0,0,0,3039,") != std::string::npos,
                             "pacing table hex values or columns wrong");
    }
    fs::remove_all(directory);
    std::cout << "PACING_RECORDER_PASS reset=1 opt_in=1 original_csv_preserved=1 hex_values=1 private_ram_only=1\n";
    return 0;
} catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
}

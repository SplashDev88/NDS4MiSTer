#include "replay/FpgaCrashMonitor.h"
#include "replay/Hybrid3DAbi.h"
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sys/resource.h>
#include <thread>
namespace { std::atomic<bool> requested{false}; }
namespace nds4mister::crash {
bool consume_manual_fpga_snapshot_request() { return requested.exchange(false); }
}
int main(int argc,char** argv) {
    if(argc!=2) return 2;
    const std::filesystem::path dir(argv[1]);
    std::filesystem::create_directories(dir);
    setenv("NDS4MISTER_CRASH_REPORT_DIR",argv[1],1);
    const rlimit cap{16777216,16777216};
    if(setrlimit(RLIMIT_FSIZE,&cap)) return 3;
    nds4mister::h3d::Header h{};
    h.magic=nds4mister::h3d::Magic; h.fpga_session=7;
    nds4mister::crash::FpgaRuntimeTelemetry runtime;
    runtime.reset(7);
    runtime.timeline=std::make_unique<nds4mister::crash::CausalTimeline>();
    auto& t=*runtime.timeline;
    // Synthetic full rings exercise the largest possible binary report.
    for(std::uint32_t i=1;i<=131072;++i) {
        t.intake.append({i,7,1,i,i,0,0});
        t.replay.append({i,7,7,i,i,0,0});
        if(i<=16384)t.publication.append({i,7,12,i,i,0,0});
    }
    std::filesystem::path result;
    {
        nds4mister::crash::FpgaCrashMonitor monitor(&h,true,&runtime);
        requested.store(true);
        for(unsigned n=0;n<1000 && result.empty();++n) {
            for(const auto& entry:std::filesystem::directory_iterator(dir))
                if(entry.path().extension()==".bin")result=entry.path();
            if(result.empty())std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
    }
    if(result.empty() || std::filesystem::file_size(result)!=24+3*20+(131072+131072+16384)*32ull) return 4;
    std::cout << "CAUSAL_REPORT_PASS file=" << result << " bytes=" << std::filesystem::file_size(result) << " cap=16777216\n";
}

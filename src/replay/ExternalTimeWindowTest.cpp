#include "melonds/MelonDsBackend.h"

#include <iostream>

int main()
{
    nds4mister::MelonDsBackend backend;
    if (!backend.external_time_window_capable())
    {
        std::cerr << "external time-window test target lacks capability\n";
        return 1;
    }
    if (!nds4mister::MelonDsBackend::self_test_external_time_window())
    {
        std::cerr << "external time-window scheduler closure self-test failed\n";
        return 1;
    }
    std::cout
        << "PASS: default-off external time window separates processed and "
           "run-safe frontiers, scans raw scheduler events, closes equal-time "
           "callbacks and both DMA domains, advances only through explicit "
           "successive boundaries, preserves exact ordered IRQ set/clear "
           "transitions, mirrors exactly-once FPGA-owned ARM9 IF word W1C "
           "with GXFIFO parity but no duplicate ETW records, truncates a "
           "verified grant at an exact dual-CPU blocking-MMIO barrier, binds "
           "one immutable CPU/RW/width/address/data/PC request to its "
           "epoch/group/P/R/event/fence identity, echoes exact replacement "
           "and B semantics, rejects dirty prior IRQ suffixes, mismatches, "
           "replay, and both skew-overflow directions, rolls back failed "
           "ungranted tails, and requires reset after committed faults\n";
    return 0;
}

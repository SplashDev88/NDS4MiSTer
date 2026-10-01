#include "replay/CausalTimeline.h"
#include <cstdlib>
#include <iostream>
#include <thread>
using namespace nds4mister::crash;
static void check(bool value) { if(!value) std::abort(); }
int main() {
    TimelineLane ring(64);
    for(std::uint32_t i=1;i<=200;++i)
        ring.append({i,7,2,i,i*3,i*5,i*7});
    auto snapshot=ring.snapshot(199);
    check(snapshot.published==200 && snapshot.overwritten==136 && snapshot.raced==0);
    check(snapshot.records.size()==63 && snapshot.records.front().us==137 && snapshot.records.back().us==199);
    TimelineLane concurrent(128);
    std::atomic<bool> done{false};
    std::thread producer([&]{
        for(std::uint32_t i=1;i<=200000;++i)
            concurrent.append({std::uint64_t(i)<<32 | i, i,2,i,i*3,i*5,i*7});
        done.store(true,std::memory_order_release);
    });
    std::uint64_t validated=0;
    do {
        auto snap=concurrent.snapshot(~0ull);
        std::uint32_t last=0;
        for(const auto& r:snap.records) {
            check(r.sequence>last && r.us==(std::uint64_t(r.sequence)<<32 | r.sequence));
            check(r.session==r.sequence && r.kind==2 && r.frame==r.sequence*3 && r.a==r.sequence*5 && r.b==r.sequence*7);
            last=r.sequence; ++validated;
        }
    } while(!done.load(std::memory_order_acquire));
    producer.join();
    check(validated!=0 && concurrent.snapshot(~0ull).records.back().sequence==200000);
    std::cout<<"CAUSAL_TIMELINE_PASS wrap=1 cutoff=1 concurrent_records="<<validated<<"\n";
}

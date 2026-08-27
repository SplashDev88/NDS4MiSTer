#include "melonds/MelonDsBackend.h"
#include "replay/LiveHgsEncoder.h"

#include <array>
#include <atomic>
#include <chrono>
#include <cstring>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <thread>
#include <vector>

namespace {
struct HgsHeader {
    char magic[4];
    std::uint16_t version;
    std::uint16_t header_size;
    std::uint64_t stream_size;
};
static_assert(sizeof(HgsHeader)==16);
}

int main(int argc,char** argv) {
    if(argc<2 || argc>4){std::cerr<<"usage: nds_live_hgs_test rom [frames] [output.hgs]\n";return 2;}
    const std::uint32_t frames=argc>=3?static_cast<std::uint32_t>(std::strtoul(argv[2],nullptr,10)):600;
    std::ofstream output;
    if(argc==4) {
        output.open(argv[3],std::ios::binary|std::ios::trunc);
        const HgsHeader header{{'H','G','S','1'},2,sizeof(HgsHeader),0};
        if(!output.write(reinterpret_cast<const char*>(&header),sizeof(header))) return 6;
    }
    nds4mister::MelonDsBackend backend; std::string error;
    if(!backend.load_rom(argv[1],error)){std::cerr<<error<<"\n";return 3;}
    nds4mister::HpsGpuRingControl control; control.capacity=1u<<20;
    std::vector<std::byte> storage(control.capacity); nds4mister::HpsGpuRing ring(control,storage.data()); nds4mister::LiveHgsEncoder encoder(ring);
    std::atomic<bool> done=false,output_ok=true; std::array<std::uint64_t,10> type_counts{}; std::uint64_t output_bytes=16;
    std::thread consumer([&]{ std::array<std::uint8_t,4092> payload{}; for(;;){std::uint16_t type=0,size=0;if(ring.pop(type,payload.data(),payload.size(),size)){if(type<type_counts.size())type_counts[type]++;output_bytes+=4+size;if(output&&output_ok.load(std::memory_order_relaxed)){const nds4mister::HpsGpuRecordHeader header{type,static_cast<std::uint16_t>(sizeof(header)+size)};if(!output.write(reinterpret_cast<const char*>(&header),sizeof(header))||!output.write(reinterpret_cast<const char*>(payload.data()),size))output_ok.store(false,std::memory_order_relaxed);}continue;}if(done.load(std::memory_order_acquire)&&control.producer.load()==control.consumer.load())break;std::this_thread::yield();} });
    backend.set_2d_trace_sink([](const void* data,std::size_t size,void* userdata){static_cast<nds4mister::LiveHgsEncoder*>(userdata)->feed(data,size);},&encoder);
    const auto start=std::chrono::steady_clock::now(); nds4mister::FrameTimings timings{};
    for(std::uint32_t i=0;i<frames;i++) {
        if(!backend.run_frame(timings,error)){std::cerr<<error<<"\n";return 4;}
        if((i+1)%60==0 || i+1==frames) {
            const double elapsed=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
            std::cerr<<"progress frames="<<(i+1)<<" seconds="<<elapsed<<" input_records="<<encoder.input_records()<<" output_records="<<encoder.output_records()<<"\n";
        }
    }
    backend.set_2d_trace_sink(nullptr,nullptr); const auto end=std::chrono::steady_clock::now();
    done.store(true,std::memory_order_release); consumer.join(); if(!encoder.finish())return 5;
    if(output) {
        if(!output_ok.load(std::memory_order_relaxed)) return 7;
        output.seekp(0);
        const HgsHeader header{{'H','G','S','1'},2,sizeof(HgsHeader),output_bytes};
        if(!output.write(reinterpret_cast<const char*>(&header),sizeof(header))) return 7;
        output.close();
        if(!output) return 7;
    }
    const double seconds=std::chrono::duration<double>(end-start).count();
    std::cout<<"Live emulator-to-HGS2 ring test\nframes: "<<frames<<"\nseconds: "<<seconds<<"\neffective_fps: "<<frames/seconds
             <<"\ninput_records: "<<encoder.input_records()<<"\noutput_records: "<<encoder.output_records()<<"\nskipped_records: "<<encoder.skipped_records()<<"\noutput_bytes: "<<output_bytes<<"\nring_drained: yes\n";
    for(std::size_t i=1;i<type_counts.size();i++)std::cout<<"type_"<<i<<": "<<type_counts[i]<<"\n";
}

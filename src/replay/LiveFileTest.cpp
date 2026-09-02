#include "replay/LiveHgsEncoder.h"

#include <array>
#include <atomic>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <thread>
#include <vector>

struct HgsHeader { char magic[4]; std::uint16_t version,header_size; std::uint64_t stream_size; };

int main(int argc,char** argv) {
    if(argc!=3){std::cerr<<"usage: hgs_live_file_test trace-v9 exact.hgs\n";return 2;}
    std::ifstream source(argv[1],std::ios::binary),expected(argv[2],std::ios::binary);
    melonDS::NDS4MiSTer::Trace2DFileHeader trace_header{}; HgsHeader hgs_header{};
    if(!source.read(reinterpret_cast<char*>(&trace_header),sizeof(trace_header)) || !expected.read(reinterpret_cast<char*>(&hgs_header),sizeof(hgs_header))) return 3;
    nds4mister::HpsGpuRingControl control; control.capacity=1u<<20;
    std::vector<std::byte> storage(control.capacity); nds4mister::HpsGpuRing ring(control,storage.data()); nds4mister::LiveHgsEncoder encoder(ring);
    std::atomic<bool> done=false; std::thread producer([&]{
        std::array<std::uint8_t,8191> bytes{}; std::size_t iteration=0;
        while(source) { const auto want=1+(iteration++*7919)%bytes.size(); source.read(reinterpret_cast<char*>(bytes.data()),want); const auto got=source.gcount(); if(got>0) encoder.feed(bytes.data(),static_cast<std::size_t>(got)); }
        done.store(true,std::memory_order_release);
    });
    std::array<std::uint8_t,4092> actual{},wanted{}; std::uint64_t records=0,bytes=0;
    for(;;) {
        nds4mister::HpsGpuRecordHeader eh{};
        if(!expected.read(reinterpret_cast<char*>(&eh),sizeof(eh))) break;
        if(eh.size<sizeof(eh) || eh.size-sizeof(eh)>wanted.size()) return 4;
        expected.read(reinterpret_cast<char*>(wanted.data()),eh.size-sizeof(eh)); if(!expected) return 5;
        std::uint16_t type=0,size=0;
        while(!ring.pop(type,actual.data(),actual.size(),size)) { if(done.load(std::memory_order_acquire) && control.producer.load()==control.consumer.load()) return 6; std::this_thread::yield(); }
        if(type!=eh.type || size!=eh.size-sizeof(eh) || std::memcmp(actual.data(),wanted.data(),size)!=0) { std::cerr<<"mismatch at record "<<records<<"\n";return 7; }
        records++; bytes+=sizeof(eh)+size;
    }
    producer.join();
    if(!encoder.finish() || control.producer.load()!=control.consumer.load()) return 8;
    std::cout<<"Live HGS2 full-stream test\nrecords: "<<records<<"\nbytes: "<<bytes+sizeof(HgsHeader)
             <<"\ninput_records: "<<encoder.input_records()<<"\nskipped_records: "<<encoder.skipped_records()
             <<"\nrecord_exact: passed\npayload_exact: passed\n";
}

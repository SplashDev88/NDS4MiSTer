#include "replay/LiveHgsEncoder.h"

#include <array>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <thread>
#include <vector>

using namespace melonDS::NDS4MiSTer;

template<typename T> void append(std::vector<std::uint8_t>& out,const T& value) {
    const auto* p=reinterpret_cast<const std::uint8_t*>(&value); out.insert(out.end(),p,p+sizeof(value));
}

int main() {
    nds4mister::HpsGpuRingControl control; control.capacity=4096;
    std::vector<std::byte> storage(control.capacity); nds4mister::HpsGpuRing ring(control,storage.data());
    nds4mister::LiveHgsEncoder encoder(ring); std::vector<std::uint8_t> raw;

    Trace2DScanlinePacket scan{}; scan.Frame=7; scan.VRAMCNT[0]=0x81;
    append(raw,Trace2DRecordHeader{static_cast<std::uint16_t>(Trace2DRecordType::Scanline),static_cast<std::uint16_t>(sizeof(Trace2DRecordHeader)+sizeof(scan))}); append(raw,scan);
    append(raw,Trace2DRecordHeader{static_cast<std::uint16_t>(Trace2DRecordType::Scanline),static_cast<std::uint16_t>(sizeof(Trace2DRecordHeader)+sizeof(scan))}); append(raw,scan);
    Trace2DGeometryFramePacket frame{{static_cast<std::uint16_t>(Trace2DRecordType::GeometryFrame),static_cast<std::uint16_t>(sizeof(Trace2DGeometryFramePacket))},7,0,1,2,3}; append(raw,frame);
    Trace2DFramebufferScanlinePacket oracle{}; oracle.Record={static_cast<std::uint16_t>(Trace2DRecordType::FramebufferScanline),static_cast<std::uint16_t>(sizeof(oracle))}; append(raw,oracle);

    std::thread producer([&]{ for(std::size_t p=0;p<raw.size();) { const auto n=std::min<std::size_t>(1+(p%17),raw.size()-p); encoder.feed(raw.data()+p,n); p+=n; } });
    std::array<std::uint16_t,4> expected{2,7,7,5}; std::array<std::uint8_t,4092> payload{};
    for(std::size_t i=0;i<expected.size();) { std::uint16_t type=0,size=0; if(!ring.pop(type,payload.data(),payload.size(),size)){std::this_thread::yield();continue;} if(type!=expected[i++]) return 1; }
    producer.join();
    if(!encoder.finish() || encoder.input_records()!=4 || encoder.output_records()!=4 || encoder.skipped_records()!=1) return 2;
    std::cout<<"Live HGS2 encoder test\nfragment_reassembly: passed\nmap_deduplication: passed\noracle_filtering: passed\nordering: passed\n";
}

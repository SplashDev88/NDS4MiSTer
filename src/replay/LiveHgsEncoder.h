#pragma once

#include "NDS4MiSTer_2DTrace.h"
#include "replay/HpsGpuRing.h"

#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <thread>
#include <vector>

namespace nds4mister {

class LiveHgsEncoder {
public:
    explicit LiveHgsEncoder(HpsGpuRing& ring) : ring_(ring) {}

    void feed(const void* data, std::size_t size) {
        const auto* bytes=static_cast<const std::uint8_t*>(data);
        pending_.insert(pending_.end(),bytes,bytes+size);
        while (pending_.size()>=sizeof(melonDS::NDS4MiSTer::Trace2DRecordHeader)) {
            melonDS::NDS4MiSTer::Trace2DRecordHeader h{};
            std::memcpy(&h,pending_.data(),sizeof(h));
            if (h.Size<sizeof(h) || h.Size>4096) { failed_=true; return; }
            if (pending_.size()<h.Size) return;
            encode(h,pending_.data()+sizeof(h),h.Size-sizeof(h));
            pending_.erase(pending_.begin(),pending_.begin()+h.Size);
        }
    }

    bool finish() { return !failed_ && pending_.empty(); }
    std::uint64_t input_records() const { return input_records_; }
    std::uint64_t output_records() const { return output_records_; }
    std::uint64_t skipped_records() const { return skipped_records_; }

private:
    void push(std::uint16_t type,const void* payload,std::uint16_t size) {
        while (!ring_.push(type,payload,size)) std::this_thread::sleep_for(std::chrono::microseconds(50));
        output_records_++;
    }

    void encode(const melonDS::NDS4MiSTer::Trace2DRecordHeader& h,const std::uint8_t* payload,std::uint16_t size) {
        using namespace melonDS::NDS4MiSTer;
        input_records_++;
        const auto type=static_cast<Trace2DRecordType>(h.Type);
        if (type==Trace2DRecordType::MemoryDelta) {
            if (size<sizeof(Trace2DMemoryDeltaHeader)-sizeof(h)) { failed_=true; return; }
            Trace2DMemoryDeltaHeader delta{}; delta.Record=h;
            std::memcpy(reinterpret_cast<std::uint8_t*>(&delta)+sizeof(h),payload,sizeof(delta)-sizeof(h));
            push(delta.Region<2?6:1,payload,size); return;
        }
        if (type==Trace2DRecordType::Scanline) {
            if (size!=sizeof(Trace2DScanlinePacket)) { failed_=true; return; }
            Trace2DScanlinePacket packet{}; std::memcpy(&packet,payload,sizeof(packet));
            if (!have_map_ || std::memcmp(last_map_.data(),packet.VRAMCNT,last_map_.size())!=0) {
                std::array<std::uint8_t,16> map{};
                std::memcpy(map.data(),&packet.Frame,4); std::memcpy(map.data()+4,packet.VRAMCNT,9);
                push(2,map.data(),map.size()); std::memcpy(last_map_.data(),packet.VRAMCNT,last_map_.size()); have_map_=true;
            }
            push(7,payload,size); return;
        }
        if (type==Trace2DRecordType::GeometryCommand) { push(3,payload,size); return; }
        if (type==Trace2DRecordType::GeometryRegister) { push(4,payload,size); return; }
        if (type==Trace2DRecordType::GeometryFrame) { push(5,payload,size); return; }
        if (type==Trace2DRecordType::Internal2DLatch) { push(8,payload,size); return; }
        if (type==Trace2DRecordType::ExtendedPaletteMap) { push(9,payload,size); return; }
        skipped_records_++;
    }

    HpsGpuRing& ring_;
    std::vector<std::uint8_t> pending_;
    std::array<std::uint8_t,9> last_map_{};
    bool have_map_=false,failed_=false;
    std::uint64_t input_records_=0,output_records_=0,skipped_records_=0;
};
}

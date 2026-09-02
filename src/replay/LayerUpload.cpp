#include "replay/LayerRecord.h"
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {
constexpr std::uint32_t kDdrPhysicalBase=0x30000000;
constexpr std::size_t kMaximumBytes=64u*1024u*1024u;
constexpr std::size_t kPublishedMapBytes=3u*nds4mister::kLayerSlotBytes;

bool validPublication(const nds4mister::LayerPublication& h) {
    return h.magic==nds4mister::kLayerPublicationMagic&&h.abi==nds4mister::kLayerPublicationAbi&&
        h.headerBytes==sizeof(h)&&h.generation==h.generationCheck&&!(h.generation&1)&&
        h.activeSlot<2&&h.frameBytes==nds4mister::kLayerFrameBytes&&
        h.recordBytes==sizeof(nds4mister::LayerRecord)&&h.recordCount==nds4mister::kLayerFrameRecords;
}
}

int main(int argc,char** argv) try {
    bool checkOnly=false,publish=false;std::string path;
    for(int i=1;i<argc;i++) {
        if(std::string(argv[i])=="--check")checkOnly=true;
        else if(std::string(argv[i])=="--publish")publish=true;
        else if(path.empty())path=argv[i];
        else throw std::runtime_error("usage: nds_layer_upload [--check] [--publish] records.bin");
    }
    if(path.empty())throw std::runtime_error("usage: nds_layer_upload [--check] [--publish] records.bin");
    std::ifstream input(path,std::ios::binary|std::ios::ate);
    if(!input)throw std::runtime_error("cannot open "+path);
    const auto end=input.tellg();
    if(end<=0||static_cast<std::uint64_t>(end)>kMaximumBytes||static_cast<std::uint64_t>(end)%sizeof(nds4mister::LayerRecord))
        throw std::runtime_error("record file must be a non-empty multiple of 40 bytes and at most 64 MiB");
    std::vector<std::byte> data(static_cast<std::size_t>(end));input.seekg(0);input.read(reinterpret_cast<char*>(data.data()),data.size());
    if(!input)throw std::runtime_error("short read from "+path);
    std::cout<<"records: "<<data.size()/sizeof(nds4mister::LayerRecord)<<"\nbytes: "<<data.size()<<"\n";
    if(publish&&data.size()!=nds4mister::kLayerFrameBytes)
        throw std::runtime_error("published frame must contain exactly 512x192 records");
    if(checkOnly){std::cout<<"layout: valid\n";return 0;}
    const int fd=open("/dev/mem",O_RDWR|O_SYNC|O_CLOEXEC);
    if(fd<0)throw std::runtime_error(std::string("open /dev/mem: ")+std::strerror(errno));
    const std::size_t mapBytes=publish?kPublishedMapBytes:data.size();
    void* map=mmap(nullptr,mapBytes,PROT_READ|PROT_WRITE,MAP_SHARED,fd,kDdrPhysicalBase);
    if(map==MAP_FAILED){const auto e=errno;close(fd);throw std::runtime_error(std::string("mmap DDR: ")+std::strerror(e));}
    if(!publish) {
        std::memcpy(map,data.data(),data.size());__sync_synchronize();
        if(msync(map,data.size(),MS_SYNC))std::cerr<<"warning: msync: "<<std::strerror(errno)<<"\n";
    } else {
        auto* header=static_cast<nds4mister::LayerPublication*>(map);
        nds4mister::LayerPublication previous{};std::memcpy(&previous,header,sizeof(previous));
        const bool hadPrevious=validPublication(previous);
        const std::uint32_t slot=hadPrevious?(previous.activeSlot^1u):0u;
        const std::uint64_t stable=hadPrevious?(previous.generation+2u):2u;
        const std::uint64_t sequence=hadPrevious?(previous.frameSequence+1u):0u;
        nds4mister::LayerPublication next{nds4mister::kLayerPublicationMagic,
            nds4mister::kLayerPublicationAbi,sizeof(nds4mister::LayerPublication),stable|1u,
            slot,nds4mister::kLayerFrameBytes,sizeof(nds4mister::LayerRecord),
            nds4mister::kLayerFrameRecords,sequence,stable|1u,0};
        std::memcpy(header,&next,sizeof(next));__sync_synchronize();
        if(msync(map,sizeof(next),MS_SYNC))std::cerr<<"warning: header msync: "<<std::strerror(errno)<<"\n";
        auto* slotBase=static_cast<std::byte*>(map)+nds4mister::kLayerSlotBytes*(slot+1u);
        std::memcpy(slotBase,data.data(),data.size());__sync_synchronize();
        if(msync(slotBase,data.size(),MS_SYNC))std::cerr<<"warning: slot msync: "<<std::strerror(errno)<<"\n";
        next.generation=stable;next.generationCheck=stable;
        std::memcpy(header,&next,sizeof(next));__sync_synchronize();
        if(msync(map,sizeof(next),MS_SYNC))std::cerr<<"warning: publish msync: "<<std::strerror(errno)<<"\n";
        std::cout<<"slot: "<<slot<<"\nframe_sequence: "<<sequence<<"\ngeneration: "<<stable<<"\n";
    }
    munmap(map,mapBytes);close(fd);
    std::cout<<"ddr_physical_base: 0x"<<std::hex<<kDdrPhysicalBase<<"\npublish: complete\n";
    return 0;
} catch(const std::exception& error) {
    std::cerr<<"nds_layer_upload: "<<error.what()<<"\n";return 1;
}

#include "melonds/MelonDsBackend.h"
#include "replay/LayerRecord.h"
#include <array>
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include "GPU3D.h"
#include <condition_variable>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
#if defined(__linux__)
#include <linux/input.h>
#endif

namespace {
constexpr off_t kDdrPhysicalBase=0x30000000;
constexpr std::size_t kMapBytes=3u*nds4mister::kLayerSlotBytes;

class EvdevInput {
public:
    EvdevInput() {
#if defined(__linux__)
        const char* path=std::getenv("NDS4MISTER_INPUT");
        fd_=open(path?path:"/dev/input/event2",O_RDONLY|O_NONBLOCK|O_CLOEXEC);
#endif
    }
    ~EvdevInput(){if(fd_>=0)close(fd_);}
    std::uint32_t poll(){
#if defined(__linux__)
        input_event event{};
        while(fd_>=0&&read(fd_,&event,sizeof(event))==sizeof(event)){
            if(event.type==EV_KEY)set(event.code,event.value!=0);
            else if(event.type==EV_ABS)setAxis(event.code,event.value);
        }
#endif
        return mask_;
    }
private:
    void button(unsigned bit,bool pressed){if(pressed)mask_&=~(1u<<bit);else mask_|=1u<<bit;}
    void set(unsigned code,bool pressed){
#if defined(__linux__)
        switch(code){
        case KEY_X:case BTN_EAST:button(0,pressed);break;
        case KEY_Z:case BTN_SOUTH:button(1,pressed);break;
        case KEY_RIGHTSHIFT:case BTN_SELECT:button(2,pressed);break;
        case KEY_ENTER:case BTN_START:button(3,pressed);break;
        case KEY_RIGHT:case BTN_DPAD_RIGHT:button(4,pressed);break;
        case KEY_LEFT:case BTN_DPAD_LEFT:button(5,pressed);break;
        case KEY_UP:case BTN_DPAD_UP:button(6,pressed);break;
        case KEY_DOWN:case BTN_DPAD_DOWN:button(7,pressed);break;
        case KEY_S:case BTN_TR:button(8,pressed);break;
        case KEY_A:case BTN_TL:button(9,pressed);break;
        case KEY_W:case BTN_NORTH:button(10,pressed);break;
        case KEY_Q:case BTN_WEST:button(11,pressed);break;
        }
#else
        (void)code;(void)pressed;
#endif
    }
    void setAxis(unsigned code,int value){
#if defined(__linux__)
        if(code==ABS_X||code==ABS_HAT0X){button(4,value>12000);button(5,value< -12000);}
        if(code==ABS_Y||code==ABS_HAT0Y){button(7,value>12000);button(6,value< -12000);}
#else
        (void)code;(void)value;
#endif
    }
    int fd_=-1;std::uint32_t mask_=0xFFFu;
};

class Publisher {
public:
    explicit Publisher(const std::string& memoryPath) {
        if(memoryPath=="none")return;
        const bool devmem=memoryPath=="/dev/mem";
        fd_=open(memoryPath.c_str(),O_RDWR|O_SYNC|O_CLOEXEC|(devmem?0:O_CREAT),0600);
        if(fd_<0)throw std::runtime_error("open "+memoryPath+": "+std::strerror(errno));
        if(!devmem&&ftruncate(fd_,kMapBytes))throw std::runtime_error("resize memory file: "+std::string(std::strerror(errno)));
        map_=mmap(nullptr,kMapBytes,PROT_READ|PROT_WRITE,MAP_SHARED,fd_,devmem?kDdrPhysicalBase:0);
        if(map_==MAP_FAILED)throw std::runtime_error("map publication region: "+std::string(std::strerror(errno)));
        worker_=std::thread([this]{workerLoop();});
    }
    ~Publisher(){
        if(worker_.joinable()){{std::lock_guard<std::mutex> lock(mutex_);stopping_=true;}cv_.notify_all();worker_.join();}
        if(map_!=MAP_FAILED)munmap(map_,kMapBytes);if(fd_>=0)close(fd_);
    }
    void publish(const nds4mister::LayerRecord* records,std::uint64_t sequence,
        const std::int16_t* audio,std::uint32_t audioFrames) {
        if(map_==MAP_FAILED){published_++;return;}
        std::unique_lock<std::mutex> lock(mutex_);cv_.wait(lock,[this]{return !pending_&&!busy_;});
        pendingRecords_=records;pendingSequence_=sequence;pendingAudio_=audio;
        pendingAudioFrames_=audioFrames;pending_=true;published_++;lock.unlock();cv_.notify_all();
    }
    void drain(){if(map_!=MAP_FAILED){std::unique_lock<std::mutex> lock(mutex_);cv_.wait(lock,[this]{return !pending_&&!busy_;});}}
    std::uint64_t count()const{return published_;}
private:
    void workerLoop(){
        for(;;){
            const nds4mister::LayerRecord* records;const std::int16_t* audio;
            std::uint64_t sequence;std::uint32_t audioFrames;
            {std::unique_lock<std::mutex> lock(mutex_);cv_.wait(lock,[this]{return pending_||stopping_;});
             if(!pending_&&stopping_)return;records=pendingRecords_;sequence=pendingSequence_;
             audio=pendingAudio_;audioFrames=pendingAudioFrames_;pending_=false;busy_=true;}
        const std::uint32_t slot=activeSlot_^1u;generation_+=2;
        nds4mister::LayerPublication h{nds4mister::kLayerPublicationMagic,
            nds4mister::kLayerPublicationAbi,sizeof(nds4mister::LayerPublication),generation_|1u,
            slot,nds4mister::kLayerFrameBytes,sizeof(nds4mister::LayerRecord),
            nds4mister::kLayerFrameRecords,sequence,generation_|1u,audioFrames};
        std::memcpy(map_,&h,sizeof(h));__sync_synchronize();
        auto* dst=static_cast<std::byte*>(map_)+nds4mister::kLayerSlotBytes*(slot+1u);
        std::memcpy(dst,records,nds4mister::kLayerFrameBytes);__sync_synchronize();
        if(audioFrames)std::memcpy(dst+nds4mister::kLayerFrameBytes,audio,
            audioFrames*2u*sizeof(std::int16_t));
        __sync_synchronize();
        h.generation=generation_;h.generationCheck=generation_;
        std::memcpy(map_,&h,sizeof(h));__sync_synchronize();activeSlot_=slot;
            {std::lock_guard<std::mutex> lock(mutex_);busy_=false;}cv_.notify_all();
        }
    }
    int fd_=-1;void* map_=MAP_FAILED;std::uint64_t generation_=0,published_=0;std::uint32_t activeSlot_=1;
    std::thread worker_;std::mutex mutex_;std::condition_variable cv_;
    const nds4mister::LayerRecord* pendingRecords_=nullptr;std::uint64_t pendingSequence_=0;
    const std::int16_t* pendingAudio_=nullptr;std::uint32_t pendingAudioFrames_=0;
    bool pending_=false,busy_=false,stopping_=false;
};

struct Capture {
    Publisher& publisher;
    std::array<std::vector<nds4mister::LayerRecord>,2> records{
        std::vector<nds4mister::LayerRecord>(512*192),std::vector<nds4mister::LayerRecord>(512*192)};
    std::array<std::array<std::int16_t,2048>,2> audio{};
    unsigned recordIndex=0;
    std::array<bool,384> lines{};
    std::array<bool,384> fallback{};
    std::array<std::uint8_t,384> physicalScreen{};
    bool incomplete=false;
    bool frameReady=false;
    std::uint64_t frameSequence=0;
    double recordSeconds=0.0,publishSeconds=0.0;
    explicit Capture(Publisher& p):publisher(p){
        for(auto& buffer:records)for(unsigned line=0;line<192;line++)
            for(unsigned screen=0;screen<2;screen++)for(unsigned x=0;x<256;x++){
                auto& out=buffer[line*512+screen*256+x];out={};
                out.setTag(static_cast<std::uint16_t>(screen*256+x),line);
            }
    }
    static void receive(melonDS::u32 frame,melonDS::u16 line,melonDS::u8 engine,
        bool screenSwap,const melonDS::u32* top,const melonDS::u32* second,
        const melonDS::u8* windowMask,melonDS::u16 blendCnt,melonDS::u8 eva,
        melonDS::u8 evb,melonDS::u8 evy,melonDS::u8 displayMode,
        melonDS::u16 masterBrightness,void* userdata) {
        auto& self=*static_cast<Capture*>(userdata);if(line>=192||engine>=2)return;
        const auto recordStart=std::chrono::steady_clock::now();
        const unsigned state=line*2+engine;
        self.lines[state]=true;
        const unsigned screen=engine^(screenSwap?0u:1u);
        self.physicalScreen[state]=static_cast<std::uint8_t>(screen);
        self.fallback[state]=displayMode!=1||((masterBrightness>>14)&3)!=0;
        for(unsigned x=0;x<256;x++){
            auto& out=self.records[self.recordIndex][line*512+screen*256+x];
            out.pixels[0]=top[x];
            out.pixels[1]=second[x];
            out.ranks[0]=0x10;
            out.valid=0x03;
            out.blendCnt=blendCnt;
            out.eva=eva;
            out.evb=evb;
            out.evy=evy;
            out.flags=(windowMask[x]&0x20)?1u:0u;
        }
        self.recordSeconds+=std::chrono::duration<double>(std::chrono::steady_clock::now()-recordStart).count();
    }
    void fillFinal(unsigned line,unsigned screen,const melonDS::u32* pixels) {
        for(unsigned x=0;x<256;x++) {
            auto& out=records[recordIndex][line*512+screen*256+x];
            out={};out.pixels[0]=pixels[x]&0x00ffffff;out.valid=1;
            out.setTag(static_cast<std::uint16_t>(screen*256+x),line);
        }
    }
    static void receiveOutput(melonDS::u32 frame,melonDS::u16 line,
        const melonDS::u32* top,const melonDS::u32* bottom,void* userdata) {
        auto& self=*static_cast<Capture*>(userdata);if(line>=192)return;
        const auto recordStart=std::chrono::steady_clock::now();
        const unsigned a=line*2,b=a+1;
        if(!self.lines[a]||!self.lines[b]) {
            self.fillFinal(line,0,top);self.fillFinal(line,1,bottom);
            self.lines[a]=self.lines[b]=true;
        } else {
            if(self.fallback[a]) {
                const unsigned screen=self.physicalScreen[a];
                self.fillFinal(line,screen,screen?bottom:top);
            }
            if(self.fallback[b]) {
                const unsigned screen=self.physicalScreen[b];
                self.fillFinal(line,screen,screen?bottom:top);
            }
        }
        self.recordSeconds+=std::chrono::duration<double>(
            std::chrono::steady_clock::now()-recordStart).count();
        if(line==191) {
            for(bool complete:self.lines)if(!complete)self.incomplete=true;
            if(self.frameReady)self.incomplete=true;
            self.frameReady=true;self.frameSequence=frame;
            self.lines.fill(false);self.fallback.fill(false);
        }
    }
    void publishFrame(int audioFrames) {
        if(!frameReady)return;
        const auto publishStart=std::chrono::steady_clock::now();
        publisher.publish(records[recordIndex].data(),frameSequence,
            audio[recordIndex].data(),audioFrames>0?static_cast<std::uint32_t>(audioFrames):0u);
        recordIndex^=1u;frameReady=false;
        publishSeconds+=std::chrono::duration<double>(
            std::chrono::steady_clock::now()-publishStart).count();
    }
};
}

int main(int argc,char** argv) try {
    if(argc<2||argc>4){std::cerr<<"usage: nds_live_layer_publish rom [frames, 0=forever] [memory-file|none]\n";return 2;}
    const std::uint64_t limit=argc>=3?std::strtoull(argv[2],nullptr,10):0;
    const std::string memory=argc==4?argv[3]:"/dev/mem";
    Publisher publisher(memory);Capture capture{publisher};EvdevInput input;nds4mister::MelonDsBackend backend;std::string error;
    if(!backend.load_rom(argv[1],error))throw std::runtime_error(error);
    backend.set_composite_line_sink(&Capture::receive,&capture);nds4mister::FrameTimings timings{};
    backend.set_output_line_sink(&Capture::receiveOutput,&capture);
    const char* bypassEnv=std::getenv("NDS4MISTER_COMPOSITE_BYPASS");
    const bool bypass=!bypassEnv||std::strcmp(bypassEnv,"0")!=0;
    melonDS::NDS4MiSTer::SetCompositeLineBypass(bypass);
    const auto start=std::chrono::steady_clock::now();std::uint64_t frames=0;
    while(!limit||frames<limit){
        backend.set_key_mask(input.poll());
        if(!backend.run_frame(timings,error))throw std::runtime_error(error);
        if(capture.frameReady)capture.publishFrame(
            backend.read_audio(capture.audio[capture.recordIndex].data(),1024));
        frames++;
    }
    melonDS::NDS4MiSTer::SetCompositeLineBypass(false);
    backend.set_composite_line_sink(nullptr,nullptr);
    backend.set_output_line_sink(nullptr,nullptr);
    publisher.drain();if(capture.incomplete)throw std::runtime_error("incomplete output frame");
    const double seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
    std::cout<<"frames: "<<frames<<"\npublished: "<<publisher.count()<<"\nseconds: "<<seconds
             <<"\neffective_fps: "<<(seconds?frames/seconds:0)
             <<"\ncomposite_bypass: "<<(bypass?"enabled":"disabled")
             <<"\nrecord_seconds: "<<capture.recordSeconds
             <<"\npublish_seconds: "<<capture.publishSeconds
             <<"\nother_seconds: "<<(seconds-capture.recordSeconds-capture.publishSeconds)<<"\n";
    std::cout<<"GXCTRL invalid="<<melonDS::NDS4MiSTerGXInvalidCmd<<" executed="<<melonDS::NDS4MiSTerGXExecuted<<" clip_zero_den="<<melonDS::NDS4MiSTerClipZeroDen<<" clip_interp="<<melonDS::NDS4MiSTerClipInterp<<"\n";
} catch(const std::exception& e){std::cerr<<"nds_live_layer_publish: "<<e.what()<<"\n";return 1;}

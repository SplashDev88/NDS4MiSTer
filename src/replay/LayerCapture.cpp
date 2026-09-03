#include "melonds/MelonDsBackend.h"
#include "replay/LayerRecord.h"
#include <array>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace {
struct Capture {
    struct ModeTransition {
        std::uint32_t frame{};
        std::uint16_t line{};
        std::uint8_t engine{};
        std::uint8_t mode{};
        bool screenSwap{};
    };
    std::uint32_t target{};
    std::vector<nds4mister::LayerRecord> records=std::vector<nds4mister::LayerRecord>(512*192);
    std::array<bool,384> lines{};
    std::array<bool,384> fallback{};
    std::array<std::uint8_t,384> physicalScreen{};
    std::array<std::array<std::uint32_t,4>,2> displayModes{};
    std::array<std::array<std::uint32_t,2>,2> screenSwapCounts{};
    std::array<std::uint8_t,2> lastMode{0xff,0xff};
    std::array<bool,2> lastScreenSwap{};
    std::vector<ModeTransition> modeTransitions{};
    static void receive(melonDS::u32 frame,melonDS::u16 line,melonDS::u8 engine,
        bool screenSwap,const melonDS::u32* top,const melonDS::u32* second,
        const melonDS::u8* windowMask,melonDS::u16 blendCnt,melonDS::u8 eva,
        melonDS::u8 evb,melonDS::u8 evy,melonDS::u8 displayMode,
        melonDS::u16 masterBrightness,void* userdata) {
        auto& self=*static_cast<Capture*>(userdata);
        if(line>=192||engine>=2)return;
        const auto mode=static_cast<std::uint8_t>(displayMode&3);
        if(self.lastMode[engine]!=mode||
           self.lastScreenSwap[engine]!=screenSwap) {
            self.modeTransitions.push_back({frame,line,engine,mode,screenSwap});
            self.lastMode[engine]=mode;
            self.lastScreenSwap[engine]=screenSwap;
        }
        if(frame!=self.target)return;
        const unsigned state=line*2+engine;
        self.lines[state]=true;
        ++self.displayModes[engine][mode];
        ++self.screenSwapCounts[engine][screenSwap?1:0];
        const unsigned screen=engine^(screenSwap?0u:1u);
        self.physicalScreen[state]=static_cast<std::uint8_t>(screen);
        self.fallback[state]=displayMode!=1||((masterBrightness>>14)&3)!=0;
        for(unsigned x=0;x<256;x++) {
            auto& out=self.records[line*512+screen*256+x];
            out={};
            out.pixels[0]=top[x];
            out.pixels[1]=second[x];
            out.ranks[0]=0x10;
            out.valid=0x03;
            out.blendCnt=blendCnt;
            out.eva=eva;
            out.evb=evb;
            out.evy=evy;
            out.flags=(windowMask[x]&0x20)?1u:0u;
            out.setTag(static_cast<std::uint16_t>(screen*256+x),line);
        }
    }
    void fillFinal(unsigned line,unsigned screen,const melonDS::u32* pixels) {
        for(unsigned x=0;x<256;x++) {
            auto& out=records[line*512+screen*256+x];
            out={};out.pixels[0]=pixels[x]&0x00ffffff;out.valid=1;
            out.setTag(static_cast<std::uint16_t>(screen*256+x),line);
        }
    }
    static void receiveOutput(melonDS::u32 frame,melonDS::u16 line,
        const melonDS::u32* top,const melonDS::u32* bottom,void* userdata) {
        auto& self=*static_cast<Capture*>(userdata);
        if(frame!=self.target||line>=192)return;
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
    }
};

bool fallbackSelfTest() {
    Capture capture;capture.target=7;
    std::array<melonDS::u32,256> engine0Top{},engine0Second{};
    std::array<melonDS::u32,256> engine1Top{},engine1Second{};
    std::array<melonDS::u32,256> physicalTop{},physicalBottom{};
    std::array<melonDS::u8,256> window{};
    window.fill(0xff);
    engine0Top.fill(0x00112233);engine0Second.fill(0x00445566);
    engine1Top.fill(0x00010203);engine1Second.fill(0x00040506);
    physicalTop.fill(0x000a0b0c);physicalBottom.fill(0x000d0e0f);

    // With screen swap clear, engine A maps to physical bottom and engine B
    // maps to physical top. VRAM display must replace only engine A's record.
    Capture::receive(7,0,0,false,engine0Top.data(),engine0Second.data(),
        window.data(),0,0,0,0,2,0,&capture);
    Capture::receive(7,0,1,false,engine1Top.data(),engine1Second.data(),
        window.data(),0,0,0,0,1,0,&capture);
    Capture::receiveOutput(7,0,physicalTop.data(),physicalBottom.data(),&capture);
    const auto& regular=capture.records[0];
    const auto& vram=capture.records[256];
    if(regular.pixels[0]!=engine1Top[0]||regular.valid!=3||
       vram.pixels[0]!=(physicalBottom[0]&0x00ffffff)||vram.valid!=1)return false;

    // No pre-composite callback models forced blank/disabled engines. Both
    // physical screens must still receive authoritative final pixels.
    Capture::receiveOutput(7,1,physicalTop.data(),physicalBottom.data(),&capture);
    if(capture.records[512].pixels[0]!=(physicalTop[0]&0x00ffffff)||
       capture.records[768].pixels[0]!=(physicalBottom[0]&0x00ffffff)||
       capture.records[512].valid!=1||capture.records[768].valid!=1)return false;

    // A regular engine under master-brightness mode must use final output,
    // while the other physical screen remains pre-composite.
    Capture::receive(7,2,0,true,engine0Top.data(),engine0Second.data(),
        window.data(),0,0,0,0,1,0x4001,&capture);
    Capture::receive(7,2,1,true,engine1Top.data(),engine1Second.data(),
        window.data(),0,0,0,0,1,0,&capture);
    Capture::receiveOutput(7,2,physicalTop.data(),physicalBottom.data(),&capture);
    if(capture.records[1024].pixels[0]!=(physicalTop[0]&0x00ffffff)||
       capture.records[1280].pixels[0]!=engine1Top[0])return false;
    return true;
}
}

int main(int argc,char** argv) {
    if(argc==2&&std::string(argv[1])=="--self-test-fallback"){
        if(!fallbackSelfTest()){std::cerr<<"layer fallback self-test failed\n";return 1;}
        std::cout<<"PASS: layer fallback covers display modes, missing engines, routing, and brightness\n";
        return 0;
    }
    if(argc<3||argc>4){std::cerr<<"usage: nds_layer_capture rom output.bin [frames]\n";return 2;}
    const std::uint32_t frames=argc==4?static_cast<std::uint32_t>(std::strtoul(argv[3],nullptr,10)):600;
    if(!frames)return 2;
    nds4mister::MelonDsBackend backend;std::string error;
    if(!backend.load_rom(argv[1],error)){std::cerr<<error<<"\n";return 3;}
    Capture capture;capture.target=frames-1;
    backend.set_composite_line_sink(&Capture::receive,&capture);
    backend.set_output_line_sink(&Capture::receiveOutput,&capture);
    nds4mister::FrameTimings timings{};const auto start=std::chrono::steady_clock::now();
    for(std::uint32_t i=0;i<frames;i++)if(!backend.run_frame(timings,error)){std::cerr<<error<<"\n";return 4;}
    backend.set_composite_line_sink(nullptr,nullptr);
    backend.set_output_line_sink(nullptr,nullptr);
    unsigned lines=0;for(bool value:capture.lines)lines+=value;
    if(lines!=384){std::cerr<<"captured only "<<lines<<" of 384 engine lines for frame "<<capture.target<<"\n";return 5;}
    std::ofstream output(argv[2],std::ios::binary|std::ios::trunc);
    output.write(reinterpret_cast<const char*>(capture.records.data()),static_cast<std::streamsize>(capture.records.size()*sizeof(capture.records[0])));
    if(!output){std::cerr<<"failed writing "<<argv[2]<<"\n";return 6;}
    const double seconds=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
    std::cout<<"NDS layer capture\nframe: "<<capture.target<<"\nengine_lines: "<<lines
             <<"\nrecords: "<<capture.records.size()<<"\nbytes: "<<capture.records.size()*sizeof(capture.records[0])
             <<"\nengine_a_modes: "<<capture.displayModes[0][0]<<','<<capture.displayModes[0][1]<<','
             <<capture.displayModes[0][2]<<','<<capture.displayModes[0][3]
             <<"\nengine_b_modes: "<<capture.displayModes[1][0]<<','<<capture.displayModes[1][1]<<','
             <<capture.displayModes[1][2]<<','<<capture.displayModes[1][3]
             <<"\nengine_a_swap: "<<capture.screenSwapCounts[0][0]<<','<<capture.screenSwapCounts[0][1]
             <<"\nengine_b_swap: "<<capture.screenSwapCounts[1][0]<<','<<capture.screenSwapCounts[1][1]
             <<"\nmode_transitions:";
    for(const auto& transition:capture.modeTransitions)
        std::cout<<' '<<static_cast<unsigned>(transition.engine)<<':'
                 <<static_cast<unsigned>(transition.mode)<<':'
                 <<transition.frame<<':'<<transition.line<<':'
                 <<(transition.screenSwap?1:0);
    std::cout
             <<"\nseconds: "<<seconds<<"\neffective_fps: "<<frames/seconds<<"\n";
}

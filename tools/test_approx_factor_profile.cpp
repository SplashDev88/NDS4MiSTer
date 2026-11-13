// SPDX-License-Identifier: GPL-3.0-or-later
#define main original_raster_benchmark_main
#include "benchmark_raster_batch.cpp"
#undef main
#include "GPU_Soft.h"
#include "GPU3D_Soft.h"
int main()try {
    unsigned transitions=0;
    for(const char* setting : {static_cast<const char*>(nullptr),"auto","0","1","invalid"}) {
        if(setting)setenv("NDS4MISTER_APPROX_FACTORS",setting,1);else unsetenv("NDS4MISTER_APPROX_FACTORS");
        auto n=machine(true);auto& g=n->GPU.GPU3D;
        require(!g.ApproximateFactorsEnabled(),"new session inherited approximate factors");
        auto& s=*static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(n->GetRenderer()).Rend3D.get());
        for(bool profile : {false,true,false,true,false}) {
            g.SetApproximateFactorsEnabled(profile);frame(*n,0);render(*n);
            const bool expected=!setting || !std::strcmp(setting,"auto") ? profile : !std::strcmp(setting,"1");
            require(s.ApproximateFactors==expected,"approximate profile/override transition mismatch");
            ++transitions;
        }
    }
    unsetenv("NDS4MISTER_APPROX_FACTORS");
    unsigned whiteTransitions=0;
    for(const char* setting : {static_cast<const char*>(nullptr),"auto","0","1","invalid"}) {
        if(setting)setenv("NDS4MISTER_NEUTRAL_WHITE",setting,1);else unsetenv("NDS4MISTER_NEUTRAL_WHITE");
        auto n=machine(true);auto& g=n->GPU.GPU3D;
        require(!g.ApproximateFactorsEnabled(),"new session inherited white cartridge policy");
        auto& s=*static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(n->GetRenderer()).Rend3D.get());
        for(bool profile : {false,true,false,true,false}) for(bool aa : {false,true}) {
            g.SetApproximateFactorsEnabled(profile);frame(*n,0);
            if(aa)g.RenderDispCnt|=16;else g.RenderDispCnt&=~16u;
            render(*n);
            const bool expected=!setting || !std::strcmp(setting,"auto") ? profile && !aa : !std::strcmp(setting,"1");
            require(s.NeutralWhite==expected,"white cartridge/AA/override transition mismatch");
            ++whiteTransitions;
        }
    }
    unsetenv("NDS4MISTER_NEUTRAL_WHITE");
    std::printf("NEUTRAL_WHITE_PROFILE_PASS transitions=%u fresh_session_default_off=1\n",whiteTransitions);
    std::printf("APPROX_PROFILE_TRANSITION_PASS transitions=%u fresh_session_default_off=1\n",transitions);
    return 0;
}catch(const std::exception& e){std::fprintf(stderr,"FAIL %s\n",e.what());return 1;}

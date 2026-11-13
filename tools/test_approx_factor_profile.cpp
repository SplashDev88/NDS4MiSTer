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
    std::printf("APPROX_PROFILE_TRANSITION_PASS transitions=%u fresh_session_default_off=1\n",transitions);
    return 0;
}catch(const std::exception& e){std::fprintf(stderr,"FAIL %s\n",e.what());return 1;}

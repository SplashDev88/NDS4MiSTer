// Exercise the interaction of the exact gray path and the new 64x48 mode.
#define NDS_GRAY_ORACLE_LIBRARY
#include "test_gray_rectangle_raster.cpp"
int main() try {
    unsigned cases=0, sampled=0, grayPaths=0;
    for (unsigned scheduler=0;scheduler<2;++scheduler)
    for (unsigned scenario=0;scenario<256;++scenario) {
        auto ref=machine(false),test=machine(true);
        for (NDS* n:{ref.get(),test.get()}) {
            auto& r=*static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(n->GetRenderer()).Rend3D.get());
            r.StopRenderThread();
            r.DualCoreRaster=r.RasterBandQueue=r.WeightedRasterBands=scheduler!=0;
            r.AdaptiveRasterSplit=r.ParallelFinalPass=r.RasterBandQueueTestDelayWorker=scheduler!=0;
            r.TinyRequested=true;r.SetFullFrameCompletion(true);
            if(r.DualCoreRaster)r.ParallelPolygonList=std::make_unique<SoftRenderer3D::RendererPolygon[]>(r.MaxRendererPolygons);
            r.SetupRenderThread();grayFrame(*n,scenario);
        }
        render(*ref);render(*test);
        auto& a=ref->GetRenderer();auto& b=test->GetRenderer();
        for(unsigned y=0;y<192;++y)require(!std::memcmp(a.Get3DScanline(y),b.Get3DScanline(y),1024),"tiny gray visible mismatch");
        u64 ha[3]{},hb[3]{};
        require(a.Get3DNativeBufferHashes(ha)&&b.Get3DNativeBufferHashes(hb),"tiny gray hashes unavailable");
        require(!std::memcmp(ha,hb,sizeof(ha)),"tiny gray color/depth/attribute mismatch");
        const auto& r=*static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(b).Rend3D.get());
        sampled+=r.Tiny;
        if(r.Tiny)for(int i=0;i<r.CurrentPolygonCount;++i)grayPaths+=r.PolygonList[i].PixelState.GrayRectangle;
        ++cases;
    }
    require(sampled&&grayPaths,"tiny gray fixture did not admit the combined path");
    std::printf("PASS tiny gray interaction: %u full-buffer cases; sampled=%u gray_paths=%u\n",cases,sampled,grayPaths);
    return 0;
} catch(const std::exception& e) {std::fprintf(stderr,"FAIL: %s\n",e.what());return 1;}

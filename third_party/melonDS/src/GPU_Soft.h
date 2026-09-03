/*
    Copyright 2016-2026 melonDS team

    This file is part of melonDS.

    melonDS is free software: you can redistribute it and/or modify it under
    the terms of the GNU General Public License as published by the Free
    Software Foundation, either version 3 of the License, or (at your option)
    any later version.

    melonDS is distributed in the hope that it will be useful, but WITHOUT ANY
    WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
    FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along
    with melonDS. If not, see http://www.gnu.org/licenses/.
*/

#ifndef GPU_SOFT_H
#define GPU_SOFT_H

#include "GPU.h"
#include "GPU2D_Soft.h"
#include "GPU3D_Soft.h"

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>

namespace melonDS
{

class SoftRenderer : public Renderer
{
public:
    explicit SoftRenderer(melonDS::NDS& nds);
    ~SoftRenderer() override;
    bool Init() override { return true; }
    void Reset() override;
    void Stop() override;

    void PreSavestate() override;
    void PostSavestate() override;

    void SetRenderSettings(RendererSettings& settings) override;

    void DrawScanline(u32 line) override;
    void DrawSprites(u32 line) override;
    void SetExternalLineCacheReuse(u32 line, bool engineA,
                                   bool engineB) override;
    bool GetExternalLineCacheResult(bool& engineA, bool& engineB) override
    {
        engineA = LastExternalLineCacheReuse[0];
        engineB = LastExternalLineCacheReuse[1];
        return true;
    }
    ExternalRendererStageProfile GetExternalRendererStageProfile() const override
    {
        return StageProfile;
    }

    void VBlank() override {};
    void VBlankEnd() override {};

    void AllocCapture(u32 bank, u32 start, u32 len) override {};
    void SyncVRAMCapture(u32 bank, u32 start, u32 len, bool complete) override {};

    bool GetFramebuffers(void** top, void** bottom) override;
    u32* Get3DScanline(u32 line) override { return Rend3D->GetLine(line); }
    bool Is3DFrameIdentical() const override
    {
        return static_cast<const SoftRenderer3D*>(Rend3D.get())
            ->IsFrameIdentical();
    }
    bool Request3DRenderingCancellation() override
    {
        return static_cast<SoftRenderer3D*>(Rend3D.get())
            ->RequestFrameCancellation();
    }
    bool Was3DRenderingCanceled() const override
    {
        return static_cast<const SoftRenderer3D*>(Rend3D.get())
            ->WasFrameCanceled();
    }
    bool Get3DNativeBufferHashes(u64 hashes[3]) const override
    {
        static_cast<const SoftRenderer3D*>(Rend3D.get())
            ->GetNativeBufferHashes(hashes);
        return true;
    }
    bool GetRenderedScanlines(u32 line, u32** top, u32** bottom) override
    {
        if (line >= 192) return false;
        *top = &Framebuffer[BackBuffer][0][line * 256];
        *bottom = &Framebuffer[BackBuffer][1][line * 256];
        return true;
    }
    bool GetOBJBufferHashes(u64 hashes[4]) override
    {
        static_cast<SoftRenderer2D*>(Rend2D_A.get())->GetOBJBufferHashes(hashes[0], hashes[1]);
        static_cast<SoftRenderer2D*>(Rend2D_B.get())->GetOBJBufferHashes(hashes[2], hashes[3]);
        return true;
    }

private:
    friend class SoftRenderer2D;
    friend class SoftRenderer3D;

    u32* Framebuffer[2][2];
    bool PackedOutput = false;
    bool LineCache = false;
    bool EngineBOnly = false;
    bool StageProfileEnabled = false;
    ExternalRendererStageProfile StageProfile {};

    struct EngineLineState
    {
        u64 MemoryRevision = 0;
        u32 DispCnt = 0;
        u32 DispCntLatch[3] {};
        u16 BGCnt[4] {};
        u16 BGXPos[4] {};
        u16 BGYPos[4] {};
        s32 BGXRef[2] {};
        s32 BGYRef[2] {};
        s32 BGXRefInternal[2] {};
        s32 BGYRefInternal[2] {};
        s32 BGXRefReload[2] {};
        s32 BGYRefReload[2] {};
        s16 BGRotA[2] {};
        s16 BGRotB[2] {};
        s16 BGRotC[2] {};
        s16 BGRotD[2] {};
        u16 BGMap[32] {};
        u16 OBJMap[16] {};
        u16 BGExtMap[4] {};
        u16 OBJExtMap = 0;
        u16 LCDCMap = 0;
        u32 BGMosaicLine = 0;
        u32 OBJMosaicLine = 0;
        u16 BlendCnt = 0;
        u16 BlendAlpha = 0;
        u16 MasterBrightness = 0;
        u8 Win0Coords[4] {};
        u8 Win1Coords[4] {};
        u8 WinCnt[4] {};
        u8 BGMosaicSize[2] {};
        u8 OBJMosaicSize[2] {};
        u8 LayerEnable = 0;
        u8 OBJEnable = 0;
        u8 ForcedBlank = 0;
        u8 Win0Active = 0;
        u8 Win1Active = 0;
        u8 BGMosaicY = 0;
        u8 BGMosaicYMax = 0;
        u8 OBJMosaicY = 0;
        u8 EVA = 0;
        u8 EVB = 0;
        u8 EVY = 0;
        u8 BGMosaicLatch = 0;
        u8 OBJMosaicLatch = 0;
        u8 Enabled = 0;
    };
    EngineLineState LineCacheState[2][192] {};
    bool LineCacheStateValid[2][192] {};

    enum class Parallel2DTask
    {
        None,
        Scanline,
        Sprites,
        Stop,
    };
    bool Parallel2D = false;
    std::atomic<Parallel2DTask> ParallelTask {Parallel2DTask::None};
    u32 ParallelLine = 0;
    u32* ParallelDestination = nullptr;
    std::thread ParallelThread;
    std::mutex ParallelMutex;
    std::condition_variable ParallelCondition;
    std::condition_variable ParallelDone;

    u32* Output3D;
    u32 Prepared3DLine = ~0u;
    EngineLineState PreparedLineState[2] {};
    u32 PreparedLineStateLine = ~0u;
    u32 SpriteCacheLine = ~0u;
    bool SpriteDrawSkipped[2] {};
    alignas(8) u32 Output2D[2][256];
    alignas(8) u32 ExternalLineCache[2][192][256] {};
    bool ExternalLineCacheValid[2][192] {};
    alignas(8) u32 ExternalLineCache3D[192][256] {};
    bool ExternalLineCache3DValid[192] {};
    bool ExternalLineCacheReuse[2] {};
    bool LastExternalLineCacheReuse[2] {};
    u32 ExternalLineCacheLine = ~0u;

    void DrawScanlineA(u32 line, u32* dst);
    void DrawScanlineB(u32 line, u32* dst);
    EngineLineState CaptureLineState(u32 engine) const;

    void SetParallel2D(bool enabled);
    void Parallel2DThreadFunc();
    void StartParallel2DTask(Parallel2DTask task, u32 line, u32* dst = nullptr);
    void WaitParallel2DTask();

    void DoCapture(u32 line);

    void ApplyMasterBrightness(u16 regval, u32* dst);
    void ExpandColor(u32* dst);
};

}

#endif // GPU_SOFT_H

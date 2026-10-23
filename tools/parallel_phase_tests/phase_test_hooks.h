#pragma once
#include <array>
namespace melonDS { class SoftRenderer3D; }
// Job indices mirror the private renderer enum: Raster, Clear, FinalPass.
struct C58HookCounts {
    std::array<unsigned, 3> wakes{};
    std::array<unsigned, 3> done{};
    unsigned frames = 0;
    unsigned primaryStarts = 0;
};
void C58Track(melonDS::SoftRenderer3D* renderer);
void C58Hold(int job, bool primaryAfterPost);
bool C58WaitHeld();
bool C58WaitJobDone(int job, unsigned count);
bool C58WaitPrimaryStarts(unsigned count);
void C58Release();
C58HookCounts C58Counts();

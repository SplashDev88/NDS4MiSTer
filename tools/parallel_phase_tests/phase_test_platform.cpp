// Test-only deterministic holds around the existing semaphore protocol.
#define Semaphore_Wait C58OriginalSemaphoreWait
#define Semaphore_Post C58OriginalSemaphorePost
#include "melonds/HeadlessPlatform.cpp"
#undef Semaphore_Wait
#undef Semaphore_Post
#include "GPU_Soft.h"
#include "GPU3D_Soft.h"
#include "phase_test_hooks.h"
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <mutex>

namespace {
std::atomic<melonDS::SoftRenderer3D*> tracked{nullptr};
std::mutex gateMutex;
std::condition_variable gate;
C58HookCounts counters;
int heldJob = -1;
bool holdPrimary = false, arrived = false, released = true;

void holdIfSelected(int job, bool primary)
{
    std::unique_lock<std::mutex> lock(gateMutex);
    if (job != heldJob || primary != holdPrimary || released) return;
    arrived = true;
    gate.notify_all();
    if (!gate.wait_for(lock, std::chrono::seconds(10), [] { return released; }))
        std::abort();
}
}

void C58Track(melonDS::SoftRenderer3D* renderer)
{
    std::lock_guard<std::mutex> lock(gateMutex);
    if (!released) std::abort();
    counters = {};
    heldJob = -1;
    arrived = false;
    tracked.store(renderer, std::memory_order_release);
}

void C58Hold(int job, bool primaryAfterPost)
{
    std::lock_guard<std::mutex> lock(gateMutex);
    if (!released || job < 0 || job > 2) std::abort();
    heldJob = job;
    holdPrimary = primaryAfterPost;
    arrived = false;
    released = false;
}

bool C58WaitHeld()
{
    std::unique_lock<std::mutex> lock(gateMutex);
    return gate.wait_for(lock, std::chrono::seconds(5), [] { return arrived; });
}

bool C58WaitJobDone(int job, unsigned count)
{
    std::unique_lock<std::mutex> lock(gateMutex);
    return gate.wait_for(lock, std::chrono::seconds(5),
        [=] { return counters.done[job] >= count; });
}

bool C58WaitPrimaryStarts(unsigned count)
{
    std::unique_lock<std::mutex> lock(gateMutex);
    return gate.wait_for(lock, std::chrono::seconds(5),
        [=] { return counters.primaryStarts >= count; });
}

void C58Release()
{
    std::lock_guard<std::mutex> lock(gateMutex);
    released = true;
    heldJob = -1;
    gate.notify_all();
}

C58HookCounts C58Counts()
{
    std::lock_guard<std::mutex> lock(gateMutex);
    return counters;
}

namespace melonDS::Platform {
void Semaphore_Wait(Semaphore* semaphore)
{
    C58OriginalSemaphoreWait(semaphore);
    auto* renderer = tracked.load(std::memory_order_acquire);
    if (!renderer || semaphore != renderer->Sema_ParallelRasterStart) return;
    const int job = static_cast<int>(renderer->ParallelJob_.load(std::memory_order_relaxed));
    {
        std::lock_guard<std::mutex> lock(gateMutex);
        ++counters.wakes.at(job);
    }
    holdIfSelected(job, false);
}

void Semaphore_Post(Semaphore* semaphore, int count)
{
    auto* renderer = tracked.load(std::memory_order_acquire);
    const bool start = renderer && semaphore == renderer->Sema_ParallelRasterStart;
    const bool done = renderer && semaphore == renderer->Sema_ParallelRasterDone;
    const bool frame = renderer && semaphore == renderer->Sema_RenderDone;
    const bool primaryStart = renderer && semaphore == renderer->Sema_RenderStart;
    // Read job ownership before releasing Done; the primary can immediately
    // consume it and install the next job after the underlying post.
    const int job = (start || done) ?
        static_cast<int>(renderer->ParallelJob_.load(std::memory_order_relaxed)) : -1;
    if (done || frame || primaryStart)
    {
        std::lock_guard<std::mutex> lock(gateMutex);
        if (done) counters.done.at(job) += count;
        if (frame) counters.frames += count;
        if (primaryStart) counters.primaryStarts += count;
        gate.notify_all();
    }
    C58OriginalSemaphorePost(semaphore, count);
    if (start) holdIfSelected(job, true);
}
}

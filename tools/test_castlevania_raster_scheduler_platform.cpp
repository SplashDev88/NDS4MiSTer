// SPDX-License-Identifier: GPL-3.0-only
// Test-only platform shim: delay a selected worker after its semaphore wakes.
// The production renderer and platform are not modified by this test.
#define Semaphore_Wait C49OriginalSemaphoreWait
#include "melonds/HeadlessPlatform.cpp"
#undef Semaphore_Wait
#include <atomic>
#include <chrono>
#include <thread>

namespace {
std::atomic<melonDS::Platform::Semaphore*> delayedSemaphore{nullptr};
std::atomic<unsigned> delayedWakeups{0};
}

void C49SetDelayedSemaphore(void* semaphore)
{
    delayedSemaphore.store(static_cast<melonDS::Platform::Semaphore*>(semaphore),
        std::memory_order_release);
}

unsigned C49DelayedWakeups()
{
    return delayedWakeups.load(std::memory_order_acquire);
}

namespace melonDS::Platform {
void Semaphore_Wait(Semaphore* semaphore)
{
    C49OriginalSemaphoreWait(semaphore);
    if (semaphore == delayedSemaphore.load(std::memory_order_acquire))
    {
        delayedWakeups.fetch_add(1, std::memory_order_relaxed);
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
}
}

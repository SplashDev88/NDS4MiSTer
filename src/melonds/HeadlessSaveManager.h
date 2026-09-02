#pragma once

#include "melonds/HeadlessSaveCallback.h"

#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace nds4mister {

struct SavePersistenceStats {
    std::uint32_t saveBytes = 0;
    std::uint64_t callbacks = 0;
    std::uint64_t callbackBytes = 0;
    std::uint64_t commits = 0;
    std::uint64_t failures = 0;
    std::uint64_t directorySyncFallbacks = 0;
    bool loadedExisting = false;
    bool dirty = false;
};

class HeadlessSaveManager final {
public:
    static constexpr std::uint32_t kMaximumSaveBytes = 64u * 1024u * 1024u;

    static std::string contentId(const std::uint8_t* data, std::size_t size);
    static std::unique_ptr<HeadlessSaveManager> create(
        const std::string& root, const std::string& contentId,
        std::string& error,
        std::chrono::milliseconds quietDelay = std::chrono::seconds(2),
        std::chrono::milliseconds maximumDelay = std::chrono::seconds(10));

    ~HeadlessSaveManager();

    HeadlessSaveManager(const HeadlessSaveManager&) = delete;
    HeadlessSaveManager& operator=(const HeadlessSaveManager&) = delete;

    HeadlessSaveCallback* callback() noexcept { return &callback_; }

    bool loadExisting(std::unique_ptr<std::uint8_t[]>& data,
        std::uint32_t& length, std::string& error);
    bool initialize(const std::uint8_t* currentData,
        std::uint32_t currentLength, std::uint32_t loadedLength,
        std::string& error);

    bool flush(std::string& error);
    bool shutdown(std::string& error);
    SavePersistenceStats stats() const;

    // Exposed for deterministic lifecycle tests; product telemetry must not
    // print this path because the opaque content identity is private state.
    const std::string& savePathForTest() const noexcept { return savePath_; }

private:
    HeadlessSaveManager(std::string root, std::string contentId,
        std::chrono::milliseconds quietDelay,
        std::chrono::milliseconds maximumDelay);

    bool prepare(std::string& error);
    static void receiveWrite(void* opaque, const std::uint8_t* data,
        std::uint32_t length, std::uint32_t offset,
        std::uint32_t writeLength) noexcept;
    void requestWrite(const std::uint8_t* data, std::uint32_t length,
        std::uint32_t offset, std::uint32_t writeLength);
    void workerMain() noexcept;
    bool commitSnapshot(const std::vector<std::uint8_t>& snapshot,
        bool& directorySyncFallback, std::string& error);
    void stopWorkerNoThrow() noexcept;

    std::string root_;
    std::string contentId_;
    std::string savePath_;
    std::string lockPath_;
    std::string temporaryPrefix_;
    std::chrono::milliseconds quietDelay_;
    std::chrono::milliseconds maximumDelay_;
    int lockFd_ = -1;
    HeadlessSaveCallback callback_{};

    mutable std::mutex mutex_;
    std::condition_variable wake_;
    std::condition_variable completed_;
    std::vector<std::uint8_t> shadow_;
    std::thread worker_;
    bool initialized_ = false;
    bool dirty_ = false;
    bool forceFlush_ = false;
    bool stopRequested_ = false;
    bool stopped_ = false;
    bool flushInProgress_ = false;
    bool lastAttemptSucceeded_ = true;
    bool callbackError_ = false;
    std::uint64_t generation_ = 0;
    std::uint64_t attemptSerial_ = 0;
    std::uint64_t attemptedGeneration_ = 0;
    std::uint64_t committedGeneration_ = 0;
    std::chrono::steady_clock::time_point firstDirty_{};
    std::chrono::steady_clock::time_point lastDirty_{};
    std::string lastError_;
    SavePersistenceStats stats_{};
};

} // namespace nds4mister

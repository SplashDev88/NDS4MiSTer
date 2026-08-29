#include "melonds/HeadlessSaveManager.h"
#include "melonds/HeadlessSaveDurability.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstring>
#include <filesystem>
#include <limits>
#include <stdexcept>
#include <system_error>

#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

namespace nds4mister {
namespace {

constexpr std::array<std::uint32_t, 64> kSha256Constants{{
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
    0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
    0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
    0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
}};

constexpr std::uint32_t rotateRight(std::uint32_t value, unsigned amount)
{
    return (value >> amount) | (value << (32u - amount));
}

class Sha256 {
public:
    void update(const std::uint8_t* data, std::size_t size)
    {
        totalBytes_ += size;
        while (size) {
            const auto count = std::min(size, buffer_.size() - buffered_);
            std::memcpy(buffer_.data() + buffered_, data, count);
            buffered_ += count;
            data += count;
            size -= count;
            if (buffered_ == buffer_.size()) {
                transform(buffer_.data());
                buffered_ = 0;
            }
        }
    }

    std::array<std::uint8_t, 32> finish()
    {
        const std::uint64_t bitLength = totalBytes_ * 8u;
        buffer_[buffered_++] = 0x80u;
        if (buffered_ > 56) {
            std::fill(buffer_.begin() + buffered_, buffer_.end(), 0);
            transform(buffer_.data());
            buffered_ = 0;
        }
        std::fill(buffer_.begin() + buffered_, buffer_.begin() + 56, 0);
        for (unsigned index = 0; index < 8; ++index)
            buffer_[63u - index] = static_cast<std::uint8_t>(
                bitLength >> (index * 8u));
        transform(buffer_.data());

        std::array<std::uint8_t, 32> digest{};
        for (std::size_t index = 0; index < state_.size(); ++index) {
            digest[index * 4u] = static_cast<std::uint8_t>(state_[index] >> 24);
            digest[index * 4u + 1u] =
                static_cast<std::uint8_t>(state_[index] >> 16);
            digest[index * 4u + 2u] =
                static_cast<std::uint8_t>(state_[index] >> 8);
            digest[index * 4u + 3u] = static_cast<std::uint8_t>(state_[index]);
        }
        return digest;
    }

private:
    void transform(const std::uint8_t* block)
    {
        std::array<std::uint32_t, 64> words{};
        for (std::size_t index = 0; index < 16; ++index) {
            words[index] = (static_cast<std::uint32_t>(block[index * 4u]) << 24) |
                (static_cast<std::uint32_t>(block[index * 4u + 1u]) << 16) |
                (static_cast<std::uint32_t>(block[index * 4u + 2u]) << 8) |
                static_cast<std::uint32_t>(block[index * 4u + 3u]);
        }
        for (std::size_t index = 16; index < words.size(); ++index) {
            const auto a = words[index - 15];
            const auto b = words[index - 2];
            const auto s0 = rotateRight(a, 7) ^ rotateRight(a, 18) ^ (a >> 3);
            const auto s1 = rotateRight(b, 17) ^ rotateRight(b, 19) ^ (b >> 10);
            words[index] = words[index - 16] + s0 + words[index - 7] + s1;
        }

        auto a = state_[0];
        auto b = state_[1];
        auto c = state_[2];
        auto d = state_[3];
        auto e = state_[4];
        auto f = state_[5];
        auto g = state_[6];
        auto h = state_[7];
        for (std::size_t index = 0; index < words.size(); ++index) {
            const auto choose = (e & f) ^ (~e & g);
            const auto majority = (a & b) ^ (a & c) ^ (b & c);
            const auto sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^
                rotateRight(a, 22);
            const auto sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^
                rotateRight(e, 25);
            const auto temp1 = h + sum1 + choose + kSha256Constants[index] +
                words[index];
            const auto temp2 = sum0 + majority;
            h = g;
            g = f;
            f = e;
            e = d + temp1;
            d = c;
            c = b;
            b = a;
            a = temp1 + temp2;
        }
        state_[0] += a;
        state_[1] += b;
        state_[2] += c;
        state_[3] += d;
        state_[4] += e;
        state_[5] += f;
        state_[6] += g;
        state_[7] += h;
    }

    std::array<std::uint32_t, 8> state_{{
        0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
        0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u,
    }};
    std::array<std::uint8_t, 64> buffer_{};
    std::size_t buffered_ = 0;
    std::uint64_t totalBytes_ = 0;
};

bool validContentId(const std::string& value)
{
    if (value.size() != 64) return false;
    return std::all_of(value.begin(), value.end(), [](char byte) {
        return (byte >= '0' && byte <= '9') || (byte >= 'a' && byte <= 'f');
    });
}

std::string systemError(const char* operation)
{
    return std::string(operation) + ": " + std::strerror(errno);
}

bool closeChecked(int fd, std::string& error)
{
    if (close(fd) == 0) return true;
    error = systemError("close save file");
    return false;
}

int syncSaveFile(int fd)
{
#if defined(__APPLE__)
    return fsync(fd);
#else
    return fdatasync(fd);
#endif
}

} // namespace

std::string HeadlessSaveManager::contentId(
    const std::uint8_t* data, std::size_t size)
{
    if (!data && size) return {};
    Sha256 hash;
    if (size) hash.update(data, size);
    const auto digest = hash.finish();
    constexpr char hex[] = "0123456789abcdef";
    std::string result(digest.size() * 2u, '0');
    for (std::size_t index = 0; index < digest.size(); ++index) {
        result[index * 2u] = hex[digest[index] >> 4];
        result[index * 2u + 1u] = hex[digest[index] & 0x0fu];
    }
    return result;
}

std::unique_ptr<HeadlessSaveManager> HeadlessSaveManager::create(
    const std::string& root, const std::string& contentId,
    std::string& error, std::chrono::milliseconds quietDelay,
    std::chrono::milliseconds maximumDelay)
{
    if (root.empty() || !validContentId(contentId)) {
        error = "invalid save persistence configuration";
        return nullptr;
    }
    if (quietDelay.count() < 0 || maximumDelay.count() <= 0) {
        error = "invalid save persistence timing";
        return nullptr;
    }
    try {
        auto result = std::unique_ptr<HeadlessSaveManager>(
            new HeadlessSaveManager(root, contentId, quietDelay, maximumDelay));
        if (!result->prepare(error)) return nullptr;
        return result;
    } catch (const std::exception& exception) {
        error = std::string("save persistence setup failed: ") + exception.what();
        return nullptr;
    }
}

HeadlessSaveManager::HeadlessSaveManager(std::string root,
    std::string contentId, std::chrono::milliseconds quietDelay,
    std::chrono::milliseconds maximumDelay)
    : root_(std::move(root)), contentId_(std::move(contentId)),
      quietDelay_(quietDelay), maximumDelay_(maximumDelay)
{
    const std::string base = "sha256-" + contentId_ + ".sav";
    savePath_ = (std::filesystem::path(root_) / base).string();
    lockPath_ = (std::filesystem::path(root_) / ("." + base + ".lock")).string();
    temporaryPrefix_ = "." + base + ".tmp.";
    callback_.write = &HeadlessSaveManager::receiveWrite;
    callback_.opaque = this;
}

bool HeadlessSaveManager::prepare(std::string& error)
{
    std::error_code filesystemError;
    std::filesystem::create_directories(root_, filesystemError);
    if (filesystemError) {
        error = "cannot create save directory: " + filesystemError.message();
        return false;
    }
    if (!std::filesystem::is_directory(root_, filesystemError) ||
        filesystemError) {
        error = "save root is not a directory";
        return false;
    }

    int lockFlags = O_RDWR | O_CREAT | O_CLOEXEC;
#ifdef O_NOFOLLOW
    lockFlags |= O_NOFOLLOW;
#endif
    lockFd_ = open(lockPath_.c_str(), lockFlags, 0600);
    if (lockFd_ < 0) {
        error = systemError("open save lock");
        return false;
    }
    if (flock(lockFd_, LOCK_EX | LOCK_NB) != 0) {
        error = errno == EWOULDBLOCK
            ? "save is already owned by another runner"
            : systemError("lock save");
        return false;
    }

    // A killed writer can leave only its private temporary file behind.  The
    // committed .sav is always authoritative; with the per-ROM lock held it is
    // safe to discard stale temporaries for this exact content identity.
    for (std::filesystem::directory_iterator iterator(root_, filesystemError), end;
         !filesystemError && iterator != end; iterator.increment(filesystemError)) {
        const auto name = iterator->path().filename().string();
        if (name.rfind(temporaryPrefix_, 0) == 0) {
            std::error_code removeError;
            std::filesystem::remove(iterator->path(), removeError);
        }
    }
    if (filesystemError) {
        error = "cannot inspect save directory: " + filesystemError.message();
        return false;
    }
    return true;
}

HeadlessSaveManager::~HeadlessSaveManager()
{
    stopWorkerNoThrow();
    if (lockFd_ >= 0) close(lockFd_);
}

bool HeadlessSaveManager::loadExisting(
    std::unique_ptr<std::uint8_t[]>& data, std::uint32_t& length,
    std::string& error)
{
    data.reset();
    length = 0;
    int flags = O_RDONLY | O_CLOEXEC;
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
    const int fd = open(savePath_.c_str(), flags);
    if (fd < 0) {
        if (errno == ENOENT) return true;
        error = systemError("open existing save");
        return false;
    }

    struct stat status {};
    if (fstat(fd, &status) != 0 || !S_ISREG(status.st_mode) ||
        status.st_size <= 0 ||
        status.st_size > static_cast<off_t>(kMaximumSaveBytes)) {
        error = "existing save has an invalid type or size";
        close(fd);
        return false;
    }

    length = static_cast<std::uint32_t>(status.st_size);
    try {
        data = std::make_unique<std::uint8_t[]>(length);
    } catch (const std::bad_alloc&) {
        error = "cannot allocate existing save buffer";
        close(fd);
        return false;
    }

    std::size_t offset = 0;
    while (offset < length) {
        const auto result = read(fd, data.get() + offset, length - offset);
        if (result > 0) {
            offset += static_cast<std::size_t>(result);
            continue;
        }
        if (result < 0 && errno == EINTR) continue;
        error = result == 0 ? "existing save ended early"
                            : systemError("read existing save");
        close(fd);
        data.reset();
        length = 0;
        return false;
    }
    if (!closeChecked(fd, error)) {
        data.reset();
        length = 0;
        return false;
    }
    return true;
}

bool HeadlessSaveManager::initialize(const std::uint8_t* currentData,
    std::uint32_t currentLength, std::uint32_t loadedLength,
    std::string& error)
{
    if (currentLength > kMaximumSaveBytes ||
        (currentLength && !currentData)) {
        error = "melonDS reported an invalid cartridge save buffer";
        return false;
    }
    if (loadedLength && loadedLength != currentLength) {
        error = "existing save size does not match this cartridge";
        return false;
    }

    std::lock_guard<std::mutex> lock(mutex_);
    if (initialized_) {
        error = "save persistence was initialized twice";
        return false;
    }
    try {
        if (currentLength)
            shadow_.assign(currentData, currentData + currentLength);
        else
            shadow_.clear();
    } catch (const std::bad_alloc&) {
        error = "cannot allocate cartridge save shadow";
        return false;
    }
    initialized_ = true;
    stats_.saveBytes = currentLength;
    stats_.loadedExisting = loadedLength != 0;
    try {
        worker_ = std::thread(&HeadlessSaveManager::workerMain, this);
    } catch (const std::system_error& exception) {
        initialized_ = false;
        shadow_.clear();
        error = std::string("cannot start save worker: ") + exception.what();
        return false;
    }
    return true;
}

void HeadlessSaveManager::receiveWrite(void* opaque,
    const std::uint8_t* data, std::uint32_t length, std::uint32_t offset,
    std::uint32_t writeLength) noexcept
{
    if (!opaque) return;
    try {
        static_cast<HeadlessSaveManager*>(opaque)->requestWrite(
            data, length, offset, writeLength);
    } catch (...) {
        // melonDS's platform callback cannot report an exception.  A later
        // explicit flush still verifies the generation and returns failure.
    }
}

void HeadlessSaveManager::requestWrite(const std::uint8_t* data,
    std::uint32_t length, std::uint32_t offset,
    std::uint32_t writeLength)
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (!initialized_ || stopped_) return;
    if (!writeLength && (!data || !length)) return;

    // CartRetail::SPIRelease masks its accumulated write length with
    // (SRAMLength - 1).  A write that covers exactly one complete save chip
    // therefore reaches Platform::WriteNDSSave with writeLength == 0 even
    // though the supplied buffer contains a changed full-chip snapshot.  A
    // callback is only issued after melonDS has changed save memory, so retain
    // that boundary case as a full-buffer update instead of silently losing
    // it.  Requiring the established save length to match keeps an unrelated
    // zero-length callback from resizing an existing save.
    const bool fullSnapshot = writeLength == 0;
    ++stats_.callbacks;
    stats_.callbackBytes += fullSnapshot ? length : writeLength;
    if (!data || !length || length > kMaximumSaveBytes ||
        (!fullSnapshot && offset >= length) ||
        writeLength > length ||
        (length > shadow_.size() && !shadow_.empty()) ||
        (fullSnapshot && !shadow_.empty() && length != shadow_.size())) {
        ++stats_.failures;
        lastError_ = "melonDS supplied an invalid save write range";
        lastAttemptSucceeded_ = false;
        callbackError_ = true;
        completed_.notify_all();
        return;
    }

    // Most retail carts get their save size from melonDS's ROM database at
    // construction time.  Keep the callback correct for carts that expose a
    // zero-length buffer initially and allocate it on first use, too.  A
    // shorter replacement callback remains a partial update and preserves the
    // existing tail, matching SetSaveMemory's contract.
    if (shadow_.empty()) {
        try {
            shadow_.assign(data, data + length);
        } catch (const std::bad_alloc&) {
            ++stats_.failures;
            lastError_ = "cannot grow cartridge save shadow";
            lastAttemptSucceeded_ = false;
            callbackError_ = true;
            completed_.notify_all();
            return;
        }
        stats_.saveBytes = length;
    }

    if (fullSnapshot) {
        std::memcpy(shadow_.data(), data, length);
    } else {
        const auto firstLength = std::min(writeLength, length - offset);
        std::memcpy(shadow_.data() + offset, data + offset, firstLength);
        const auto secondLength = writeLength - firstLength;
        if (secondLength)
            std::memcpy(shadow_.data(), data, secondLength);
    }

    const auto now = std::chrono::steady_clock::now();
    if (!dirty_) firstDirty_ = now;
    lastDirty_ = now;
    dirty_ = true;
    ++generation_;
    wake_.notify_all();
}

void HeadlessSaveManager::workerMain() noexcept
{
    std::unique_lock<std::mutex> lock(mutex_);
    for (;;) {
        if (!dirty_) {
            if (stopRequested_) {
                stopped_ = true;
                completed_.notify_all();
                return;
            }
            wake_.wait(lock, [this] { return dirty_ || stopRequested_; });
            continue;
        }

        if (!forceFlush_ && !stopRequested_) {
            const auto due = std::min(lastDirty_ + quietDelay_,
                                      firstDirty_ + maximumDelay_);
            if (std::chrono::steady_clock::now() < due) {
                wake_.wait_until(lock, due);
                continue;
            }
        }

        const auto snapshotGeneration = generation_;
        std::vector<std::uint8_t> snapshot;
        try {
            snapshot = shadow_;
        } catch (const std::bad_alloc&) {
            ++stats_.failures;
            lastError_ = "cannot allocate atomic save snapshot";
            attemptedGeneration_ = snapshotGeneration;
            ++attemptSerial_;
            lastAttemptSucceeded_ = false;
            forceFlush_ = false;
            completed_.notify_all();
            if (stopRequested_) {
                stopped_ = true;
                return;
            }
            lastDirty_ = std::chrono::steady_clock::now();
            continue;
        }
        forceFlush_ = false;
        flushInProgress_ = true;
        lock.unlock();

        std::string commitError;
        bool directorySyncFallback = false;
        bool success = false;
        try {
            success = commitSnapshot(
                snapshot, directorySyncFallback, commitError);
        } catch (const std::exception& exception) {
            commitError = std::string("atomic save commit failed: ") +
                exception.what();
        } catch (...) {
            commitError = "atomic save commit failed";
        }

        lock.lock();
        flushInProgress_ = false;
        attemptedGeneration_ = snapshotGeneration;
        ++attemptSerial_;
        lastAttemptSucceeded_ = success;
        if (directorySyncFallback) ++stats_.directorySyncFallbacks;
        if (success) {
            ++stats_.commits;
            committedGeneration_ = std::max(
                committedGeneration_, snapshotGeneration);
            lastError_.clear();
            if (generation_ == snapshotGeneration) dirty_ = false;
        } else {
            ++stats_.failures;
            lastError_ = std::move(commitError);
            if (generation_ == snapshotGeneration) {
                firstDirty_ = std::chrono::steady_clock::now();
                lastDirty_ = firstDirty_;
            }
        }
        completed_.notify_all();

        if (stopRequested_ && (!success || !dirty_)) {
            // Emulation has stopped before shutdown, so no newer callback can
            // race a newly captured snapshot.  If shutdown arrived while an
            // older periodic commit was in progress, loop once more to commit
            // the newer dirty generation.  One failed atomic attempt is
            // reported rather than hanging core unload forever.
            stopped_ = true;
            completed_.notify_all();
            return;
        }
    }
}

bool HeadlessSaveManager::commitSnapshot(
    const std::vector<std::uint8_t>& snapshot,
    bool& directorySyncFallback, std::string& error)
{
    directorySyncFallback = false;
    std::string temporaryTemplate =
        (std::filesystem::path(root_) / (temporaryPrefix_ + "XXXXXX")).string();
    std::vector<char> temporaryName(
        temporaryTemplate.begin(), temporaryTemplate.end());
    temporaryName.push_back('\0');
    const int fd = mkstemp(temporaryName.data());
    if (fd < 0) {
        error = systemError("create temporary save");
        return false;
    }
    auto fail = [&](const std::string& message) {
        error = message;
        close(fd);
        unlink(temporaryName.data());
        return false;
    };
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0)
        return fail(systemError("protect temporary save descriptor"));
    if (fchmod(fd, 0600) != 0)
        return fail(systemError("set temporary save permissions"));

    std::size_t offset = 0;
    while (offset < snapshot.size()) {
        const auto result = write(fd, snapshot.data() + offset,
            snapshot.size() - offset);
        if (result > 0) {
            offset += static_cast<std::size_t>(result);
            continue;
        }
        if (result < 0 && errno == EINTR) continue;
        return fail(result == 0 ? "temporary save write made no progress"
                                : systemError("write temporary save"));
    }
    if (syncSaveFile(fd) != 0)
        return fail(systemError("sync temporary save"));
    if (!closeChecked(fd, error)) {
        unlink(temporaryName.data());
        return false;
    }

    if (rename(temporaryName.data(), savePath_.c_str()) != 0) {
        error = systemError("commit temporary save");
        unlink(temporaryName.data());
        return false;
    }
    int directoryFlags = O_RDONLY | O_CLOEXEC;
#ifdef O_DIRECTORY
    directoryFlags |= O_DIRECTORY;
#endif
    const int directory = open(root_.c_str(), directoryFlags);
    if (directory < 0) {
        error = systemError("open save directory for sync");
        return false;
    }
    const int syncResult = fsync(directory);
    const int syncError = errno;
    if (syncResult != 0 &&
        !headlessSaveDirectorySyncUnsupported(syncError)) {
        errno = syncError;
        error = systemError("sync save directory");
        close(directory);
        return false;
    }
    if (!closeChecked(directory, error)) return false;
    directorySyncFallback = syncResult != 0;
    return true;
}

bool HeadlessSaveManager::flush(std::string& error)
{
    std::unique_lock<std::mutex> lock(mutex_);
    if (callbackError_) {
        error = lastError_.empty() ? "invalid cartridge save callback"
                                   : lastError_;
        return false;
    }
    if (!initialized_ || shadow_.empty() || (!dirty_ && !flushInProgress_))
        return true;
    if (stopped_) {
        error = lastError_.empty() ? "save worker stopped while dirty" : lastError_;
        return false;
    }

    const auto targetGeneration = generation_;
    const auto startingAttempt = attemptSerial_;
    forceFlush_ = true;
    wake_.notify_all();
    completed_.wait(lock, [this, targetGeneration, startingAttempt] {
        return committedGeneration_ >= targetGeneration || stopped_ ||
            (attemptSerial_ > startingAttempt &&
             attemptedGeneration_ >= targetGeneration &&
             !lastAttemptSucceeded_);
    });
    if (committedGeneration_ >= targetGeneration) return true;
    error = lastError_.empty() ? "atomic save flush failed" : lastError_;
    return false;
}

bool HeadlessSaveManager::shutdown(std::string& error)
{
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!worker_.joinable()) {
            if (dirty_ || callbackError_) {
                error = lastError_.empty() ? "save worker stopped while dirty"
                                           : lastError_;
                return false;
            }
            return true;
        }
        stopRequested_ = true;
        forceFlush_ = true;
        wake_.notify_all();
    }
    worker_.join();

    std::lock_guard<std::mutex> lock(mutex_);
    if (dirty_ || callbackError_) {
        error = lastError_.empty() ? "atomic save shutdown flush failed"
                                   : lastError_;
        return false;
    }
    return true;
}

void HeadlessSaveManager::stopWorkerNoThrow() noexcept
{
    try {
        std::string ignored;
        shutdown(ignored);
    } catch (...) {
        if (worker_.joinable()) {
            {
                std::lock_guard<std::mutex> lock(mutex_);
                stopRequested_ = true;
                wake_.notify_all();
            }
            worker_.join();
        }
    }
}

SavePersistenceStats HeadlessSaveManager::stats() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    auto result = stats_;
    result.dirty = dirty_;
    return result;
}

} // namespace nds4mister

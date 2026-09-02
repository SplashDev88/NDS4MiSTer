#include "replay/SoundPersistentEpoch.h"

#include "replay/StandaloneBoot.h"

#include <cerrno>
#include <climits>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <stdexcept>
#include <string>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

namespace nds4mister {
namespace {

constexpr std::uint32_t kSoundEpochMagic = 0x4553444eu; // "NDSE"
constexpr std::uint32_t kSoundEpochVersion = 1;

struct SoundEpochRecord {
    std::uint32_t magic = kSoundEpochMagic;
    std::uint32_t version = kSoundEpochVersion;
    std::uint32_t last_epoch = 0;
    std::uint32_t crc32 = 0;

    void seal() {
        crc32 = 0;
        crc32 = boot_crc32(this, offsetof(SoundEpochRecord, crc32));
    }

    bool valid() const {
        return magic == kSoundEpochMagic &&
            version == kSoundEpochVersion &&
            last_epoch != 0 &&
            boot_crc32(this, offsetof(SoundEpochRecord, crc32)) == crc32;
    }
};

static_assert(sizeof(SoundEpochRecord) == 16);

class FileDescriptor {
public:
    explicit FileDescriptor(int fd) : fd_(fd) {}
    FileDescriptor(const FileDescriptor&) = delete;
    FileDescriptor& operator=(const FileDescriptor&) = delete;
    ~FileDescriptor() {
        if (fd_ >= 0) close(fd_);
    }
    int get() const { return fd_; }

private:
    int fd_;
};

[[noreturn]] void throw_errno(const char* operation,
                              const std::string& path) {
    throw std::runtime_error(std::string(operation) + " " + path + ": " +
                             std::strerror(errno));
}

void read_exact(int fd, void* destination, std::size_t bytes,
                const std::string& path) {
    auto* cursor = static_cast<std::byte*>(destination);
    std::size_t offset = 0;
    while (offset < bytes) {
        const auto result = pread(
            fd, cursor + offset, bytes - offset, static_cast<off_t>(offset));
        if (result < 0) {
            if (errno == EINTR) continue;
            throw_errno("read sound epoch", path);
        }
        if (result == 0)
            throw std::runtime_error("short sound epoch record " + path);
        offset += static_cast<std::size_t>(result);
    }
}

void write_exact(int fd, const void* source, std::size_t bytes,
                 const std::string& path) {
    const auto* cursor = static_cast<const std::byte*>(source);
    std::size_t offset = 0;
    while (offset < bytes) {
        const auto result = pwrite(
            fd, cursor + offset, bytes - offset, static_cast<off_t>(offset));
        if (result < 0) {
            if (errno == EINTR) continue;
            throw_errno("write sound epoch", path);
        }
        if (result == 0)
            throw std::runtime_error("short sound epoch write " + path);
        offset += static_cast<std::size_t>(result);
    }
}

} // namespace

std::uint32_t allocate_persistent_sound_epoch(const std::string& path) {
    if (path.empty())
        throw std::runtime_error("sound epoch path is empty");

    // Keep a separate, durable lock marker.  Once it exists, disappearance or
    // zero-length truncation of the data record is evidence of lost state and
    // must fail closed rather than silently restarting at epoch one.
    const std::string lockPath = path + ".lock";
    bool lockCreated = false;
    int lockFd = open(lockPath.c_str(), O_RDWR | O_CLOEXEC);
    if (lockFd < 0 && errno == ENOENT) {
        lockFd = open(lockPath.c_str(),
                      O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (lockFd >= 0) lockCreated = true;
        else if (errno == EEXIST)
            lockFd = open(lockPath.c_str(), O_RDWR | O_CLOEXEC);
    }
    if (lockFd < 0) throw_errno("open sound epoch lock", lockPath);
    FileDescriptor lockDescriptor(lockFd);
    if (flock(lockFd, LOCK_EX) != 0)
        throw_errno("lock sound epoch", lockPath);
    if (lockCreated && fsync(lockFd) != 0)
        throw_errno("sync sound epoch lock", lockPath);

    bool recordCreated = false;
    int fd = open(path.c_str(), O_RDWR | O_CLOEXEC);
    if (fd < 0 && errno == ENOENT) {
        if (!lockCreated)
            throw std::runtime_error("missing persistent sound epoch " + path);
        fd = open(path.c_str(),
                  O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (fd >= 0) recordCreated = true;
    }
    if (fd < 0) throw_errno("open sound epoch", path);
    FileDescriptor descriptor(fd);

    struct stat state {};
    if (fstat(fd, &state) != 0) throw_errno("stat sound epoch", path);
    if ((state.st_size == 0 && !recordCreated) ||
        (state.st_size != 0 &&
         state.st_size != static_cast<off_t>(sizeof(SoundEpochRecord)))) {
        throw std::runtime_error("invalid sound epoch record size " + path);
    }

    std::uint32_t previous = 0;
    if (state.st_size == static_cast<off_t>(sizeof(SoundEpochRecord))) {
        SoundEpochRecord existing;
        read_exact(fd, &existing, sizeof(existing), path);
        if (!existing.valid())
            throw std::runtime_error("invalid sound epoch record " + path);
        previous = existing.last_epoch;
    }

    if (previous == UINT32_MAX)
        throw std::runtime_error("sound epoch exhausted " + path);
    const std::uint32_t allocated = previous + 1;

    SoundEpochRecord next;
    next.last_epoch = allocated;
    next.seal();
    write_exact(fd, &next, sizeof(next), path);
    if (ftruncate(fd, static_cast<off_t>(sizeof(next))) != 0)
        throw_errno("truncate sound epoch", path);
    if (fsync(fd) != 0) throw_errno("sync sound epoch", path);

    SoundEpochRecord verified;
    read_exact(fd, &verified, sizeof(verified), path);
    if (!verified.valid() || verified.last_epoch != allocated)
        throw std::runtime_error("sound epoch durable readback mismatch " +
                                 path);
    return allocated;
}

} // namespace nds4mister

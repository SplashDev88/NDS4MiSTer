#pragma once

#include <cerrno>
#include <cstddef>
#include <cstring>
#include <fcntl.h>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace nds4mister::h3d::memory {

constexpr std::size_t WindowBytes = 0x400000;
constexpr std::size_t ControlBytes = 0x100000;
constexpr std::size_t PublicationBytes = WindowBytes - ControlBytes;
constexpr off_t PhysicalBase = 0x3fc00000;
constexpr off_t PublicationPhysicalBase = PhysicalBase + ControlBytes;

// Private A/B control: no renderer, pacing, diagnostic or clock changes.
inline bool disable_write_combining(const char* value)
{
    if (!value || std::strcmp(value, "0") == 0) return false;
    if (std::strcmp(value, "1") == 0) return true;
    throw std::runtime_error("NDS4MISTER_H3D_DISABLE_WC must be 0 or 1");
}

struct PosixMappingOps {
    int open(const char* path, int flags) { return ::open(path, flags); }
    int stat(int fd, struct stat* status) { return ::fstat(fd, status); }
    int close(int fd) { return ::close(fd); }
    void* map(std::size_t bytes, int fd, off_t offset)
    {
        return ::mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_SHARED,
                      fd, offset);
    }
    int unmap(void* address, std::size_t bytes)
    {
        return ::munmap(address, bytes);
    }
};

// Ops is injectable only to exercise failed syscalls and the physical mapping
// contract without /dev/mem. The production specialization calls POSIX directly.
template<class Ops = PosixMappingOps>
class BasicMapping {
    class Region {
    public:
        explicit Region(Ops& ops) : ops_(ops) {}
        ~Region()
        {
            if (address_ != MAP_FAILED) ops_.unmap(address_, bytes_);
        }
        Region(const Region&) = delete;
        Region& operator=(const Region&) = delete;

        bool map(const char* path, std::size_t bytes, off_t offset,
                 bool regular_file = false)
        {
            const int fd = ops_.open(path, O_RDWR | O_SYNC | O_CLOEXEC);
            if (fd < 0) {
                error_ = errno;
                return false;
            }
            if (regular_file) {
                struct stat status {};
                if (ops_.stat(fd, &status) != 0) {
                    error_ = errno;
                    ops_.close(fd);
                    return false;
                }
                if (status.st_size < static_cast<off_t>(bytes)) {
                    error_ = EINVAL;
                    ops_.close(fd);
                    return false;
                }
            }
            void* const mapped = ops_.map(bytes, fd, offset);
            error_ = mapped == MAP_FAILED ? errno : 0;
            ops_.close(fd);
            if (mapped == MAP_FAILED) return false;
            address_ = mapped;
            bytes_ = bytes;
            return true;
        }

        void* data() const { return address_; }
        std::size_t size() const { return bytes_; }
        int error() const { return error_; }

    private:
        Ops& ops_;
        void* address_ = MAP_FAILED;
        std::size_t bytes_ = 0;
        int error_ = 0;
    };

public:
    explicit BasicMapping(const std::string& path, bool disable_wc = false,
                          Ops ops = {})
        : ops_(ops), control_(ops_), publication_(ops_),
          physical_(path == "/dev/mem")
    {
        if (!physical_) {
            if (!control_.map(path.c_str(), WindowBytes, 0, true))
                mapping_error("map memory file " + path, control_.error());
            return;
        }

        // Only header/policy/packet pages retain Device attributes. Never map
        // the pixel pages here: a second WC VMA for those physical pages would
        // leave an ARM memory-type alias, even if we avoid its old pointer.
        if (!control_.map("/dev/mem", ControlBytes, PhysicalBase))
            mapping_error("map H3D control", control_.error());

        if (!disable_wc) {
            for (const char* device : {"/dev/nds_mem_wc", "/dev/mem_wc"}) {
                if (publication_.map(device, PublicationBytes,
                                     PublicationPhysicalBase)) {
                    wc_device_ = device;
                    return;
                }
            }
        }
        fallback_error_ = publication_.error();
        forced_device_ = disable_wc;
        if (!publication_.map("/dev/mem", PublicationBytes,
                              PublicationPhysicalBase))
            mapping_error("map H3D publication fallback", publication_.error());
    }

    BasicMapping(const BasicMapping&) = delete;
    BasicMapping& operator=(const BasicMapping&) = delete;

    void* data() const { return control_.data(); }
    std::size_t size() const { return control_.size(); }
    void* publication_data() const
    {
        return physical_ ? publication_.data() : nullptr;
    }
    bool write_combined() const { return wc_device_ != nullptr; }
    std::string mode_message() const
    {
        if (!physical_) return {};
        if (wc_device_)
            return std::string("H3D: write-combined 3D publication enabled via ") +
                wc_device_ + "; nonoverlapping mappings; disable_wc=0";
        if (forced_device_)
            return "H3D: Device-memory publication forced for A/B; "
                   "nonoverlapping mappings; disable_wc=1";
        return std::string("H3D: write-combined device unavailable (") +
            std::strerror(fallback_error_) +
            "); using Device-memory publication; nonoverlapping mappings; "
            "disable_wc=0";
    }

private:
    [[noreturn]] static void mapping_error(const std::string& operation,
                                         int error)
    {
        throw std::runtime_error(operation + ": " + std::strerror(error));
    }

    Ops ops_;
    Region control_;
    Region publication_;
    bool physical_ = false;
    bool forced_device_ = false;
    const char* wc_device_ = nullptr;
    int fallback_error_ = 0;
};

using Mapping = BasicMapping<>;

} // namespace nds4mister::h3d::memory

#include "replay/Hybrid3DMemoryMapping.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <iostream>
#include <map>
#include <set>
#include <vector>

namespace memory = nds4mister::h3d::memory;

static void require(bool value, const char* message)
{
    if (!value) throw std::runtime_error(message);
}

struct State {
    struct Map {
        void* pointer;
        std::size_t size;
        off_t physical;
        std::string device;
    };
    std::string backing;
    std::set<std::string> available {"/dev/mem", "/dev/nds_mem_wc"};
    std::set<std::string> fail_map;
    bool fail_publication_device = false;
    bool fail_stat = false;
    std::map<int, std::string> opened;
    std::vector<std::string> attempts;
    std::vector<Map> active;
    std::size_t maps_completed = 0;
    std::size_t unmaps_completed = 0;
};

// This backend records physical requests while mmap'ing disjoint portions of
// a real shared temporary file. It never opens a device or uses physical RAM.
struct TestOps {
    State* state;
    int open(const char* path, int flags)
    {
        state->attempts.emplace_back(path);
        const bool device = std::string(path).rfind("/dev/", 0) == 0;
        if (device && state->available.count(path) == 0) {
            errno = ENOENT;
            return -1;
        }
        const int fd = ::open(device ? state->backing.c_str() : path, flags);
        if (fd >= 0) state->opened[fd] = path;
        return fd;
    }
    int stat(int fd, struct stat* status)
    {
        if (state->fail_stat) {
            errno = EIO;
            return -1;
        }
        return ::fstat(fd, status);
    }
    int close(int fd)
    {
        require(state->opened.erase(fd) == 1, "unexpected fd close");
        return ::close(fd);
    }
    void* map(std::size_t bytes, int fd, off_t offset)
    {
        const auto device = state->opened.at(fd);
        if (state->fail_map.count(device) ||
            (state->fail_publication_device && device == "/dev/mem" &&
             offset == memory::PublicationPhysicalBase)) {
            errno = EPERM;
            return MAP_FAILED;
        }
        const bool physical = device.rfind("/dev/", 0) == 0;
        if (physical) {
            require(offset >= memory::PhysicalBase &&
                    static_cast<std::uint64_t>(offset) + bytes <=
                        std::uint64_t(memory::PhysicalBase) + memory::WindowBytes,
                    "mapping escaped reserved H3D aperture");
            for (const auto& live : state->active) {
                require(offset + static_cast<off_t>(bytes) <= live.physical ||
                        live.physical + static_cast<off_t>(live.size) <= offset,
                        "overlapping physical mappings / ARM attribute alias");
            }
        }
        void* pointer = ::mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_SHARED,
                              fd, physical ? offset - memory::PhysicalBase : offset);
        if (pointer != MAP_FAILED) {
            state->active.push_back({pointer, bytes, offset, device});
            ++state->maps_completed;
        }
        return pointer;
    }
    int unmap(void* address, std::size_t bytes)
    {
        const auto it = std::find_if(state->active.begin(), state->active.end(),
            [address, bytes](const State::Map& m) {
                return m.pointer == address && m.size == bytes;
            });
        require(it != state->active.end(), "unmap used wrong address/length");
        state->active.erase(it);
        ++state->unmaps_completed;
        return ::munmap(address, bytes);
    }
};

using Mapping = memory::BasicMapping<TestOps>;

static void check_released(const State& state)
{
    require(state.opened.empty(), "mapping leaked fd");
    require(state.active.empty(), "mapping leaked VMA");
    require(state.maps_completed == state.unmaps_completed,
            "exception/destruction did not unmap every successful region");
}

static void physical_case(State state, bool disable, bool expect_wc,
                          const char* expected_device)
{
    {
        Mapping mapping("/dev/mem", disable, TestOps{&state});
        require(mapping.size() == memory::ControlBytes,
                "physical control map still includes publication pages");
        require(state.active.size() == 2, "physical mapping count");
        require(state.active[0].physical == memory::PhysicalBase &&
                state.active[0].size == memory::ControlBytes &&
                state.active[0].device == "/dev/mem", "control mapping changed");
        require(state.active[1].physical == memory::PublicationPhysicalBase &&
                state.active[1].size == memory::PublicationBytes &&
                state.active[1].device == expected_device, "pixel mapping changed");
        require(mapping.write_combined() == expect_wc, "wrong publisher mode");
        require(state.opened.empty(), "mapping retained unnecessary fds");
        if (disable) {
            require(std::none_of(state.attempts.begin(), state.attempts.end(),
                    [](const auto& path) { return path.find("wc") != std::string::npos; }),
                    "forced Device mode attempted WC");
            require(mapping.mode_message().find("disable_wc=1") != std::string::npos,
                    "forced A/B choice not logged");
        }
        auto* control = static_cast<std::uint32_t*>(mapping.data());
        auto* pixels = static_cast<std::uint32_t*>(mapping.publication_data());
        control[0] = 0x31443348;
        control[memory::ControlBytes / 4 - 1] = 0xabcdef01;
        pixels[0] = 0x10203040;
        pixels[memory::PublicationBytes / 4 - 1] = 0x50607080;
        const int file = ::open(state.backing.c_str(), O_RDONLY);
        require(file >= 0, "verify file open failed");
        std::uint32_t words[2] {};
        require(::pread(file, words, sizeof(words), memory::ControlBytes - 4) == 8 &&
                words[0] == 0xabcdef01 && words[1] == 0x10203040,
                "split mapping points at wrong physical bytes");
        require(::pread(file, words, 4, memory::WindowBytes - 4) == 4 &&
                words[0] == 0x50607080, "pixel mapping tail offset incorrect");
        ::close(file);
    }
    check_released(state);
}

int main()
try {
    char path[] = "/tmp/nds-h3d-mapping-XXXXXX";
    const int fd = ::mkstemp(path);
    require(fd >= 0 && ::ftruncate(fd, memory::WindowBytes) == 0,
            "could not create mapping fixture");
    ::close(fd);
    struct Cleanup {
        const char* path;
        ~Cleanup() { ::unlink(path); }
    } cleanup {path};

    State baseline;
    baseline.backing = path;
    physical_case(baseline, false, true, "/dev/nds_mem_wc");
    physical_case(baseline, true, false, "/dev/mem");
    auto fallback = baseline;
    fallback.available.erase("/dev/nds_mem_wc");
    physical_case(fallback, false, false, "/dev/mem");
    fallback.available.insert("/dev/mem_wc");
    physical_case(fallback, false, true, "/dev/mem_wc");
    fallback.available.insert("/dev/nds_mem_wc");
    fallback.fail_map.insert("/dev/nds_mem_wc");
    physical_case(fallback, false, true, "/dev/mem_wc");
    fallback.fail_map.insert("/dev/mem_wc");
    physical_case(fallback, false, false, "/dev/mem");

    // Total mapping failure must release the already-created control map.
    fallback.fail_publication_device = true;
    bool rejected = false;
    try { Mapping mapping("/dev/mem", false, TestOps{&fallback}); }
    catch (const std::runtime_error&) { rejected = true; }
    require(rejected, "failed fallback did not fail closed");
    check_released(fallback);

    State file_state;
    file_state.backing = path;
    {
        Mapping mapping(path, false, TestOps{&file_state});
        require(mapping.size() == memory::WindowBytes &&
                mapping.publication_data() == nullptr && !mapping.write_combined(),
                "file-backed lifecycle contract changed");
        require(file_state.attempts == std::vector<std::string>{path} &&
                mapping.mode_message().empty(), "file-backed mode touched devices");
    }
    check_released(file_state);
    file_state.fail_stat = true;
    rejected = false;
    try { Mapping mapping(path, false, TestOps{&file_state}); }
    catch (const std::runtime_error&) { rejected = true; }
    require(rejected, "stat failure accepted");
    check_released(file_state);
    file_state.fail_stat = false;
    const int short_fd = ::open(path, O_RDWR);
    require(short_fd >= 0 && ::ftruncate(short_fd, memory::WindowBytes - 1) == 0,
            "truncate fixture failed");
    ::close(short_fd);
    rejected = false;
    try { Mapping mapping(path, false, TestOps{&file_state}); }
    catch (const std::runtime_error&) { rejected = true; }
    require(rejected, "short file accepted");
    check_released(file_state);

    require(!memory::disable_write_combining(nullptr) &&
            !memory::disable_write_combining("0") &&
            memory::disable_write_combining("1"), "A/B choice parsing");
    for (const char* invalid : {"", "2", "yes", "false", "1x"}) {
        rejected = false;
        try { memory::disable_write_combining(invalid); }
        catch (const std::runtime_error&) { rejected = true; }
        require(rejected, "ambiguous A/B mode was accepted");
    }
    std::cout << "H3D_MEMORY_MAPPING_TEST_PASS\n";
} catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
}

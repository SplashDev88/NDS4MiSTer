#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {

std::uint64_t parseNumber(const char* text, const char* name) {
    char* end = nullptr;
    errno = 0;
    const auto value = std::strtoull(text, &end, 0);
    if (errno != 0 || end == text || *end != '\0')
        throw std::runtime_error(std::string("invalid ") + name + ": " + text);
    return value;
}

void writeAll(int descriptor, const std::byte* data, std::size_t bytes) {
    while (bytes != 0) {
        const auto result = write(descriptor, data, bytes);
        if (result < 0) {
            if (errno == EINTR) continue;
            throw std::runtime_error(
                std::string("write snapshot: ") + std::strerror(errno));
        }
        if (result == 0)
            throw std::runtime_error("write snapshot returned zero");
        data += result;
        bytes -= static_cast<std::size_t>(result);
    }
}

} // namespace

int main(int argc, char** argv) try {
    if (argc != 4) {
        std::cerr << "usage: " << argv[0]
                  << " PHYSICAL_ADDRESS BYTE_COUNT OUTPUT\n";
        return 2;
    }

    const auto physical = parseNumber(argv[1], "physical address");
    const auto count64 = parseNumber(argv[2], "byte count");
    if (count64 == 0 || count64 > 16u * 1024u * 1024u)
        throw std::runtime_error("byte count must be between 1 and 16777216");
    const auto count = static_cast<std::size_t>(count64);

    const long pageResult = sysconf(_SC_PAGESIZE);
    if (pageResult <= 0)
        throw std::runtime_error("cannot determine system page size");
    const auto pageSize = static_cast<std::uint64_t>(pageResult);
    const auto page = physical & ~(pageSize - 1u);
    const auto offset = static_cast<std::size_t>(physical - page);
    if (offset > SIZE_MAX - count)
        throw std::runtime_error("snapshot range overflow");
    const auto mapBytes = offset + count;

    const int memory = open("/dev/mem", O_RDONLY | O_SYNC | O_CLOEXEC);
    if (memory < 0)
        throw std::runtime_error(
            std::string("open /dev/mem: ") + std::strerror(errno));
    void* mapping = mmap(nullptr, mapBytes, PROT_READ, MAP_SHARED, memory,
                         static_cast<off_t>(page));
    const int mapError = errno;
    close(memory);
    if (mapping == MAP_FAILED)
        throw std::runtime_error(
            std::string("mmap /dev/mem: ") + std::strerror(mapError));

    std::vector<std::byte> snapshot(count);
    const auto* source = reinterpret_cast<volatile const std::uint8_t*>(
        static_cast<const std::byte*>(mapping) + offset);
    __sync_synchronize();
    for (std::size_t index = 0; index < count; ++index)
        snapshot[index] = static_cast<std::byte>(source[index]);
    __sync_synchronize();
    munmap(mapping, mapBytes);

    const int output = open(argv[3],
                            O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
                            S_IRUSR | S_IWUSR);
    if (output < 0)
        throw std::runtime_error(
            std::string("open output: ") + std::strerror(errno));
    try {
        writeAll(output, snapshot.data(), snapshot.size());
    } catch (...) {
        close(output);
        throw;
    }
    if (fsync(output) != 0) {
        const int syncError = errno;
        close(output);
        throw std::runtime_error(
            std::string("fsync output: ") + std::strerror(syncError));
    }
    if (close(output) != 0)
        throw std::runtime_error(
            std::string("close output: ") + std::strerror(errno));

    std::cout << "snapshot physical=0x" << std::hex << physical << std::dec
              << " bytes=" << count << " output=" << argv[3] << "\n";
    return 0;
} catch (const std::exception& error) {
    std::cerr << "nds_physical_memory_snapshot: " << error.what() << "\n";
    return 1;
}

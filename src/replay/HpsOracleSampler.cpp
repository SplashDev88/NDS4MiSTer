#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <unordered_map>
#include <vector>

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

namespace {
constexpr std::uint32_t kMagic = 0x4f53444e;
constexpr std::uintptr_t kPhysical = 0x2c000000;

std::uint64_t parseCount(const char* text) {
    char* end = nullptr;
    errno = 0;
    const auto value = std::strtoull(text, &end, 0);
    if (errno || !end || *end || value == 0)
        throw std::runtime_error("sample count must be a positive integer");
    return value;
}

std::uint32_t parseWord(const char* text, const char* name) {
    char* end = nullptr;
    errno = 0;
    const auto value = std::strtoull(text, &end, 0);
    if (errno || !end || *end || value > 0xffffffffull)
        throw std::runtime_error(std::string(name) +
                                 " must be a 32-bit integer");
    return static_cast<std::uint32_t>(value);
}
}

int main(int argc, char** argv) try {
    if (argc > 18) {
        std::cerr << "usage: nds_hps_oracle_sampler [samples] "
                     "[--after-reset] [--non-timing] [--pc-stream] "
                     "[--bus-stream] "
                     "[--match-address address] "
                     "[--duration seconds] [--trigger-address address] "
                     "[--trigger-write-below address] "
                     "[--trigger-cpu 7|9] [--pre-pc count] "
                     "[--post-pc count]\n";
        return 2;
    }
    const std::uint64_t wanted = argc >= 2 ? parseCount(argv[1]) : 200000;
    bool afterReset = false;
    bool nonTiming = false;
    bool pcStream = false;
    bool busStream = false;
    bool haveMatchAddress = false;
    std::uint32_t matchAddress = 0;
    unsigned durationSeconds = 10;
    bool haveTriggerAddress = false;
    std::uint32_t triggerAddress = 0;
    bool haveTriggerWriteBelow = false;
    std::uint32_t triggerWriteBelow = 0;
    unsigned triggerCpu = 9;
    std::size_t prePcCount = 4096;
    std::size_t postPcCount = 4096;
    for (int index = 2; index < argc; ++index) {
        if (std::strcmp(argv[index], "--after-reset") == 0) afterReset = true;
        else if (std::strcmp(argv[index], "--non-timing") == 0) nonTiming = true;
        else if (std::strcmp(argv[index], "--pc-stream") == 0) pcStream = true;
        else if (std::strcmp(argv[index], "--bus-stream") == 0) busStream = true;
        else if (std::strcmp(argv[index], "--match-address") == 0 &&
                 index + 1 < argc) {
            matchAddress = parseWord(argv[++index], "match address");
            haveMatchAddress = true;
        }
        else if (std::strcmp(argv[index], "--duration") == 0 &&
                 index + 1 < argc) {
            durationSeconds = static_cast<unsigned>(
                parseCount(argv[++index]));
        } else if (std::strcmp(argv[index], "--trigger-address") == 0 &&
                 index + 1 < argc) {
            triggerAddress = parseWord(argv[++index], "trigger address");
            haveTriggerAddress = true;
        } else if (std::strcmp(argv[index], "--trigger-write-below") == 0 &&
                 index + 1 < argc) {
            triggerWriteBelow =
                parseWord(argv[++index], "trigger write threshold");
            haveTriggerWriteBelow = true;
        } else if (std::strcmp(argv[index], "--trigger-cpu") == 0 &&
                   index + 1 < argc) {
            triggerCpu = static_cast<unsigned>(parseCount(argv[++index]));
            if (triggerCpu != 7 && triggerCpu != 9)
                throw std::runtime_error("trigger CPU must be 7 or 9");
        } else if (std::strcmp(argv[index], "--pre-pc") == 0 &&
                   index + 1 < argc) {
            prePcCount = static_cast<std::size_t>(parseCount(argv[++index]));
        } else if (std::strcmp(argv[index], "--post-pc") == 0 &&
                   index + 1 < argc) {
            postPcCount = static_cast<std::size_t>(parseCount(argv[++index]));
        }
        else {
            std::cerr << "unknown option: " << argv[index] << "\n";
            return 2;
        }
    }
    if (haveTriggerAddress && haveTriggerWriteBelow)
        throw std::runtime_error(
            "trigger address and trigger write threshold are mutually exclusive");
    const bool haveTrigger = haveTriggerAddress || haveTriggerWriteBelow;
    const long pageResult = sysconf(_SC_PAGESIZE);
    const std::size_t pageSize = pageResult > 0
        ? static_cast<std::size_t>(pageResult) : 4096u;
    const auto page = kPhysical & ~(static_cast<std::uintptr_t>(pageSize) - 1u);
    const auto offset = static_cast<std::size_t>(kPhysical - page);
    const char* mailboxFile =
        std::getenv("NDS4MISTER_SAMPLER_MAILBOX_FILE");
    if (mailboxFile && !*mailboxFile)
        throw std::runtime_error(
            "NDS4MISTER_SAMPLER_MAILBOX_FILE must not be empty");
    const char* mailboxPath = mailboxFile ? mailboxFile : "/dev/mem";
    const off_t mailboxOffset =
        mailboxFile ? 0 : static_cast<off_t>(page);
    const int fd = open(mailboxPath, O_RDONLY | O_SYNC | O_CLOEXEC);
    if (fd < 0)
        throw std::runtime_error(
            std::string(mailboxFile ? "open mailbox file: " :
                                      "open /dev/mem: ") +
            std::strerror(errno));
    void* mapping = mmap(nullptr, pageSize, PROT_READ, MAP_SHARED, fd,
                         mailboxOffset);
    close(fd);
    if (mapping == MAP_FAILED)
        throw std::runtime_error(std::string("mmap mailbox: ") +
                                 std::strerror(errno));
    auto* words = reinterpret_cast<volatile const std::uint32_t*>(
        static_cast<const std::byte*>(mapping) + offset);

    if (afterReset) {
        const std::uint32_t baseline = words[1];
        const auto resetDeadline =
            std::chrono::steady_clock::now() + std::chrono::seconds(15);
        while (words[1] >= baseline &&
               std::chrono::steady_clock::now() < resetDeadline) {}
        if (words[1] >= baseline)
            throw std::runtime_error("mailbox generation did not reset");
    }

    std::array<std::uint64_t, 256> regions{};
    std::array<std::uint64_t, 2> cpus{}, directions{};
    std::array<std::uint64_t, 4> widths{};
    std::unordered_map<std::uint32_t, std::uint64_t> addresses;
    std::array<std::unordered_map<std::uint32_t, std::uint64_t>, 2>
        timingPcs;
    struct TraceEntry {
        std::uint32_t generation;
        std::uint32_t address;
        std::uint32_t writeData;
        std::uint32_t control;
        std::uint32_t cycles;
    };
    std::array<TraceEntry, 256> firstInRegion{};
    std::array<bool, 256> sawRegion{};
    std::vector<TraceEntry> prefix;
    std::deque<TraceEntry> recent;
    std::deque<TraceEntry> preTriggerPcs;
    std::vector<TraceEntry> suspicious;
    unsigned suspiciousAfter = 0;
    bool triggered = !haveTrigger;
    std::size_t postTriggerPcs = 0;
    std::uint32_t previous = words[1], first = previous, last = previous;
    std::uint32_t firstAddress = 0, lastAddress = 0;
    std::uint32_t firstControl = 0, lastControl = 0;
    std::uint32_t firstCycles = 0, lastCycles = 0;
    std::uint64_t samples = 0;
    std::uint64_t validMatchedResponses = 0;
    bool observedMailboxPublication = false;
    const auto start = std::chrono::steady_clock::now();
    const auto deadline = start + std::chrono::seconds(durationSeconds);
    while (samples < wanted && std::chrono::steady_clock::now() < deadline) {
        const std::uint32_t generation = words[1];
        if (generation == previous || words[0] != kMagic) {
            // When armed from menu.rbf, the FPGA has not fetched its boot
            // descriptor yet and generation is still zero. A full-speed HPS
            // read loop here can starve that first shared-DDR transaction.
            // Back off only until the first mailbox publication; once boot
            // starts, retain the original tight sampling cadence.
            if (samples == 0 &&
                (!haveMatchAddress || !observedMailboxPublication))
                usleep(100);
            continue;
        }
        __sync_synchronize();
        const std::uint32_t address = words[2];
        const std::uint32_t writeData = words[3];
        const std::uint32_t control = words[4];
        const std::uint32_t cycles = words[5];
        __sync_synchronize();
        if (words[1] != generation) continue;
        observedMailboxPublication = true;
        previous = last = generation;
        if (haveMatchAddress && address != matchAddress) continue;
        if (nonTiming && address == 0xffffffffu) continue;
        std::uint32_t responseData = 0;
        bool responseValid = false;
        if (busStream && address != 0xffffffffu) {
            // The sampler is read-only. Wait only for this already-published
            // request to complete, then snapshot the responder's value before
            // the FPGA is allowed to advance to the next generation.
            const auto responseDeadline =
                std::chrono::steady_clock::now() +
                std::chrono::milliseconds(50);
            while (words[7] != generation &&
                   words[1] == generation &&
                   std::chrono::steady_clock::now() < responseDeadline) {}
            if (words[7] == generation) {
                __sync_synchronize();
                responseData = words[6];
                __sync_synchronize();
                responseValid = words[7] == generation;
            }
        }
        if (haveMatchAddress && responseValid) ++validMatchedResponses;
        if (!samples) {
            firstAddress = address;
            firstControl = control;
            firstCycles = cycles;
        }
        lastAddress = address;
        lastControl = control;
        lastCycles = cycles;
        const TraceEntry entry{generation, address, writeData, control, cycles};
        const unsigned entryCpu = (control & 8u) ? 9 : 7;
        if (busStream && address != 0xffffffffu) {
            std::cout << "bus_stream generation=0x" << std::hex
                      << std::setw(8) << std::setfill('0') << generation
                      << " cpu=" << std::dec << entryCpu
                      << " address=0x" << std::hex << std::setw(8)
                      << address
                      << " raw_payload=0x" << std::setw(8) << writeData
                      << " control=0x" << std::setw(8) << control
                      << " cycles=0x" << std::setw(8) << cycles
                      << " response=0x" << std::setw(8) << responseData
                      << " response_valid=" << std::dec
                      << (responseValid ? 1 : 0)
                      << std::setfill(' ') << "\n";
        }
        const bool triggerMatched =
            !triggered && entryCpu == triggerCpu &&
            ((haveTriggerAddress && address == triggerAddress) ||
             (haveTriggerWriteBelow && (control & 1u) == 0 &&
              address < triggerWriteBelow));
        if (triggerMatched) {
            triggered = true;
            std::cout << "pc_stream_trigger generation=0x" << std::hex
                      << std::setw(8) << std::setfill('0') << generation
                      << " cpu=" << std::dec << entryCpu
                      << " address=0x" << std::hex << std::setw(8)
                      << address
                      << " raw_payload=0x" << std::setw(8) << writeData
                      << " control=0x" << std::setw(8) << control
                      << " cycles=0x" << std::setw(8) << cycles
                      << std::dec << std::setfill(' ')
                      << "\n";
            for (const auto& prior : preTriggerPcs) {
                std::cout << "pc_stream generation=0x" << std::hex
                          << std::setw(8) << std::setfill('0')
                          << prior.generation
                          << " cpu=" << ((prior.control & 8u) ? 9 : 7)
                          << " pc=0x" << std::setw(8) << prior.writeData
                          << " cycles=0x" << std::setw(8) << prior.cycles
                          << std::dec << std::setfill(' ') << "\n";
            }
            preTriggerPcs.clear();
            std::cout << std::flush;
        }
        if (pcStream && address == 0xffffffffu) {
            if (triggered) {
                std::cout << "pc_stream generation=0x" << std::hex
                          << std::setw(8) << std::setfill('0') << generation
                          << " cpu=" << entryCpu
                          << " pc=0x" << std::setw(8) << writeData
                          << " cycles=0x" << std::setw(8) << cycles
                          << std::dec << std::setfill(' ') << "\n";
                if (haveTrigger && ++postTriggerPcs >= postPcCount)
                    break;
            } else {
                preTriggerPcs.push_back(entry);
                if (preTriggerPcs.size() > prePcCount)
                    preTriggerPcs.pop_front();
            }
        }
        if (prefix.size() < 64)
            prefix.push_back(entry);
        const auto region = static_cast<unsigned>(address >> 24);
        if (!sawRegion[region]) {
            sawRegion[region] = true;
            firstInRegion[region] = entry;
        }
        if (suspicious.empty() && region == 0x01) {
            suspicious.assign(recent.begin(), recent.end());
            suspicious.push_back(entry);
            suspiciousAfter = 64;
        } else if (suspiciousAfter) {
            suspicious.push_back(entry);
            --suspiciousAfter;
        }
        recent.push_back(entry);
        if (recent.size() > 32) recent.pop_front();
        ++regions[region];
        // A trigger capture may observe millions of unique runaway addresses
        // before the interesting event. Keep that diagnostic memory-bounded;
        // exact address histograms are useful only once the trigger fires.
        if (!haveTrigger || triggered) ++addresses[address];
        ++directions[(control & 1u) ? 0 : 1];
        ++widths[(control >> 1) & 3u];
        const unsigned cpu = (control & 8u) ? 0 : 1;
        ++cpus[cpu];
        if (address == 0xffffffffu) ++timingPcs[cpu][writeData];
        ++samples;
    }
    const auto end = std::chrono::steady_clock::now();
    const double seconds = std::chrono::duration<double>(end - start).count();
    const std::uint32_t generations = last - first;

    std::vector<unsigned> order(256);
    for (unsigned index = 0; index < order.size(); ++index) order[index] = index;
    std::sort(order.begin(), order.end(), [&](unsigned a, unsigned b) {
        return regions[a] > regions[b];
    });
    std::cout << "samples=" << samples << " generation_delta=" << generations
              << " seconds=" << std::fixed << std::setprecision(3) << seconds
              << " transactions_per_second="
              << static_cast<std::uint64_t>(generations / seconds) << "\n";
    if (haveMatchAddress) {
        std::cout << std::hex << std::setfill('0')
                  << "match_address=0x" << std::setw(8) << matchAddress
                  << std::dec << std::setfill(' ')
                  << " matches=" << samples
                  << " response_valid_matches=" << validMatchedResponses
                  << "\n";
    }
    std::cout << "arm9=" << cpus[0] << " arm7=" << cpus[1]
              << " reads=" << directions[0] << " writes=" << directions[1]
              << " access8=" << widths[0] << " access16=" << widths[1]
              << " access32=" << widths[2] << " access_other=" << widths[3]
              << "\n";
    std::cout << std::hex << std::setfill('0')
              << "first_address=0x" << std::setw(8) << firstAddress
              << " first_control=0x" << std::setw(8) << firstControl
              << " first_cycles=0x" << std::setw(8) << firstCycles
              << " last_address=0x" << std::setw(8) << lastAddress
              << " last_control=0x" << std::setw(8) << lastControl
              << " last_cycles=0x" << std::setw(8) << lastCycles
              << std::dec << std::setfill(' ') << "\n";
    std::cout << "first_samples:\n";
    for (const auto& entry : prefix) {
        std::cout << "  generation=0x" << std::hex << std::setw(8)
                  << std::setfill('0') << entry.generation
                  << " address=0x" << std::setw(8) << entry.address
                  << " write_data=0x" << std::setw(8) << entry.writeData
                  << " control=0x" << std::setw(8) << entry.control
                  << " cycles=0x" << std::setw(8) << entry.cycles
                  << std::dec << std::setfill(' ') << "\n";
    }
    if (!suspicious.empty()) {
        std::cout << "first_01_region_window:\n";
        for (const auto& entry : suspicious) {
            std::cout << "  generation=0x" << std::hex << std::setw(8)
                      << std::setfill('0') << entry.generation
                      << " address=0x" << std::setw(8) << entry.address
                      << " write_data=0x" << std::setw(8) << entry.writeData
                      << " control=0x" << std::setw(8) << entry.control
                      << " cycles=0x" << std::setw(8) << entry.cycles
                      << std::dec << std::setfill(' ') << "\n";
        }
    }
    std::cout << "address_regions:\n";
    for (unsigned index : order) {
        if (!regions[index]) break;
        const auto& firstRegion = firstInRegion[index];
        std::cout << "  0x" << std::hex << std::setw(2) << std::setfill('0')
                  << index << "xxxxxx" << std::dec << std::setfill(' ')
                  << " samples=" << regions[index]
                  << " percent=" << std::setprecision(2)
                  << (100.0 * regions[index] / samples)
                  << " first_generation=0x" << std::hex
                  << firstRegion.generation
                  << " first_address=0x" << std::setw(8)
                  << std::setfill('0') << firstRegion.address
                  << " first_control=0x" << std::setw(8)
                  << firstRegion.control << std::dec << std::setfill(' ')
                  << "\n";
    }
    std::vector<std::pair<std::uint32_t, std::uint64_t>> exact(
        addresses.begin(), addresses.end());
    std::sort(exact.begin(), exact.end(), [](const auto& a, const auto& b) {
        return a.second > b.second ||
            (a.second == b.second && a.first < b.first);
    });
    std::cout << "top_addresses:\n";
    const auto shown = std::min<std::size_t>(exact.size(), 16);
    for (std::size_t index = 0; index < shown; ++index) {
        std::cout << "  0x" << std::hex << std::setw(8)
                  << std::setfill('0') << exact[index].first
                  << std::dec << std::setfill(' ')
                  << " samples=" << exact[index].second
                  << " percent=" << std::setprecision(2)
                  << (100.0 * exact[index].second / samples) << "\n";
    }
    std::cout << "timing_pc_histogram:\n";
    for (unsigned cpu = 0; cpu < timingPcs.size(); ++cpu) {
        std::vector<std::pair<std::uint32_t, std::uint64_t>> pcs(
            timingPcs[cpu].begin(), timingPcs[cpu].end());
        std::sort(pcs.begin(), pcs.end(), [](const auto& a, const auto& b) {
            return a.second > b.second ||
                (a.second == b.second && a.first < b.first);
        });
        const auto pcSamples = cpus[cpu];
        const auto pcShown = std::min<std::size_t>(pcs.size(), 16);
        for (std::size_t index = 0; index < pcShown; ++index) {
            std::cout << "  arm" << (cpu ? 7 : 9)
                      << " pc=0x" << std::hex << std::setw(8)
                      << std::setfill('0') << pcs[index].first
                      << std::dec << std::setfill(' ')
                      << " samples=" << pcs[index].second
                      << " percent=" << std::setprecision(2)
                      << (pcSamples
                          ? 100.0 * pcs[index].second / pcSamples : 0.0)
                      << "\n";
        }
    }
    munmap(mapping, pageSize);
    return samples ? 0 : 1;
} catch (const std::exception& error) {
    std::cerr << "nds_hps_oracle_sampler: " << error.what() << "\n";
    return 1;
}

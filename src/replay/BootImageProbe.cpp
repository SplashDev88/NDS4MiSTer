#include "melonds/MelonDsBackend.h"
#include "replay/StandaloneBoot.h"

#include <cstring>
#include <iomanip>
#include <iostream>
#include <fstream>
#include <stdexcept>
#include <string>

int main(int argc, char** argv) try {
    if (argc != 2 && argc != 3) {
        std::cerr << "usage: nds_boot_image_probe rom [main-ram-dump.bin]\n";
        return 2;
    }
    nds4mister::MelonDsBackend backend;
    std::string error;
    if (!backend.load_rom(argv[1], error)) throw std::runtime_error(error);
    nds4mister::DirectBootImage image;
    if (!backend.export_direct_boot_image(image, error))
        throw std::runtime_error(error);
    if (image.main_ram.size() != nds4mister::kStandaloneMainRamBytes)
        throw std::runtime_error("wrong main RAM image size");
    if (image.shared_wram.size() != nds4mister::kStandaloneSharedWramBytes ||
        image.arm7_wram.size() != nds4mister::kStandaloneArm7WramBytes ||
        image.wramcnt != 3)
        throw std::runtime_error("wrong direct-boot WRAM image or mapping");
    const auto checkEntry = [&](std::uint32_t entry, const char* cpu) {
        if ((entry & 0xff000000u) != 0x02000000u)
            throw std::runtime_error(std::string(cpu) +
                                     " entry is outside DS main RAM");
        std::uint32_t opcode = 0;
        std::memcpy(&opcode, image.main_ram.data() + (entry & 0x003fffffu),
                    sizeof(opcode));
        if (opcode == 0)
            throw std::runtime_error(std::string(cpu) +
                                     " entry contains a zero opcode");
        return opcode;
    };
    // Optional raw main-RAM dump for the lockstep cosim. Feed it through
    // tools/dump_boot_image_hex.py to get the $readmemh form the testbench
    // loads with +mainimage=<path>, so the RTL side executes the real program
    // instead of the two-instruction shim.
    if (argc == 3) {
        std::ofstream dump(argv[2], std::ios::binary | std::ios::trunc);
        if (!dump)
            throw std::runtime_error("cannot open main RAM dump output");
        dump.write(reinterpret_cast<const char*>(image.main_ram.data()),
                   static_cast<std::streamsize>(image.main_ram.size()));
        if (!dump)
            throw std::runtime_error("failed writing main RAM dump");
        std::cerr << "main_ram_dump=" << argv[2]
                  << " bytes=" << image.main_ram.size()
                  << " arm9_entry=0x" << std::hex << image.arm9_entry
                  << std::dec << "\n";
    }
    const auto arm9Opcode = checkEntry(image.arm9_entry, "ARM9");
    const auto arm7Opcode = checkEntry(image.arm7_entry, "ARM7");

    nds4mister::StandaloneBootDescriptor descriptor;
    descriptor.arm9_dtcm_irq_vector = image.arm9_dtcm_irq_vector;
    descriptor.arm9_trace_trigger = image.arm9_entry;
    descriptor.arm9_entry = image.arm9_entry;
    descriptor.arm7_entry = image.arm7_entry;
    descriptor.seal(1);
    const auto expectedDescriptorCrc = descriptor.descriptor_crc32;
    descriptor.descriptor_crc32 = 0;
    if (nds4mister::boot_crc32(&descriptor, 60) != expectedDescriptorCrc)
        throw std::runtime_error("descriptor CRC does not reproduce");
    descriptor.descriptor_crc32 = expectedDescriptorCrc;

    // Prove that replacing melonDS's private backing preserves direct-boot
    // WRAMCNT=3 semantics and exposes the same bytes to the external owner.
    std::vector<std::uint8_t> shared = image.shared_wram;
    std::vector<std::uint8_t> arm7 = image.arm7_wram;
    if (!backend.attach_external_wram(
            shared.data(), shared.size(), arm7.data(), arm7.size(), error))
        throw std::runtime_error(error);
    if (!backend.bus_write(false, 2, 0x03001234u, 0x89abcdefu) ||
        !backend.bus_write(false, 2, 0x03805678u, 0x12345678u))
        throw std::runtime_error("external WRAM write failed");
    std::uint32_t sharedValue = 0, arm7Value = 0, arm9Unmapped = 1;
    if (!backend.bus_read(false, 2, 0x03001234u, sharedValue) ||
        !backend.bus_read(false, 2, 0x03805678u, arm7Value) ||
        !backend.bus_read(true, 2, 0x03001234u, arm9Unmapped) ||
        sharedValue != 0x89abcdefu || arm7Value != 0x12345678u ||
        arm9Unmapped != 0)
        throw std::runtime_error("external WRAM mapping mismatch");

    std::cout << std::hex << std::setfill('0')
              << "arm9_entry=0x" << std::setw(8) << image.arm9_entry
              << " arm9_opcode=0x" << std::setw(8) << arm9Opcode
              << " arm7_entry=0x" << std::setw(8) << image.arm7_entry
              << " arm7_opcode=0x" << std::setw(8) << arm7Opcode
              << " arm9_dtcm_irq_vector=0x" << std::setw(8)
              << image.arm9_dtcm_irq_vector
              << " main_ram_crc32=0x" << std::setw(8)
              << nds4mister::boot_crc32(
                     image.main_ram.data(), image.main_ram.size())
              << " arm9_trace_trigger=0x" << std::setw(8)
              << descriptor.arm9_trace_trigger
              << " descriptor_crc32=0x" << std::setw(8)
              << descriptor.descriptor_crc32 << "\n";
    return 0;
} catch (const std::exception& error) {
    std::cerr << "nds_boot_image_probe: " << error.what() << "\n";
    return 1;
}

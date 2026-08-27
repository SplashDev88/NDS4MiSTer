#include "melonds/MelonDsBackend.h"

#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

namespace {
struct FrameProbe {
    unsigned lines = 0;
    unsigned frames = 0;
    static void receive(melonDS::u32, melonDS::u16 line,
        const melonDS::u32*, const melonDS::u32*, void* userdata) {
        auto& self = *static_cast<FrameProbe*>(userdata);
        if (line < 192) ++self.lines;
        if (line == 191) ++self.frames;
    }
};
}

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "usage: nds_external_timing_test rom\n";
        return 2;
    }
    nds4mister::MelonDsBackend backend;
    std::string error;
    if (!backend.load_rom(argv[1], error)) {
        std::cerr << error << "\n";
        return 1;
    }
    nds4mister::DirectBootImage image;
    if (!backend.export_direct_boot_image(image, error) ||
        !backend.attach_external_main_ram(image.main_ram.data(),
                                          image.main_ram.size(), error)) {
        std::cerr << error << "\n";
        return 1;
    }
    image.main_ram[0x1234] = 0x78;
    image.main_ram[0x1235] = 0x56;
    image.main_ram[0x1236] = 0x34;
    image.main_ram[0x1237] = 0x12;
    std::uint32_t sharedRead = 0;
    if (!backend.bus_read(true, 2, 0x02001234, sharedRead) ||
        sharedRead != 0x12345678u) {
        std::cerr << "external main RAM read mismatch\n";
        return 1;
    }
    if (!backend.bus_write(false, 1, 0x02001238, 0xa55au) ||
        image.main_ram[0x1238] != 0x5a || image.main_ram[0x1239] != 0xa5) {
        std::cerr << "external main RAM write mismatch\n";
        return 1;
    }
    // Prove the exact responder-side input hop used by the hybrid core.
    // MiSTer input arbitration produces the DS active-low 12-bit mask; both
    // CPUs must observe its low ten keys at KEYINPUT, while ARM7 observes
    // X/Y at EXTKEYIN. This catches a frontend mask that logs correctly but
    // never reaches the values returned to the FPGA CPUs.
    std::uint32_t arm9Keys = 0, arm7Keys = 0, arm7ExtendedKeys = 0;
    backend.set_key_mask(0x0fffu);
    if (!backend.bus_read(true, 1, 0x04000130u, arm9Keys) ||
        !backend.bus_read(false, 1, 0x04000130u, arm7Keys) ||
        !backend.bus_read(false, 1, 0x04000136u, arm7ExtendedKeys) ||
        arm9Keys != 0x03ffu || arm7Keys != 0x03ffu ||
        arm7ExtendedKeys != 0x007fu) {
        std::cerr << "released KEYINPUT/EXTKEYIN mismatch: "
                  << std::hex << arm9Keys << " " << arm7Keys << " "
                  << arm7ExtendedKeys << std::dec << "\n";
        return 1;
    }
    backend.set_key_mask(0x0feeu);
    if (!backend.bus_read(true, 1, 0x04000130u, arm9Keys) ||
        !backend.bus_read(false, 1, 0x04000130u, arm7Keys) ||
        arm9Keys != 0x03eeu || arm7Keys != 0x03eeu) {
        std::cerr << "pressed KEYINPUT mismatch: "
                  << std::hex << arm9Keys << " " << arm7Keys
                  << std::dec << "\n";
        return 1;
    }
    backend.set_key_mask(0x03ffu);
    if (!backend.bus_read(false, 1, 0x04000136u, arm7ExtendedKeys) ||
        arm7ExtendedKeys != 0x007cu) {
        std::cerr << "pressed EXTKEYIN mismatch: "
                  << std::hex << arm7ExtendedKeys << std::dec << "\n";
        return 1;
    }
    backend.set_key_mask(0x0fffu);
    const std::uint64_t initial = backend.advance_external_cycles(true, 0);
    const std::uint64_t arm9_37 = backend.advance_external_cycles(true, 37);
    const std::uint64_t arm7_11 = backend.advance_external_cycles(false, 11);
    const std::uint64_t arm7_51 = backend.advance_external_cycles(false, 40);
    const std::uint64_t arm9_51 = backend.advance_external_cycles(true, 14);
    if (initial != 0 || arm9_37 != 0 || arm7_11 != 11 ||
        arm7_51 != 37 || arm9_51 != 51) {
        std::cerr << "external timing mismatch: " << initial << " "
                  << arm9_37 << " " << arm7_11 << " " << arm7_51 << " "
                  << arm9_51 << "\n";
        return 1;
    }
    // DIV/SQRT are ARM9-local. The ARM9 BIOS IRQ wrapper reads and restores
    // these registers even while ARM7 is behind, so completion must follow
    // ARM9's authoritative timestamp instead of the shared scheduler floor.
    backend.advance_external_cycles(true, 0);
    if (!backend.bus_write(true, 2, 0x04000290, 0u) ||
        !backend.bus_write(true, 2, 0x04000294, 0u) ||
        !backend.bus_write(true, 2, 0x04000298, 0u) ||
        !backend.bus_write(true, 2, 0x0400029c, 0u) ||
        !backend.bus_write(true, 1, 0x04000280, 0u)) {
        std::cerr << "ARM9 divider setup failed\n";
        return 1;
    }
    std::uint32_t divControl = 0;
    if (!backend.bus_read(true, 1, 0x04000280, divControl) ||
        !(divControl & 0x8000u)) {
        std::cerr << "ARM9 divider BUSY did not assert\n";
        return 1;
    }
    backend.advance_external_cycles(true, 18);
    if (!backend.bus_read(true, 1, 0x04000280, divControl) ||
        (divControl & 0x8000u) || !(divControl & 0x4000u)) {
        std::cerr << "ARM9 divider completion waited for ARM7 catch-up: "
                  << std::hex << divControl << std::dec << "\n";
        return 1;
    }
    // Cartridge command completion is local to the issuing CPU interface.
    // ARM9 must not remain in a ROMCTRL-busy polling loop merely because
    // ARM7 has not yet published another timing bucket.
    backend.advance_external_cycles(true, 0);
    if (!backend.bus_write(true, 1, 0x040001a0, 0x8000u) ||
        !backend.bus_write(true, 2, 0x040001a4, 0xa0000000u)) {
        std::cerr << "ARM9 cartridge command setup failed\n";
        return 1;
    }
    std::uint32_t romControl = 0;
    if (!backend.bus_read(true, 2, 0x040001a4, romControl) ||
        !(romControl & 0x80000000u)) {
        std::cerr << "ARM9 cartridge BUSY did not assert\n";
        return 1;
    }
    backend.advance_external_cycles(true, 64);
    if (!backend.bus_read(true, 2, 0x040001a4, romControl) ||
        (romControl & 0x80000000u)) {
        std::cerr << "ARM9 cartridge BUSY waited for ARM7 catch-up: "
                  << std::hex << romControl << std::dec << "\n";
        return 1;
    }
    // The game-card AUXSPI interface has a separate completion event for each
    // CPU. Prove that BUSY remains asserted before the exact 64-cycle deadline
    // and clears at that CPU's deadline even while the peer CPU is behind.
    if (!backend.bus_write(true, 1, 0x040001a0, 0xa000u) ||
        !backend.bus_write(true, 0, 0x040001a2, 0u)) {
        std::cerr << "ARM9 cartridge AUXSPI setup failed\n";
        return 1;
    }
    std::uint32_t cartSpiControl = 0;
    if (!backend.bus_read(true, 1, 0x040001a0, cartSpiControl) ||
        !(cartSpiControl & 0x0080u)) {
        std::cerr << "ARM9 cartridge AUXSPI BUSY did not assert\n";
        return 1;
    }
    backend.advance_external_cycles(true, 63);
    if (!backend.bus_read(true, 1, 0x040001a0, cartSpiControl) ||
        !(cartSpiControl & 0x0080u)) {
        std::cerr << "ARM9 cartridge AUXSPI completed before its deadline\n";
        return 1;
    }
    backend.advance_external_cycles(true, 1);
    if (!backend.bus_read(true, 1, 0x040001a0, cartSpiControl) ||
        (cartSpiControl & 0x0080u)) {
        std::cerr << "ARM9 cartridge AUXSPI BUSY waited for ARM7 catch-up: "
                  << std::hex << cartSpiControl << std::dec << "\n";
        return 1;
    }
    // Put ARM7 ahead of ARM9 before scheduling its transfer, so this mirrors
    // the opposite peer-lag direction and catches accidental ARM9-only fixes.
    backend.advance_external_cycles(false, 200);
    if (!backend.bus_write(false, 1, 0x040001a0, 0xa000u) ||
        !backend.bus_write(false, 0, 0x040001a2, 0u)) {
        std::cerr << "ARM7 cartridge AUXSPI setup failed\n";
        return 1;
    }
    if (!backend.bus_read(false, 1, 0x040001a0, cartSpiControl) ||
        !(cartSpiControl & 0x0080u)) {
        std::cerr << "ARM7 cartridge AUXSPI BUSY did not assert\n";
        return 1;
    }
    backend.advance_external_cycles(false, 63);
    if (!backend.bus_read(false, 1, 0x040001a0, cartSpiControl) ||
        !(cartSpiControl & 0x0080u)) {
        std::cerr << "ARM7 cartridge AUXSPI completed before its deadline\n";
        return 1;
    }
    backend.advance_external_cycles(false, 1);
    if (!backend.bus_read(false, 1, 0x040001a0, cartSpiControl) ||
        (cartSpiControl & 0x0080u)) {
        std::cerr << "ARM7 cartridge AUXSPI BUSY waited for ARM9 catch-up: "
                  << std::hex << cartSpiControl << std::dec << "\n";
        return 1;
    }
    FrameProbe frameProbe;
    backend.set_output_line_sink(&FrameProbe::receive, &frameProbe);
    if (!backend.bus_write(true, 1, 0x04000004, 1u << 3) ||
        !backend.bus_write(true, 2, 0x04000210, 1u) ||
        !backend.bus_write(true, 2, 0x04000208, 1u)) {
        std::cerr << "failed to configure ARM9 VBlank IRQ\n";
        return 1;
    }
    backend.advance_external_cycles(true, 700000);
    if (frameProbe.frames != 0) {
        std::cerr << "single CPU incorrectly advanced shared video time\n";
        return 1;
    }
    backend.advance_external_cycles(false, 700000);
    backend.set_output_line_sink(nullptr, nullptr);
    std::vector<std::int16_t> audio(4096);
    const int audioFrames = backend.read_audio(audio.data(), 2048);
    if (frameProbe.frames == 0 || frameProbe.lines < 192 ||
        audioFrames <= 0 || !backend.irq_pending(true)) {
        std::cerr << "external scheduler output mismatch: frames="
                  << frameProbe.frames << " lines=" << frameProbe.lines
                  << " audio_frames=" << audioFrames << " irq9="
                  << backend.irq_pending(true) << "\n";
        return 1;
    }
    if (!backend.bus_write(true, 2, 0x04000214, 1u) ||
        backend.irq_pending(true)) {
        std::cerr << "ARM9 VBlank IRQ did not clear through IF\n";
        return 1;
    }
    if (!backend.bus_write(false, 1, 0x04000004, 1u << 3) ||
        !backend.bus_write(false, 2, 0x04000210, 1u) ||
        !backend.bus_write(false, 2, 0x04000208, 1u) ||
        !backend.bus_write(false, 0, 0x04000301, 0x80u) ||
        !backend.external_cpu_halted(false)) {
        std::cerr << "ARM7 HALT did not assert\n";
        return 1;
    }
    backend.advance_external_cycles(true, 700000);
    backend.advance_external_cycles(false, 700000);
    if (!backend.irq_pending(false) || backend.external_cpu_halted(false)) {
        std::cerr << "ARM7 VBlank IRQ did not wake HALT\n";
        return 1;
    }
    if (!backend.bus_write(false, 2, 0x04000214, 1u) ||
        backend.irq_pending(false)) {
        std::cerr << "ARM7 VBlank IRQ did not clear through IF\n";
        return 1;
    }
    auto* ram32 = reinterpret_cast<std::uint32_t*>(image.main_ram.data());
    backend.bus_write(true, 2, 0x04000208, 0u);
    backend.bus_write(true, 2, 0x04000214, 0xffffffffu);
    for (unsigned index = 0; index < 4; ++index) {
        ram32[(0x2000 / 4) + index] = 0x11223300u + index;
        ram32[(0x3000 / 4) + index] = 0;
    }
    const bool dmaSourceWrite =
        backend.bus_write(true, 2, 0x040000b0, 0x02002000u);
    const bool dmaDestWrite =
        backend.bus_write(true, 2, 0x040000b4, 0x02003000u);
    const bool dmaControlWrite =
        backend.bus_write(true, 2, 0x040000b8, 0x84000004u);
    const bool dmaHalted = backend.external_cpu_halted(true);
    if (!dmaSourceWrite || !dmaDestWrite || !dmaControlWrite || !dmaHalted) {
        std::uint32_t sourceRead = 0, destRead = 0, controlRead = 0;
        backend.bus_read(true, 2, 0x040000b0, sourceRead);
        backend.bus_read(true, 2, 0x040000b4, destRead);
        backend.bus_read(true, 2, 0x040000b8, controlRead);
        std::cerr << "ARM9 immediate DMA did not start: src=" << std::hex
                  << sourceRead << " dst=" << destRead << " cnt="
                  << controlRead << std::dec << " halted=" << dmaHalted
                  << "\n";
        return 1;
    }
    backend.advance_external_cycles(true, 1);
    backend.advance_external_cycles(false, 1);
    for (unsigned index = 0; index < 4; ++index) {
        if (ram32[(0x3000 / 4) + index] != 0x11223300u + index) {
            std::cerr << "ARM9 external DMA copy mismatch\n";
            return 1;
        }
    }
    if (backend.external_cpu_halted(true)) {
        std::cerr << "ARM9 did not resume after external DMA\n";
        return 1;
    }
    backend.bus_write(false, 2, 0x04000214, 0xffffffffu);
    backend.bus_write(false, 2, 0x04000210, 1u << 3);
    backend.bus_write(false, 2, 0x04000208, 1u);
    if (!backend.bus_write(false, 1, 0x04000100, 0xfffeu) ||
        !backend.bus_write(false, 1, 0x04000102, 0x00c0u)) {
        std::cerr << "ARM7 timer configuration failed\n";
        return 1;
    }
    backend.advance_external_cycles(true, 4);
    backend.advance_external_cycles(false, 4);
    if (!backend.irq_pending(false)) {
        std::cerr << "ARM7 timer IRQ did not follow external cycles\n";
        return 1;
    }
    backend.bus_write(false, 2, 0x04000214, 1u << 3);
    if (backend.irq_pending(false)) {
        std::cerr << "ARM7 timer IRQ did not clear\n";
        return 1;
    }
    // ARM7 SPI events must be based on the ARM7 clock. Hybrid bus accesses
    // happen outside melonDS's normal CPU loop, so this catches a stale
    // CurCPU context that otherwise leaves the firmware polling BUSY forever.
    if (!backend.bus_write(false, 1, 0x040001c0, 0x8100u) ||
        !backend.bus_write(false, 0, 0x040001c2, 0u)) {
        std::cerr << "ARM7 SPI configuration failed\n";
        return 1;
    }
    std::uint32_t spiControl = 0;
    if (!backend.bus_read(false, 1, 0x040001c0, spiControl) ||
        !(spiControl & 0x0080u)) {
        std::cerr << "ARM7 SPI BUSY did not assert\n";
        return 1;
    }
    // SPI is an ARM7-local peripheral. Its completion must not wait for an
    // unrelated ARM9 timing bucket to reach the same global timestamp.
    backend.advance_external_cycles(false, 64);
    if (!backend.bus_read(false, 1, 0x040001c0, spiControl) ||
        (spiControl & 0x0080u)) {
        std::cerr << "ARM7 SPI BUSY waited for ARM9 catch-up: "
                  << std::hex << spiControl << std::dec << "\n";
        return 1;
    }
    std::uint32_t protectedBios = 0, executingBios = 0;
    if (!backend.bus_read(false, 2, 0x00000000u, protectedBios,
                          0x02380000u) ||
        !backend.bus_read(false, 2, 0x00000000u, executingBios,
                          0x00000004u) ||
        protectedBios != 0xffffffffu || executingBios == 0xffffffffu) {
        std::cerr << "ARM7 external BIOS execution context mismatch: "
                  << std::hex << protectedBios << " " << executingBios
                  << std::dec << "\n";
        return 1;
    }
    std::cout << "PASS: FPGA ARM9/ARM7 cycles advance melonDS system time "
              << "monotonically with correct clock scaling and peripherals "
              << "share the FPGA main-RAM image; generated_frames="
              << frameProbe.frames << " generated_audio_frames="
              << audioFrames
              << " irq_delivery=passed halt_wake=passed dma=passed"
              << " timer=passed spi=passed auxspi=passed divider=passed"
              << " bios_context=passed keyinput=passed\n";
    return 0;
}

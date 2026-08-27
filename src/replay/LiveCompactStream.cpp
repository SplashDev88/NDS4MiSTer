#include "melonds/MelonDsBackend.h"
#include <array>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <signal.h>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <sys/socket.h>
#include <netdb.h>
#include <unistd.h>

namespace {
constexpr std::size_t kPixels = 512u * 192u;
constexpr std::uint32_t kFrameMagic = 0x4643444e;

void transferAll(int fd, void* data, std::size_t bytes, bool sending) {
    auto* cursor = static_cast<std::byte*>(data);
    while (bytes) {
        const ssize_t count = sending ? send(fd, cursor, bytes, 0) : recv(fd, cursor, bytes, MSG_WAITALL);
        if (count <= 0) throw std::runtime_error(std::string(sending ? "send: " : "receive: ") +
            (count == 0 ? "connection closed" : std::strerror(errno)));
        cursor += count;
        bytes -= static_cast<std::size_t>(count);
    }
}

int connectTo(const char* host, const char* port) {
    addrinfo hints{}; hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
    addrinfo* addresses = nullptr;
    const int lookup = getaddrinfo(host, port, &hints, &addresses);
    if (lookup) throw std::runtime_error(std::string("resolve: ") + gai_strerror(lookup));
    int fd = -1;
    for (auto* address = addresses; address; address = address->ai_next) {
        fd = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (fd >= 0 && connect(fd, address->ai_addr, address->ai_addrlen) == 0) break;
        if (fd >= 0) close(fd); fd = -1;
    }
    freeaddrinfo(addresses);
    if (fd < 0) throw std::runtime_error(std::string("connect: ") + std::strerror(errno));
    return fd;
}

std::uint16_t rgb555(std::uint32_t color) {
    return static_cast<std::uint16_t>(((color >> 1) & 0x1f) |
        ((color >> 4) & 0x3e0) | ((color >> 7) & 0x7c00));
}

struct StreamCapture {
    const char* host;
    const char* port;
    int fd = -1;
    std::array<std::uint16_t, kPixels> pixels{};
    std::array<std::uint16_t, kPixels> previous{};
    std::array<std::int16_t, 2048> audio{};
    std::uint32_t audioFrames = 0;
    bool hasPrevious = false;
    std::array<bool, 192> lines{};
    std::uint32_t keyMask = 0xfff;
    std::uint64_t published = 0;
    std::uint64_t payloadBytes = 0, deltaFrames = 0;
    std::array<std::byte, sizeof(keyMask)> inputBytes{};
    std::size_t inputCount = 0;
    void receiveInput() {
        for (;;) {
            const ssize_t count = recv(fd, inputBytes.data() + inputCount,
                inputBytes.size() - inputCount, MSG_DONTWAIT);
            if (count > 0) {
                inputCount += static_cast<std::size_t>(count);
                if (inputCount == inputBytes.size()) {
                    std::memcpy(&keyMask, inputBytes.data(), sizeof(keyMask));
                    inputCount = 0;
                }
                continue;
            }
            if (count == 0) throw std::runtime_error("receive: connection closed");
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            throw std::runtime_error(std::string("receive: ") + std::strerror(errno));
        }
    }
    std::vector<std::byte> encodeDelta() const {
        std::vector<std::byte> output;
        output.reserve(sizeof(pixels) / 2);
        auto word = [&output](std::uint16_t value) {
            output.push_back(static_cast<std::byte>(value));
            output.push_back(static_cast<std::byte>(value >> 8));
        };
        std::size_t at = 0;
        while (at < kPixels) {
            if (pixels[at] == previous[at]) {
                std::size_t length = 1;
                while (length < 32768 && at + length < kPixels &&
                       pixels[at + length] == previous[at + length]) ++length;
                word(static_cast<std::uint16_t>(0x8000u | (length - 1u)));
                at += length;
            } else {
                const std::size_t start = at++;
                while (at < kPixels && at - start < 32768) {
                    if (pixels[at] == previous[at] && at + 1 < kPixels &&
                        pixels[at + 1] == previous[at + 1]) break;
                    ++at;
                }
                word(static_cast<std::uint16_t>((at - start) - 1u));
                for (std::size_t i = start; i < at; ++i) word(pixels[i]);
            }
        }
        return output;
    }
    void publish() {
        for (;;) {
            try {
                bool resync = false;
                if (fd < 0) { fd = connectTo(host, port); resync = true; }
                auto delta = (!resync && hasPrevious) ? encodeDelta() : std::vector<std::byte>{};
                const bool compressed = !delta.empty() && delta.size() < sizeof(pixels);
                std::uint32_t header[6] = {kFrameMagic, compressed ? 1u : 0u,
                    static_cast<std::uint32_t>(compressed ? delta.size() : sizeof(pixels)),
                    static_cast<std::uint32_t>(kPixels), audioFrames, 0};
                transferAll(fd, header, sizeof(header), true);
                if (compressed) transferAll(fd, delta.data(), delta.size(), true);
                else transferAll(fd, pixels.data(), sizeof(pixels), true);
                if (audioFrames) transferAll(fd, audio.data(), audioFrames * 4u, true);
                receiveInput();
                payloadBytes += header[2];
                if (compressed) ++deltaFrames;
                previous = pixels; hasPrevious = true;
                return;
            } catch (const std::exception& error) {
                if (fd >= 0) close(fd);
                fd = -1; inputCount = 0;
                std::cerr << "stream disconnected (" << error.what() << "); reconnecting\n";
                std::this_thread::sleep_for(std::chrono::milliseconds(250));
            }
        }
    }
    static void receive(melonDS::u32, melonDS::u16 line, const melonDS::u32* top,
        const melonDS::u32* bottom, void* userdata) {
        auto& self = *static_cast<StreamCapture*>(userdata);
        if (line >= 192) return;
        self.lines[line] = true;
        for (unsigned x = 0; x < 256; ++x) {
            self.pixels[line * 512u + x] = rgb555(top[x]);
            self.pixels[line * 512u + 256u + x] = rgb555(bottom[x]);
        }
        if (line != 191) return;
        for (bool present : self.lines) if (!present) throw std::runtime_error("incomplete rendered frame");
        self.publish();
        self.lines.fill(false); ++self.published;
    }
};
}

int main(int argc, char** argv) try {
    if (argc < 3 || argc > 5) {
        std::cerr << "usage: nds_live_compact_stream rom mister-host [frames,0=forever] [port]\n";
        return 2;
    }
    const std::uint64_t limit = argc >= 4 ? std::strtoull(argv[3], nullptr, 10) : 0;
    signal(SIGPIPE, SIG_IGN);
    StreamCapture capture{argv[2], argc >= 5 ? argv[4] : "5364"};
    nds4mister::MelonDsBackend backend; std::string error;
    if (!backend.load_rom(argv[1], error)) throw std::runtime_error(error);
    backend.set_output_line_sink(&StreamCapture::receive, &capture);
    nds4mister::FrameTimings timings{}; std::uint64_t frames = 0;
    const auto start = std::chrono::steady_clock::now();
    auto deadline = start;
    const auto framePeriod = std::chrono::duration_cast<std::chrono::steady_clock::duration>(
        std::chrono::duration<double>(1.0 / 59.8261));
    const bool uncapped = std::getenv("NDS4MISTER_UNCAPPED") != nullptr;
    while (!limit || frames < limit) {
        backend.set_key_mask(capture.keyMask);
        if (!backend.run_frame(timings, error)) throw std::runtime_error(error);
        capture.audioFrames = static_cast<std::uint32_t>(backend.read_audio(capture.audio.data(), 1024));
        ++frames;
        if (!uncapped) {
            deadline += framePeriod;
            const auto now = std::chrono::steady_clock::now();
            if (now < deadline) std::this_thread::sleep_until(deadline);
            else if (now - deadline > framePeriod * 4) deadline = now;
        }
    }
    const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    if (capture.fd >= 0) close(capture.fd);
    std::cout << "frames: " << frames << "\npublished: " << capture.published
              << "\ndelta_frames: " << capture.deltaFrames
              << "\npayload_bytes: " << capture.payloadBytes
              << "\naverage_payload: " << (capture.published ? capture.payloadBytes / capture.published : 0)
              << "\nseconds: " << seconds << "\neffective_fps: " << (seconds ? frames / seconds : 0) << "\n";
} catch (const std::exception& error) {
    std::cerr << "nds_live_compact_stream: " << error.what() << "\n";
    return 1;
}

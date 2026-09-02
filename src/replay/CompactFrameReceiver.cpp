#include "replay/LayerRecord.h"
#include <array>
#include <chrono>
#include <condition_variable>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <sys/mman.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <vector>
#if defined(__linux__)
#include <linux/input.h>
#endif

namespace {
constexpr off_t kDdrPhysicalBase = 0x30000000;
constexpr std::size_t kFrameBytes = 512u * 192u * 2u;
constexpr std::size_t kMapBytes = 3u * nds4mister::kLayerSlotBytes;
constexpr std::uint32_t kFrameMagic = 0x4643444e;

void transferAll(int fd, void* data, std::size_t bytes, bool sending) {
    auto* cursor = static_cast<std::byte*>(data);
    while (bytes) {
        const ssize_t count = sending ? send(fd, cursor, bytes, 0) : recv(fd, cursor, bytes, MSG_WAITALL);
        if (count <= 0) throw std::runtime_error(count == 0 ? "connection closed" : std::strerror(errno));
        cursor += count; bytes -= static_cast<std::size_t>(count);
    }
}

class Input {
public:
    explicit Input(volatile const std::uint64_t* fpgaInput) : fpgaInput_(fpgaInput) {
#if defined(__linux__)
        const char* path = std::getenv("NDS4MISTER_INPUT");
        path_ = path ? path : "/dev/input/event0";
        openDevice();
#endif
    }
    ~Input() { if (fd_ >= 0) close(fd_); }
    std::uint32_t poll() {
#if defined(__linux__)
        if (fd_ < 0 && std::chrono::steady_clock::now() >= nextOpen_) openDevice();
        input_event event{};
        ssize_t count = -1;
        while (fd_ >= 0 && (count = read(fd_, &event, sizeof(event))) == sizeof(event)) {
            std::cout << "input event: type=" << event.type << " code=" << event.code
                      << " value=" << event.value << "\n" << std::flush;
            if (event.type == EV_KEY) set(event.code, event.value != 0);
            else if (event.type == EV_ABS) axis(event.code, event.value);
        }
        if (fd_ >= 0 && count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            std::cout << "input device lost: " << path_ << " error=" << std::strerror(errno)
                      << "\n" << std::flush;
            close(fd_);
            fd_ = -1;
            mask_ = 0xfff;
            nextOpen_ = std::chrono::steady_clock::now() + std::chrono::seconds(1);
        }
#endif
        if (fpgaInput_) {
            const std::uint64_t word = *fpgaInput_;
            if (static_cast<std::uint32_t>(word >> 32) == 0x4a53444e) {
                const std::uint32_t joy = static_cast<std::uint32_t>(word);
                std::uint32_t mapped = 0xfff;
                auto map = [&](unsigned joyBit, unsigned dsBit) {
                    if (joy & (1u << joyBit)) mapped &= ~(1u << dsBit);
                };
                map(0, 4); map(1, 5); map(2, 7); map(3, 6);
                map(4, 0); map(5, 1); map(6, 2); map(7, 3);
                map(8, 8); map(9, 9); map(10, 10); map(11, 11);
                return mapped;
            }
        }
        return mask_;
    }
private:
#if defined(__linux__)
    void openDevice() {
        fd_ = open(path_.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        std::cout << "input device: " << path_ << " fd=" << fd_;
        if (fd_ < 0) {
            std::cout << " error=" << std::strerror(errno);
            nextOpen_ = std::chrono::steady_clock::now() + std::chrono::seconds(1);
        }
        std::cout << "\n" << std::flush;
    }
#endif
    void button(unsigned bit, bool pressed) { if (pressed) mask_ &= ~(1u << bit); else mask_ |= 1u << bit; }
    void set(unsigned code, bool pressed) {
#if defined(__linux__)
        switch (code) {
        case KEY_X: case BTN_EAST: button(0, pressed); break;
        case KEY_Z: case BTN_SOUTH: button(1, pressed); break;
        case KEY_RIGHTSHIFT: case BTN_SELECT: button(2, pressed); break;
        case KEY_ENTER: case BTN_START: button(3, pressed); break;
        case KEY_RIGHT: case BTN_DPAD_RIGHT: button(4, pressed); break;
        case KEY_LEFT: case BTN_DPAD_LEFT: button(5, pressed); break;
        case KEY_UP: case BTN_DPAD_UP: button(6, pressed); break;
        case KEY_DOWN: case BTN_DPAD_DOWN: button(7, pressed); break;
        case KEY_S: case BTN_TR: button(8, pressed); break;
        case KEY_A: case BTN_TL: button(9, pressed); break;
        case KEY_W: case BTN_NORTH: button(10, pressed); break;
        case KEY_Q: case BTN_WEST: button(11, pressed); break;
        }
#else
        (void)code; (void)pressed;
#endif
    }
    void axis(unsigned code, int value) {
#if defined(__linux__)
        if (code == ABS_X || code == ABS_HAT0X) { button(4, value > 12000); button(5, value < -12000); }
        if (code == ABS_Y || code == ABS_HAT0Y) { button(7, value > 12000); button(6, value < -12000); }
#else
        (void)code; (void)value;
#endif
    }
    int fd_ = -1; std::uint32_t mask_ = 0xfff;
#if defined(__linux__)
    std::string path_;
    std::chrono::steady_clock::time_point nextOpen_{};
#endif
    volatile const std::uint64_t* fpgaInput_ = nullptr;
};

class Publisher {
public:
    Publisher() {
        fd_ = open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
        if (fd_ < 0) throw std::runtime_error(std::string("open /dev/mem: ") + std::strerror(errno));
        map_ = mmap(nullptr, kMapBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, kDdrPhysicalBase);
        if (map_ == MAP_FAILED) throw std::runtime_error(std::string("map DDR: ") + std::strerror(errno));
    }
    ~Publisher() { if (map_ != MAP_FAILED) munmap(map_, kMapBytes); if (fd_ >= 0) close(fd_); }
    volatile const std::uint64_t* fpgaInput() const {
        return reinterpret_cast<volatile const std::uint64_t*>(
            static_cast<const std::byte*>(map_) + sizeof(nds4mister::LayerPublication));
    }
    void publish(const std::byte* frame, const std::int16_t* audio, std::uint32_t audioFrames,
        std::uint64_t sequence) {
        auto* header = static_cast<nds4mister::LayerPublication*>(map_);
        generation_ += 2; activeSlot_ ^= 1u;
        nds4mister::LayerPublication next{nds4mister::kLayerPublicationMagic, 2,
            sizeof(nds4mister::LayerPublication), generation_ | 1u, activeSlot_, kFrameBytes,
            2, 512u * 192u, sequence, generation_ | 1u, audioFrames};
        std::memcpy(header, &next, sizeof(next)); __sync_synchronize();
        auto* destination = static_cast<std::byte*>(map_) + nds4mister::kLayerSlotBytes * (activeSlot_ + 1u);
        std::memcpy(destination, frame, kFrameBytes); __sync_synchronize();
        if (audioFrames) std::memcpy(destination + kFrameBytes, audio, audioFrames * 4u);
        __sync_synchronize();
        next.generation = generation_; next.generationCheck = generation_;
        std::memcpy(header, &next, sizeof(next)); __sync_synchronize();
    }
private:
    int fd_ = -1; void* map_ = MAP_FAILED; std::uint64_t generation_ = 0; std::uint32_t activeSlot_ = 1;
};

struct BufferedFrame {
    std::array<std::byte, kFrameBytes> pixels{};
    std::vector<std::int16_t> audio;
    std::uint32_t audioFrames = 0;
};

class PlaybackQueue {
public:
    PlaybackQueue(Publisher& publisher, unsigned prebufferFrames,
        const char* snapshotPath, const char* audioSnapshotPath,
        std::uint64_t& sequence)
        : publisher_(publisher), prebufferFrames_(prebufferFrames),
          maximumFrames_(prebufferFrames + 4), snapshotPath_(snapshotPath),
          audioSnapshotPath_(audioSnapshotPath), sequence_(sequence),
          worker_(&PlaybackQueue::run, this) {}

    ~PlaybackQueue() { stop(); }

    void push(BufferedFrame frame) {
        std::unique_lock<std::mutex> lock(mutex_);
        space_.wait(lock, [&] { return stopped_ || frames_.size() < maximumFrames_; });
        if (stopped_) throw std::runtime_error("playback queue stopped");
        frames_.push_back(std::move(frame));
        ready_.notify_one();
    }

    std::size_t depth() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return frames_.size();
    }

    void stop() {
        bool notify = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (!stopped_) {
                stopped_ = true;
                notify = true;
            }
        }
        if (notify) {
            ready_.notify_all();
            space_.notify_all();
        }
        if (worker_.joinable()) worker_.join();
    }

private:
    void run() noexcept {
        try {
            std::unique_lock<std::mutex> lock(mutex_);
            ready_.wait(lock, [&] { return stopped_ || frames_.size() >= prebufferFrames_; });
            if (stopped_) return;
            auto deadline = std::chrono::steady_clock::now();
            const auto period = std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                std::chrono::duration<double>(1.0 / 59.8261));
            for (;;) {
                if (frames_.empty()) {
                    ready_.wait(lock, [&] { return stopped_ || !frames_.empty(); });
                    if (stopped_) return;
                    ++underruns_;
                    deadline = std::chrono::steady_clock::now();
                }
                BufferedFrame frame = std::move(frames_.front());
                frames_.pop_front();
                space_.notify_one();
                lock.unlock();

                publisher_.publish(frame.pixels.data(), frame.audio.data(),
                    frame.audioFrames, ++sequence_);
                if (snapshotPath_ && (sequence_ == 1 || (sequence_ % 300) == 0)) {
                    std::ofstream snapshot(snapshotPath_, std::ios::binary | std::ios::trunc);
                    snapshot.write(reinterpret_cast<const char*>(frame.pixels.data()), frame.pixels.size());
                }
                if (audioSnapshotPath_ && !frame.audio.empty() &&
                    (sequence_ == 1 || (sequence_ % 300) == 0)) {
                    std::ofstream snapshot(audioSnapshotPath_, std::ios::binary | std::ios::trunc);
                    snapshot.write(reinterpret_cast<const char*>(frame.audio.data()),
                        frame.audio.size() * sizeof(frame.audio[0]));
                }
                if ((sequence_ % 300) == 0)
                    std::cout << "published frames: " << sequence_
                        << " jitter-buffer underruns: " << underruns_ << "\n" << std::flush;

                deadline += period;
                const auto now = std::chrono::steady_clock::now();
                if (deadline < now) deadline = now + period;
                std::this_thread::sleep_until(deadline);
                lock.lock();
                if (stopped_) return;
            }
        } catch (const std::exception& error) {
            std::cerr << "playback queue: " << error.what() << "\n" << std::flush;
            std::lock_guard<std::mutex> lock(mutex_);
            stopped_ = true;
            space_.notify_all();
        }
    }

    Publisher& publisher_;
    const unsigned prebufferFrames_;
    const std::size_t maximumFrames_;
    const char* snapshotPath_;
    const char* audioSnapshotPath_;
    std::uint64_t& sequence_;
    mutable std::mutex mutex_;
    std::condition_variable ready_, space_;
    std::deque<BufferedFrame> frames_;
    bool stopped_ = false;
    std::uint64_t underruns_ = 0;
    std::thread worker_;
};

int listenSocket(unsigned port) {
    const int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) throw std::runtime_error("socket");
    int reuse = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(static_cast<std::uint16_t>(port));
    if (bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) || listen(fd, 1))
        throw std::runtime_error(std::string("listen: ") + std::strerror(errno));
    return fd;
}
}

int main(int argc, char** argv) try {
    const unsigned port = argc >= 2 ? std::strtoul(argv[1], nullptr, 10) : 5364;
    const int listener = listenSocket(port);
    std::cout << "listening for compact NDS frames on port " << port << "\n" << std::flush;
    Publisher publisher; Input input(publisher.fpgaInput()); std::array<std::byte, kFrameBytes> frame{};
    std::vector<std::byte> payload;
    std::vector<std::int16_t> audio;
    const char* snapshotPath = std::getenv("NDS4MISTER_SNAPSHOT");
    const char* audioSnapshotPath = std::getenv("NDS4MISTER_AUDIO_SNAPSHOT");
    const bool scriptedInput = std::getenv("NDS4MISTER_INPUT_TEST") != nullptr;
    const char* jitterText = std::getenv("NDS4MISTER_JITTER_FRAMES");
    const unsigned jitterFrames = jitterText ? std::strtoul(jitterText, nullptr, 10) : 0;
    if (jitterFrames > 16) throw std::runtime_error("NDS4MISTER_JITTER_FRAMES must be 0..16");
    std::cout << "jitter prebuffer frames: " << jitterFrames << "\n" << std::flush;
    std::uint64_t sequence = 0;
    std::uint64_t receivedSequence = 0;
    std::uint32_t lastKeys = 0xfff;
    auto lastArrival = std::chrono::steady_clock::now();
    double arrivalGapSumMs = 0.0;
    double arrivalGapMaxMs = 0.0;
    double arrivalExcessMaxMs = 0.0;
    std::uint32_t arrivalGapCount = 0;
    std::uint32_t underrunRiskCount = 0;
    std::uint32_t previousAudioFrames = 0;
    for (;;) {
        const int client = accept(listener, nullptr, nullptr);
        if (client < 0) throw std::runtime_error("accept");
        std::cout << "producer connected\n" << std::flush;
        std::unique_ptr<PlaybackQueue> playback;
        if (jitterFrames)
            playback = std::make_unique<PlaybackQueue>(publisher, jitterFrames,
                snapshotPath, audioSnapshotPath, sequence);
        lastArrival = std::chrono::steady_clock::now();
        previousAudioFrames = 0;
        try {
            for (;;) {
                std::uint32_t header[6]{};
                transferAll(client, header, sizeof(header), false);
                if (header[0] != kFrameMagic || header[2] > kFrameBytes ||
                    header[3] != kFrameBytes / 2 || header[4] > 1024)
                    throw std::runtime_error("invalid compact frame header");
                payload.resize(header[2]);
                transferAll(client, payload.data(), payload.size(), false);
                if (header[1] == 0) {
                    if (payload.size() != frame.size()) throw std::runtime_error("invalid raw frame size");
                    std::memcpy(frame.data(), payload.data(), frame.size());
                } else if (header[1] == 1) {
                    auto* pixels = reinterpret_cast<std::uint16_t*>(frame.data());
                    std::size_t source = 0, destination = 0;
                    auto readWord = [&]() {
                        if (source + 2 > payload.size()) throw std::runtime_error("truncated delta frame");
                        const auto value = static_cast<std::uint16_t>(payload[source]) |
                            (static_cast<std::uint16_t>(payload[source + 1]) << 8);
                        source += 2;
                        return value;
                    };
                    while (source < payload.size() && destination < kFrameBytes / 2) {
                        const std::uint16_t token = readWord();
                        const std::size_t length = (token & 0x7fffu) + 1u;
                        if (destination + length > kFrameBytes / 2) throw std::runtime_error("delta frame overflow");
                        if (token & 0x8000u) destination += length;
                        else for (std::size_t i = 0; i < length; ++i) pixels[destination++] = readWord();
                    }
                    if (source != payload.size() || destination != kFrameBytes / 2)
                        throw std::runtime_error("invalid delta frame length");
                } else throw std::runtime_error("unsupported compact frame encoding");
                audio.resize(header[4] * 2u);
                if (!audio.empty()) transferAll(client, audio.data(), audio.size() * sizeof(audio[0]), false);
                const auto arrival = std::chrono::steady_clock::now();
                if (previousAudioFrames) {
                    const double gapMs = std::chrono::duration<double, std::milli>(arrival - lastArrival).count();
                    arrivalGapSumMs += gapMs;
                    if (gapMs > arrivalGapMaxMs) arrivalGapMaxMs = gapMs;
                    const double bufferedMs = previousAudioFrames * (1000.0 / 48000.0);
                    if (gapMs > bufferedMs) {
                        const double excessMs = gapMs - bufferedMs;
                        if (excessMs > arrivalExcessMaxMs) arrivalExcessMaxMs = excessMs;
                        ++underrunRiskCount;
                    }
                    ++arrivalGapCount;
                }
                lastArrival = arrival;
                previousAudioFrames = header[4];
                ++receivedSequence;
                if (playback) {
                    BufferedFrame buffered;
                    buffered.pixels = frame;
                    buffered.audio = audio;
                    buffered.audioFrames = header[4];
                    playback->push(std::move(buffered));
                } else {
                    publisher.publish(frame.data(), audio.data(), header[4], ++sequence);
                }
                if (!playback && snapshotPath && (sequence == 1 || (sequence % 300) == 0)) {
                    std::ofstream snapshot(snapshotPath, std::ios::binary | std::ios::trunc);
                    snapshot.write(reinterpret_cast<const char*>(frame.data()), frame.size());
                }
                if (!playback && audioSnapshotPath && !audio.empty() &&
                    (sequence == 1 || (sequence % 300) == 0)) {
                    std::ofstream snapshot(audioSnapshotPath, std::ios::binary | std::ios::trunc);
                    snapshot.write(reinterpret_cast<const char*>(audio.data()),
                        audio.size() * sizeof(audio[0]));
                }
                std::uint32_t keys = input.poll();
                if (scriptedInput) {
                    if (receivedSequence >= 60 && receivedSequence < 66) keys &= ~(1u << 7); // Down
                    if (receivedSequence >= 120 && receivedSequence < 126) keys &= ~(1u << 0); // A
                }
                if (keys != lastKeys) {
                    std::cout << "input mask: 0x" << std::hex << keys << std::dec << "\n" << std::flush;
                    lastKeys = keys;
                }
                transferAll(client, &keys, sizeof(keys), true);
                if ((receivedSequence % 300) == 0) {
                    const double averageGapMs = arrivalGapCount ? arrivalGapSumMs / arrivalGapCount : 0.0;
                    std::cout << "received frames: " << receivedSequence
                        << " audio frames: " << header[4]
                        << " arrival gap avg/max ms: " << averageGapMs << "/" << arrivalGapMaxMs
                        << " underrun-risk count/max-excess ms: " << underrunRiskCount
                        << "/" << arrivalExcessMaxMs
                        << " queue depth: " << (playback ? playback->depth() : 0)
                        << "\n" << std::flush;
                    arrivalGapSumMs = 0.0;
                    arrivalGapMaxMs = 0.0;
                    arrivalExcessMaxMs = 0.0;
                    arrivalGapCount = 0;
                    underrunRiskCount = 0;
                }
            }
        } catch (const std::exception& error) {
            playback.reset();
            std::cout << "producer disconnected: " << error.what() << "\n" << std::flush;
            close(client);
        }
    }
} catch (const std::exception& error) {
    std::cerr << "nds_compact_receiver: " << error.what() << "\n";
    return 1;
}

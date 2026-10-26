// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "rom_layout.h"
#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <poll.h>
#include <stdexcept>
#include <string>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

// CIFS open/stat/read can sleep much longer than the host watchdog. Only this
// disposable child touches the ROM file; the SPI owner waits in short polls.
// A pipe also bounds read-ahead memory and keeps the child away from ROM/SPI MMIO.
class RomReader {
public:
  static constexpr uint64_t max_file_size = RomLayout::max_file_size;
  static constexpr uint64_t max_transfer_size = RomLayout::max_transfer_size;
  static constexpr bool validSize(uint64_t size) {
    return size >= 512 && size <= max_file_size;
  }
  static constexpr uint64_t transferSize(uint64_t size) {
    return RomLayout::transferSize(size);
  }
private:
  struct Header { uint64_t size; int error; int operation; };
  static constexpr int padding_progress = 7;
  int input = -1;
  pid_t child = -1;
  bool framed_stream = false;
  bool cache_preparing = false;
  int work_progress = -1;
  void workProgress(const Header &h) {
    if (h.error || h.size > 9900 || int(h.size) < work_progress)
      throw std::runtime_error("Invalid ROM loading progress");
    work_progress = int(h.size);
  }
  void cacheStatus(const Header &h) {
    if (h.size || h.error != 1) throw std::runtime_error("Invalid ROM cache status");
    cache_preparing = true;
  }
  std::chrono::steady_clock::time_point progressed = std::chrono::steady_clock::now();
  inline static std::vector<pid_t> retiring;
  static bool send(int fd, const void *data, size_t size) {
    const auto *p = static_cast<const char *>(data);
    while (size) {
      const auto n = write(fd, p, size);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) return false;
      p += n;
      size -= size_t(n);
    }
    return true;
  }
  [[noreturn]] static void worker(int output, pid_t parent, const std::string &path,
                                const std::string &movie_directory, bool allow_movies) {
    // Never inherit the host's graceful SIGTERM handler: this child has no
    // state to save and must also stop if the host disappears during CIFS I/O.
    signal(SIGTERM, SIG_DFL);
    signal(SIGINT, SIG_DFL);
    signal(SIGUSR1, SIG_DFL);
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != parent) _exit(1);
    // CLOEXEC alone does not release the host's flock after fork. Close every
    // inherited descriptor except the diagnostic stderr before any network
    // operation, including that lock, input devices, save, heartbeat and
    // /dev/mem. Never access inherited MMIO.
    DIR *fds = opendir("/proc/self/fd");
    if (!fds) _exit(1);
    while (auto *e = readdir(fds)) {
      char *end;
      const long fd = strtol(e->d_name, &end, 10);
      if (*end == '\0' && fd != output && fd != STDERR_FILENO && fd != dirfd(fds)) close(int(fd));
    }
    closedir(fds);
#ifdef STANDALONE_TEST
    if (test_hook) test_hook(-1, 0);
#endif
    const int rom = open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    Header h{};
    struct stat st{};
    if (rom < 0) { h.operation = 1; h.error = errno; }
    else if (fstat(rom, &st)) { h.operation = 2; h.error = errno; }
    else if (!S_ISREG(st.st_mode)) { h.operation = 3; h.error = EINVAL; }
    else if (st.st_size < 0 || !validSize(uint64_t(st.st_size))) {
      h.operation = 4; h.error = EINVAL;
    } else h.size = uint64_t(st.st_size);
    // Optional paired-kit movie preparation runs in this disposable worker.
    // Framed workers may stage bytes under reset before identity verification;
    // only their final completion permits boot. Unknown games keep the reader.
    // Only these FDs survive exec; neither save/SPI ownership nor a helper
    // process is retained during gameplay. The original path stays in Host.
    if (!h.operation && !movie_directory.empty()) {
      unsigned char header[32]{};
      if (pread(rom, header, sizeof(header), 0) == ssize_t(sizeof(header))) {
        const std::string code(reinterpret_cast<char *>(header + 12), 4);
        const char* nsmb_mode = std::getenv("NDS_NSMB_PATCH");
        const bool nsmb = (code == "A2DE" || code == "A2DP" || code == "A2DJ" || code == "A2DK") && nsmb_mode &&
            (std::strcmp(nsmb_mode, "lookup") == 0 || std::strcmp(nsmb_mode, "skip") == 0 ||
             std::strcmp(nsmb_mode, "both") == 0 || std::strcmp(nsmb_mode, "bones") == 0 ||
             std::strcmp(nsmb_mode, "lookup+bones") == 0 || std::strcmp(nsmb_mode, "skip+bones") == 0 ||
             std::strcmp(nsmb_mode, "both+bones") == 0);
        const bool portrait = ((code == "ACBE" || code == "ACBP") && header[30] == 0) ||
                              (code == "ACBJ" && header[30] <= 1);
        if ((allow_movies && portrait) || (header[30] == 0 && (nsmb || (allow_movies && (code == "BMTE" || code == "B2KJ" || code == "YQUE" ||
                               code == "AXFE" || code == "YWSE" || code == "BMTJ" ||
                               code == "YQUP" || code == "YQUJ" || code == "AXFP" ||
                               code == "AXFJ" || code == "CSNP" || code == "C5RJ" || code == "YR9E" ||
                               code == "YR9P" || code == "YR9J" || code == "YR9K"))))) {
          const auto script = movie_directory + (nsmb ? "/nsmb_stream.py" : "/stream.py");
          const auto input_arg = std::to_string(rom), output_arg = std::to_string(output);
          const auto parent_arg = std::to_string(parent);
          if (fcntl(rom, F_SETFD, 0) || fcntl(output, F_SETFD, 0)) _exit(1);
          // Capability negotiation: old paired workers ignore this, and a new
          // worker never sends framed data to an old host. Keep a diagnostic
          // opt-out for exact loader A/B checks, with no menu setting.
          if (!getenv("NDS_ROM_STREAM_PATCHES") && setenv("NDS_ROM_STREAM_PATCHES", "1", 1)) _exit(1);
          if (setenv("NDS_ROM_CACHE_STATUS", "1", 1)) _exit(1);
          if (setenv("NDS_ROM_LOAD_PROGRESS", "1", 1)) _exit(1);
          execlp("python3", "python3", "-E", "-s", "-B", script.c_str(), input_arg.c_str(),
                 output_arg.c_str(), parent_arg.c_str(), static_cast<char *>(nullptr));
          // A missing worker must not silently enable only half of a profile.
          // No cartridge data has been sent; retain the ordinary native path.
          dprintf(STDERR_FILENO, "FMV_AUTO_FALLBACK cannot start movie reader\n");
        }
      }
    }
    std::array<unsigned char, 262144> buffer;
    // Validate all omitted bytes before telling the host it may start a
    // download. The ROM header's used-size field is not evidence of padding.
    uint64_t off = RomLayout::transferLimit(h.size);
    while (!h.operation && off < h.size) {
#ifdef STANDALONE_TEST
      if (test_hook) test_hook(rom, off);
#endif
      const auto n = pread(rom, buffer.data(), std::min<uint64_t>(buffer.size(), h.size - off), off);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) { h.operation = 6; h.error = n < 0 ? errno : EIO; break; }
      if (std::any_of(buffer.begin(), buffer.begin() + n,
                      [](unsigned char byte) { return byte != 0xff; })) {
        h.operation = 5; h.error = EINVAL; break;
      }
      off += uint64_t(n);
      // Keep the no-progress timeout honest during slow padding reads without
      // granting the host permission to touch cartridge memory yet.
      const Header progress{off, 0, padding_progress};
      if (!send(output, &progress, sizeof(progress))) _exit(1);
    }
    if (!send(output, &h, sizeof(h)) || h.operation) _exit(1);
    off = 0;
    const auto transfer_size = transferSize(h.size);
    while (off < transfer_size) {
#ifdef STANDALONE_TEST
      if (test_hook) test_hook(rom, off);
#endif
      const auto n = pread(rom, buffer.data(), std::min<uint64_t>(buffer.size(), transfer_size - off), off);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0 || !send(output, buffer.data(), size_t(n))) _exit(1);
      off += uint64_t(n);
    }
    // The parent must observe completion before releasing the cartridge. This
    // also covers post-stream source validation in the optional movie worker.
    const Header complete{transfer_size, 0, 8};
    if (!send(output, &complete, sizeof(complete))) _exit(1);
    _exit(0);
  }

public:
  static constexpr unsigned no_progress_ms = 120000;
  bool framed() const { return framed_stream; }
#ifdef STANDALONE_TEST
  inline static void (*test_hook)(int, uint64_t) = nullptr;
  pid_t testPid() const { return child; }
#endif
  explicit RomReader(const std::string &path, const std::string &movie_directory = {},
                     const std::string &nsmb_mode = {}, bool allow_movies = true) {
    reap();
    int fds[2];
    if (pipe2(fds, O_CLOEXEC)) throw std::runtime_error("ROM reader pipe");
    const auto parent = getpid();
    child = fork();
    if (child < 0) {
      close(fds[0]); close(fds[1]);
      throw std::runtime_error("ROM reader fork");
    }
    if (!child) {
      // Only the disposable reader inherits the menu selection. Never mutate
      // the SPI owner's environment when another game is loaded later.
      if (!nsmb_mode.empty() && setenv("NDS_NSMB_PATCH", nsmb_mode.c_str(), 1)) _exit(1);
      worker(fds[1], parent, path, movie_directory, allow_movies);
    }
    close(fds[1]);
    input = fds[0];
  }
  RomReader(const RomReader &) = delete;
  RomReader &operator=(const RomReader &) = delete;
  bool preparingCache() const { return cache_preparing; }
  int workProgress() const { return work_progress; }
  ~RomReader() {
    close(input);
    // A CIFS task in uninterruptible sleep may not exit immediately. Never join
    // it on the SPI thread. An unreaped child PID cannot be reused underneath us.
    int status;
    pid_t result;
    do { result = waitpid(child, &status, WNOHANG); } while (result < 0 && errno == EINTR);
    if (!result) {
      kill(child, SIGKILL);
      retiring.push_back(child);
    }
    reap();
  }
  static void reap() {
    retiring.erase(std::remove_if(retiring.begin(), retiring.end(), [](pid_t pid) {
      int status;
      const auto r = waitpid(pid, &status, WNOHANG);
      return r == pid || (r < 0 && errno == ECHILD);
    }), retiring.end());
  }
  template<class Service>
  void finish(uint64_t size, const Service &service, unsigned timeout_ms = no_progress_ms) {
    if (framed_stream) throw std::runtime_error("Framed ROM requires validated transfer");
    Header h{};
    size_t off = 0;
    while (off < sizeof(h))
      off += read(reinterpret_cast<char *>(&h) + off, sizeof(h) - off, service, timeout_ms);
    if (h.operation != 8 || h.error || h.size != transferSize(size))
      throw std::runtime_error("ROM stream did not complete validation");
  }
  // Framed loads remain held in reset until a validated completion record.
  // The host initializes the whole aperture to FF first; only it owns MMIO.
  template<class Service, class Write, class Progress, class Prepare>
  void transferFramed(uint64_t size, const Service &service, const Write &write,
                      const Progress &progress, const Prepare &prepare,
                      unsigned timeout_ms = no_progress_ms) {
    if (!framed_stream || !validSize(size)) throw std::runtime_error("Invalid framed ROM size");
    const auto limit = transferSize(size);
    std::array<unsigned char, 262144> buffer;
    uint64_t checked = 0;
    bool preparing = false;
    const auto exact = [&](void *data, size_t bytes) {
      size_t off = 0;
      while (off < bytes) off += read(static_cast<char *>(data) + off, bytes - off, service, timeout_ms);
    };
    for (;;) {
      Header h{};
      exact(&h, sizeof(h));
      if (h.operation == 13) {
        workProgress(h);
      } else if (h.operation == 12) {
        cacheStatus(h);
      } else if (h.operation == 10) {
        if (h.error <= 0 || size_t(h.error) > buffer.size() || h.size > limit ||
            uint64_t(h.error) > limit - h.size)
          throw std::runtime_error("ROM write outside cartridge memory");
        exact(buffer.data(), size_t(h.error));
        write(h.size, buffer.data(), size_t(h.error));
      } else if (h.operation == 7) {
        if (h.error || h.size < checked || h.size > size)
          throw std::runtime_error("Invalid ROM verification progress");
        checked = h.size;
        if (!preparing) progress(checked, size);
      } else if (h.operation == 11) {
        if (h.error || h.size || preparing || checked != size)
          throw std::runtime_error("Invalid ROM preparation stage");
        preparing = true;
        prepare();
      } else if (h.operation == 8) {
        if (h.error || h.size != limit || checked != size || !preparing)
          throw std::runtime_error("ROM stream did not complete validation");
        return;
      } else {
        throw std::runtime_error("ROM stream validation failed");
      }
    }
  }
  template<class Service>
  size_t read(void *data, size_t size, const Service &service,
              unsigned timeout_ms = no_progress_ms) {
    for (;;) {
      service(); // Heartbeat/save service and cancellation, even before metadata.
      if (std::chrono::steady_clock::now() - progressed >= std::chrono::milliseconds(timeout_ms))
        throw std::runtime_error("ROM load stalled: no file progress");
      pollfd fd{input, POLLIN, 0};
      const auto ready = poll(&fd, 1, 50);
      if (ready < 0 && errno == EINTR) continue;
      if (ready < 0) throw std::runtime_error("ROM reader poll");
      if (!ready) continue;
      const auto n = ::read(input, data, size);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) throw std::runtime_error("ROM read failed or file shortened");
      progressed = std::chrono::steady_clock::now();
      return size_t(n);
    }
  }
  template<class Service>
  uint64_t size(const Service &service, unsigned timeout_ms = no_progress_ms) {
    Header h{};
    do {
      size_t off = 0;
      while (off < sizeof(h))
        off += read(reinterpret_cast<char *>(&h) + off, sizeof(h) - off, service, timeout_ms);
      if (h.operation == 12) cacheStatus(h);
      if (h.operation == 13) workProgress(h);
    } while (h.operation == padding_progress || h.operation == 12 || h.operation == 13);
    if (h.operation == 9) {
      if (h.error || !validSize(h.size)) throw std::runtime_error("Invalid framed ROM metadata");
      framed_stream = true;
      return h.size;
    }
    if (h.operation) {
      if (h.operation == 5)
        throw std::runtime_error(RomLayout::extended(h.size)
            ? "ROM data above 464 MiB must be FF padding (cartridge storage is reserved)"
            : "ROM data above 252 MiB must be FF padding (graphics memory is reserved)");
      const char *names[] = {"", "open ROM", "ROM stat", "ROM file", "ROM size", "",
                             "ROM read failed while checking padding"};
      if (h.operation < 1 || h.operation > 6)
        throw std::runtime_error("Invalid ROM reader response");
      throw std::runtime_error(std::string(names[h.operation]) + ": " + strerror(h.error));
    }
    return h.size;
  }
};

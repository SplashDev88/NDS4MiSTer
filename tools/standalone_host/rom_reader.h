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
    // Optional paired-kit movie preparation runs in this disposable worker,
    // before FIO is touched. Unknown games stay on the existing native reader.
    // Only these FDs survive exec; neither save/SPI ownership nor a helper
    // process is retained during gameplay. The original path stays in Host.
    if (!h.operation && !movie_directory.empty()) {
      unsigned char header[32]{};
      if (pread(rom, header, sizeof(header), 0) == ssize_t(sizeof(header))) {
        const std::string code(reinterpret_cast<char *>(header + 12), 4);
        const char* nsmb_mode = std::getenv("NDS_NSMB_PATCH");
        const bool nsmb = code == "A2DE" && nsmb_mode &&
            (std::strcmp(nsmb_mode, "lookup") == 0 || std::strcmp(nsmb_mode, "skip") == 0 ||
             std::strcmp(nsmb_mode, "both") == 0 || std::strcmp(nsmb_mode, "bones") == 0 ||
             std::strcmp(nsmb_mode, "lookup+bones") == 0 || std::strcmp(nsmb_mode, "skip+bones") == 0 ||
             std::strcmp(nsmb_mode, "both+bones") == 0);
        if (header[30] == 0 && (nsmb || (allow_movies && (code == "BMTE" || code == "B2KJ" || code == "YQUE" ||
                               code == "AXFE" || code == "YWSE")))) {
          const auto script = movie_directory + (nsmb ? "/nsmb_stream.py" : "/stream.py");
          const auto input_arg = std::to_string(rom), output_arg = std::to_string(output);
          const auto parent_arg = std::to_string(parent);
          if (fcntl(rom, F_SETFD, 0) || fcntl(output, F_SETFD, 0)) _exit(1);
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
    Header h{};
    size_t off = 0;
    while (off < sizeof(h))
      off += read(reinterpret_cast<char *>(&h) + off, sizeof(h) - off, service, timeout_ms);
    if (h.operation != 8 || h.error || h.size != transferSize(size))
      throw std::runtime_error("ROM stream did not complete validation");
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
    } while (h.operation == padding_progress);
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

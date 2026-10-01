// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <csignal>
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
  struct Header { uint64_t size; int error; int operation; };
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
  [[noreturn]] static void worker(int output, pid_t parent, const std::string &path) {
    // Never inherit the host's graceful SIGTERM handler: this child has no
    // state to save and must also stop if the host disappears during CIFS I/O.
    signal(SIGTERM, SIG_DFL);
    signal(SIGINT, SIG_DFL);
    signal(SIGUSR1, SIG_DFL);
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != parent) _exit(1);
    // CLOEXEC alone does not release the host's flock after fork. Close every
    // inherited descriptor before any network operation, including that lock,
    // input devices, save, heartbeat and /dev/mem. Never access inherited MMIO.
    DIR *fds = opendir("/proc/self/fd");
    if (!fds) _exit(1);
    while (auto *e = readdir(fds)) {
      char *end;
      const long fd = strtol(e->d_name, &end, 10);
      if (*end == '\0' && fd != output && fd != dirfd(fds)) close(int(fd));
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
    else if (st.st_size < 512 || st.st_size > 128 * 1024 * 1024) {
      h.operation = 4; h.error = EINVAL;
    } else h.size = uint64_t(st.st_size);
    if (!send(output, &h, sizeof(h)) || h.operation) _exit(1);
    std::array<char, 262144> buffer;
    uint64_t off = 0;
    while (off < h.size) {
#ifdef STANDALONE_TEST
      if (test_hook) test_hook(rom, off);
#endif
      const auto n = pread(rom, buffer.data(), std::min<uint64_t>(buffer.size(), h.size - off), off);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0 || !send(output, buffer.data(), size_t(n))) _exit(1);
      off += uint64_t(n);
    }
    _exit(0);
  }

public:
  static constexpr unsigned no_progress_ms = 120000;
#ifdef STANDALONE_TEST
  inline static void (*test_hook)(int, uint64_t) = nullptr;
  pid_t testPid() const { return child; }
#endif
  explicit RomReader(const std::string &path) {
    reap();
    int fds[2];
    if (pipe2(fds, O_CLOEXEC)) throw std::runtime_error("ROM reader pipe");
    const auto parent = getpid();
    child = fork();
    if (child < 0) {
      close(fds[0]); close(fds[1]);
      throw std::runtime_error("ROM reader fork");
    }
    if (!child) worker(fds[1], parent, path);
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
    size_t off = 0;
    while (off < sizeof(h))
      off += read(reinterpret_cast<char *>(&h) + off, sizeof(h) - off, service, timeout_ms);
    if (h.operation) {
      const char *names[] = {"", "open ROM", "ROM stat", "ROM file", "ROM size"};
      throw std::runtime_error(std::string(names[h.operation]) + ": " + strerror(h.error));
    }
    return h.size;
  }
};

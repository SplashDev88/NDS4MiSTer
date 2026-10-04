// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <dirent.h>
#include <fcntl.h>
#include <functional>
#include <optional>
#include <stdexcept>
#include <string>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>
// Only the disposable child probes removable/network filesystems. It drops all
// inherited save/SPI/ownership descriptors, never accesses MMIO, and cannot
// block the frontend on cancellation (including uninterruptible CIFS reads).
class StorageJob {
  int input = -1;
  pid_t child = -1;
  std::string bytes;
  std::chrono::steady_clock::time_point began =
      std::chrono::steady_clock::now();
  inline static std::vector<pid_t> retiring;

public:
  static void reap() {
    retiring.erase(std::remove_if(retiring.begin(), retiring.end(),
                                  [](pid_t p) {
                                    int status;
                                    const auto r = waitpid(p, &status, WNOHANG);
                                    return r == p || (r < 0 && errno == ECHILD);
                                  }),
                   retiring.end());
  }
  explicit StorageJob(const std::function<std::string()> &work) {
    reap();
    if (retiring.size() >= 4)
      throw std::runtime_error("Storage is still responding; retry shortly");
    int pipefd[2];
    if (pipe2(pipefd, O_CLOEXEC))
      throw std::runtime_error("Cannot start storage reader");
    const auto parent = getpid();
    child = fork();
    if (child < 0) {
      close(pipefd[0]);
      close(pipefd[1]);
      throw std::runtime_error("Cannot start storage reader");
    }
    if (!child) {
      signal(SIGTERM, SIG_DFL);
      signal(SIGINT, SIG_DFL);
      signal(SIGUSR1, SIG_DFL);
      signal(SIGPIPE, SIG_DFL);
      if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != parent)
        _exit(1);
      auto *fds = opendir("/proc/self/fd");
      if (!fds)
        _exit(1);
      while (auto *e = readdir(fds)) {
        char *end;
        const long fd = strtol(e->d_name, &end, 10);
        if (!*end && fd != pipefd[1] && fd != dirfd(fds))
          close(int(fd));
      }
      closedir(fds);
      std::string result;
      try {
        result = "O" + work();
      } catch (const std::exception &e) {
        result = "E" + std::string(e.what());
      } catch (...) {
        result = "EStorage read failed";
      }
      if (result.size() > 4 * 1024 * 1024)
        result = "EStorage response is too large";
      size_t sent = 0;
      while (sent < result.size()) {
        const auto n =
            write(pipefd[1], result.data() + sent, result.size() - sent);
        if (n < 0 && errno == EINTR)
          continue;
        if (n <= 0)
          _exit(1);
        sent += size_t(n);
      }
      _exit(0);
    }
    close(pipefd[1]);
    input = pipefd[0];
    const int flags = fcntl(input, F_GETFL);
    if (flags < 0 || fcntl(input, F_SETFL, flags | O_NONBLOCK) < 0) {
      close(input);
      input = -1;
      kill(child, SIGKILL);
      retiring.push_back(child);
      reap();
      throw std::runtime_error("Cannot configure storage reader");
    }
  }
  StorageJob(const StorageJob &) = delete;
  ~StorageJob() {
    if (input >= 0)
      close(input);
    int status;
    pid_t result;
    do {
      result = waitpid(child, &status, WNOHANG);
    } while (result < 0 && errno == EINTR);
    if (!result) {
      kill(child, SIGKILL);
      retiring.push_back(child);
    }
    reap();
  }
  std::optional<std::string> poll(unsigned timeoutMs = 15000) {
    if (std::chrono::steady_clock::now() - began >=
        std::chrono::milliseconds(timeoutMs))
      throw std::runtime_error(
          "Storage is not responding. Retry or browse another device.");
    // Bound work per input/SPI loop even for a very large directory listing.
    for (unsigned i = 0; i < 8; ++i) {
      char data[8192];
      const auto n = read(input, data, sizeof(data));
      if (n > 0) {
        bytes.append(data, size_t(n));
        if (bytes.size() > 4 * 1024 * 1024)
          throw std::runtime_error("Storage response is too large");
        continue;
      }
      if (n < 0 && (errno == EAGAIN || errno == EINTR))
        return {};
      if (n < 0)
        throw std::runtime_error("Storage read failed");
      if (bytes.empty())
        throw std::runtime_error("Storage reader exited unexpectedly");
      if (bytes[0] != 'O')
        throw std::runtime_error(bytes.substr(1));
      return bytes.substr(1);
    }
    return {};
  }
};

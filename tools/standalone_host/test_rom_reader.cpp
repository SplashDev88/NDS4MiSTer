// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#include "rom_reader.h"
#include "test_rom_fixture.h"
#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sys/file.h>

namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;
static unsigned metadata_delay = 0, read_delay = 0;
static bool shorten = false, fail_read = false;
static bool fail_padding = false, shorten_padding = false;
static unsigned padding_delay = 0;
static uint64_t padding_start = RomReader::max_transfer_size;
static int inherited_fd = -1;
static void hook(int fd, uint64_t off) {
  if (fd < 0) {
    if (inherited_fd >= 0 && (fcntl(inherited_fd, F_GETFD) >= 0 || errno != EBADF)) _exit(9);
    usleep(metadata_delay * 1000);
  } else {
    if (off >= padding_start) {
      usleep(padding_delay * 1000);
      if (fail_padding) close(fd);
      if (shorten_padding) assert(truncate("/tmp/rom-reader-fixture.nds", padding_start) == 0);
    }
    usleep(read_delay * 1000);
    if (!off && shorten) assert(truncate("/tmp/rom-reader-fixture.nds", 512) == 0);
    if (!off && fail_read) close(fd);
  }
}
static std::string fixture(size_t size) {
  std::string bytes(size, '\0');
  for (size_t i = 0; i < size; ++i) bytes[i] = char((i * 113 + i / 97) & 255);
  std::ofstream("/tmp/rom-reader-fixture.nds", std::ios::binary).write(bytes.data(), bytes.size());
  return bytes;
}
static void reaped(pid_t pid) {
  const auto end = Clock::now() + std::chrono::seconds(2);
  while (Clock::now() < end) {
    RomReader::reap();
    if (kill(pid, 0) < 0 && errno == ESRCH) {
      int status;
      assert(waitpid(pid, &status, WNOHANG) < 0 && errno == ECHILD);
      return;
    }
    usleep(1000);
  }
  assert(false && "worker was not reaped");
}
static void transfer(const std::string &expected, unsigned timeout, unsigned minimum_ms = 0) {
  auto last = Clock::now(), start = last;
  unsigned calls = 0;
  pid_t pid;
  {
    RomReader r("/tmp/rom-reader-fixture.nds");
    pid = r.testPid();
    const auto service = [&] {
      const auto now = Clock::now();
      assert(now - last < std::chrono::seconds(1));
      last = now;
      ++calls;
    };
    const auto n = r.size(service, timeout);
    assert(n == expected.size());
    std::string got(n, '\0');
    size_t off = 0;
    while (off < n) off += r.read(got.data() + off, n - off, service, timeout);
    assert(got == expected);
  }
  reaped(pid);
  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start).count();
  assert(elapsed >= minimum_ms);
  std::cout << "PASS transfer bytes=" << expected.size() << " elapsed_ms=" << elapsed
            << " service_calls=" << calls << "\n";
}
static void error(const std::string &path, const std::string &expected, bool body = false) {
  pid_t pid;
  bool caught = false;
  {
    RomReader r(path);
    pid = r.testPid();
    try {
      const auto n = r.size([] {}, 500);
      if (body) {
        std::string got(n, '\0');
        size_t off = 0;
        while (off < n) off += r.read(got.data() + off, n - off, [] {}, 500);
      }
    } catch (const std::exception &e) {
      assert(std::string(e.what()).find(expected) != std::string::npos);
      caught = true;
    }
  }
  assert(caught);
  reaped(pid);
}
static void large_transfer(uint64_t file_size) {
  const char *path = "/tmp/rom-reader-fixture.nds";
  largeRomFixture(path, file_size);
  pid_t pid;
  {
    RomReader r(path);
    pid = r.testPid();
    assert(r.size([] {}, 500) == file_size);
    const auto expected = RomReader::transferSize(file_size);
    uint64_t off = 0;
    std::array<unsigned char, 262144> buffer;
    while (off < expected) {
      const auto n = r.read(buffer.data(), std::min<uint64_t>(buffer.size(), expected - off), [] {}, 500);
      for (size_t i = 0; i < n; ++i)
        assert(buffer[i] == (off + i == 0 ? 0x12 : off + i == expected - 1 ? 0x37 : 0));
      off += n;
    }
    // The worker must not stream padding into the reserved graphics area.
    bool ended = false;
    try { r.read(buffer.data(), 1, [] {}, 500); }
    catch (const std::exception &e) {
      ended = std::string(e.what()).find("ROM read failed") != std::string::npos;
    }
    assert(ended);
  }
  reaped(pid);
  std::cout << "PASS large ROM file_bytes=" << file_size
            << " transfer_bytes=" << RomReader::transferSize(file_size) << '\n';
}
static void large_roms() {
  const char *path = "/tmp/rom-reader-fixture.nds";
  for (const auto size : {RomLayout::lr1_transfer_size - 1, RomLayout::lr1_transfer_size,
                          RomLayout::lr1_transfer_size + 1, RomLayout::lr1_file_size,
                          RomLayout::lr1_file_size + 1,
                          RomReader::max_transfer_size - 1, RomReader::max_transfer_size,
                          RomReader::max_transfer_size + 1, RomReader::max_file_size})
    large_transfer(size);
  // A tiny claimed used-size in the zero-filled header cannot hide real data.
  for (const auto offset : {RomReader::max_transfer_size, RomReader::max_file_size - 1}) {
    romFixtureByte(path, offset, 0x00);
    error(path, "above 316 MiB must be FF padding");
    romFixtureByte(path, offset, 0xff);
  }
  fail_padding = true;
  error(path, "ROM read failed while checking padding");
  fail_padding = false;
  shorten_padding = true;
  error(path, "ROM read failed while checking padding");
  shorten_padding = false;
  // Exercise the LR1-specific omitted span, then a four-MiB extended tail.
  largeRomFixture(path, RomLayout::lr1_file_size);
  for (const auto offset : {RomLayout::lr1_transfer_size, RomLayout::lr1_file_size - 1}) {
    romFixtureByte(path, offset, 0);
    error(path, "above 252 MiB must be FF padding");
    romFixtureByte(path, offset, 0xff);
  }
  const auto progress_size = RomReader::max_transfer_size + 4 * RomLayout::mib;
  largeRomFixture(path, progress_size);
  pid_t pid;
  padding_delay = 80;
  const auto validation_start = Clock::now();
  unsigned service_calls = 0;
  {
    RomReader r(path);
    pid = r.testPid();
    assert(r.size([&] { ++service_calls; }, 200) == progress_size);
  }
  reaped(pid);
  assert(service_calls >= 16 && Clock::now() - validation_start >= std::chrono::milliseconds(1280));
  padding_delay = 5000;
  const auto start = Clock::now();
  bool cancelled = false;
  {
    RomReader r(path);
    pid = r.testPid();
    try {
      r.size([&] {
        if (Clock::now() - start >= std::chrono::milliseconds(100))
          throw std::runtime_error("cancelled padding");
      }, 500);
    } catch (const std::exception &e) {
      cancelled = std::string(e.what()) == "cancelled padding";
    }
  }
  assert(cancelled && Clock::now() - start < std::chrono::seconds(1));
  reaped(pid);
  padding_delay = 0;
  std::cout << "PASS first/last omitted-byte rejection, padding read errors, progress and cancellation\n";
}
static void cancelled(bool cancel, bool body) {
  metadata_delay = body ? 0 : 5000;
  read_delay = body ? 5000 : 0;
  pid_t pid;
  const auto start = Clock::now();
  bool caught = false;
  {
    RomReader r("/tmp/rom-reader-fixture.nds");
    pid = r.testPid();
    try {
      const auto service = [&] {
        if (cancel && Clock::now() - start >= std::chrono::milliseconds(100))
          throw std::runtime_error("cancelled");
      };
      r.size(service, 200);
      if (body) { char byte; r.read(&byte, 1, service, 200); }
    } catch (const std::exception &e) {
      assert(std::string(e.what()).find(cancel ? "cancelled" : "no file progress") != std::string::npos);
      caught = true;
    }
  }
  assert(caught && Clock::now() - start < std::chrono::seconds(1));
  reaped(pid);
  metadata_delay = read_delay = 0;
  std::cout << "PASS " << (body ? "read " : "metadata ")
            << (cancel ? "cancellation" : "no-progress timeout") << " and worker cleanup\n";
}
static void parent_death() {
  assert(prctl(PR_SET_CHILD_SUBREAPER, 1) == 0);
  int info[2];
  assert(pipe(info) == 0);
  metadata_delay = 10000;
  const auto host = fork();
  assert(host >= 0);
  if (!host) {
    close(info[0]);
    RomReader r("/tmp/rom-reader-fixture.nds");
    const auto pid = r.testPid();
    assert(write(info[1], &pid, sizeof(pid)) == sizeof(pid));
    for (;;) pause();
  }
  close(info[1]);
  pid_t pid;
  assert(read(info[0], &pid, sizeof(pid)) == sizeof(pid));
  close(info[0]);
  assert(kill(host, SIGKILL) == 0);
  int status;
  assert(waitpid(host, &status, 0) == host);
  const auto end = Clock::now() + std::chrono::seconds(2);
  pid_t done = 0;
  while (!done && Clock::now() < end) {
    done = waitpid(pid, &status, WNOHANG);
    assert(done >= 0);
    if (!done) usleep(1000);
  }
  assert(done == pid && (WIFSIGNALED(status) || WIFEXITED(status)));
  metadata_delay = 0;
  std::cout << "PASS reader follows host death\n";
}
int main(int argc, char **) {
  RomReader::test_hook = hook;
  auto bytes = fixture(1024 * 1024 + 37);
  transfer(bytes, 500);
  metadata_delay = 250;
  transfer(bytes, 500, 250);
  metadata_delay = 0;
  read_delay = 80;
  transfer(bytes, 200, 400); // Total exceeds the timeout; each read progresses.
  read_delay = 0;
  error("/does/not/exist", "open ROM");
  error("/tmp", "ROM file");
  fixture(511);
  error("/tmp/rom-reader-fixture.nds", "ROM size");
  assert(truncate("/tmp/rom-reader-fixture.nds", RomReader::max_file_size + 1) == 0);
  error("/tmp/rom-reader-fixture.nds", "ROM size");
  fixture(1024 * 1024);
  shorten = true;
  error("/tmp/rom-reader-fixture.nds", "ROM read failed", true);
  shorten = false;
  fixture(1024);
  fail_read = true;
  error("/tmp/rom-reader-fixture.nds", "ROM read failed", true);
  fail_read = false;
  for (const bool body : {false, true}) {
    cancelled(false, body);
    cancelled(true, body);
  }
  // A blocked worker cannot retain the host's SPI ownership lock.
  inherited_fd = open("/tmp/rom-reader-lock", O_CREAT | O_RDWR, 0600);
  assert(inherited_fd >= 0 && flock(inherited_fd, LOCK_EX | LOCK_NB) == 0);
  metadata_delay = 150;
  {
    RomReader r("/tmp/rom-reader-fixture.nds");
    close(inherited_fd);
    const int other = open("/tmp/rom-reader-lock", O_RDWR);
    bool locked = false;
    r.size([&] { if (!locked) locked = flock(other, LOCK_EX | LOCK_NB) == 0; }, 500);
    assert(locked);
    close(other);
  }
  inherited_fd = -1;
  metadata_delay = 0;
  std::cout << "PASS inherited descriptors and lock released\n";
  parent_death();
  large_roms();
  if (argc > 1) {
    read_delay = 21500;
    transfer(fixture(512), RomReader::no_progress_ms, 21500);
    read_delay = 0;
    std::cout << "PASS real blocked read exceeds unchanged 20-second watchdog\n";
  }
  fs::remove("/tmp/rom-reader-fixture.nds");
  fs::remove("/tmp/rom-reader-lock");
}

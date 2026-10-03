// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "rom_layout.h"
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <unistd.h>
#ifdef STANDALONE_TEST
#include <vector>
#endif

// This checks Linux ownership, not concurrent FPGA users. The matching
// standalone supervisor and audited framework retain exclusive bank ownership.
inline void validateRomBank(std::istream &iomem) {
  bool meaningful_ram = false;
  std::string line;
  while (std::getline(iomem, line)) {
    if (line.find("System RAM") == std::string::npos) continue;
    unsigned long long first = 0, last = 0;
    int name = 0;
    if (sscanf(line.c_str(), " %llx-%llx : %n", &first, &last, &name) != 2 ||
        name == 0 || line.substr(size_t(name)) != "System RAM" || first >= last)
      throw std::runtime_error("512 MiB ROM needs a readable, unredacted Linux memory map");
    meaningful_ram = true;
    if (first < RomLayout::bank_end && last >= RomLayout::bank_start)
      throw std::runtime_error("512 MiB ROM bank overlaps Linux System RAM");
  }
  if (iomem.bad() || !meaningful_ram)
    throw std::runtime_error("512 MiB ROM needs a readable, unredacted Linux memory map");
}

class RomMapping {
  std::array<RomLayout::Span, 3> spans;
  std::array<void *, 3> memory{{MAP_FAILED, MAP_FAILED, MAP_FAILED}};
public:
#ifdef STANDALONE_TEST
  inline static std::string test_iomem_path;
  inline static int test_memory_fd = -1, test_fail_mapping = -1;
  inline static unsigned test_live_mappings = 0;
  inline static std::vector<RomLayout::Span> test_mapped_spans;
  inline static void (*test_before_padding_write)(uint64_t) = nullptr;
#endif
  explicit RomMapping(uint64_t size) : spans(RomLayout::spans(size)) {
    if (RomLayout::extended(size)) {
#ifndef STANDALONE_TEST
      std::ifstream iomem("/proc/iomem");
#else
      std::ifstream iomem(test_iomem_path);
#endif
      validateRomBank(iomem);
    }
#ifndef STANDALONE_TEST
    const int fd = open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
    if (fd < 0) throw std::runtime_error(std::string("ROM memory: ") + strerror(errno));
#else
    const int fd = test_memory_fd;
#endif
    try {
      for (size_t i = 0; i < spans.size(); ++i) {
        if (!spans[i].size) continue;
#ifndef STANDALONE_TEST
        memory[i] = mmap(nullptr, spans[i].size, PROT_READ | PROT_WRITE,
                         MAP_SHARED, fd, spans[i].physical);
#else
        if (int(i) == test_fail_mapping) errno = ENOMEM;
        else memory[i] = mmap(nullptr, spans[i].size, PROT_READ | PROT_WRITE,
                              fd >= 0 ? MAP_SHARED : MAP_PRIVATE | MAP_ANONYMOUS,
                              fd, fd >= 0 ? spans[i].physical : 0);
#endif
        if (memory[i] == MAP_FAILED)
          throw std::runtime_error(std::string("ROM mmap: ") + strerror(errno));
#ifdef STANDALONE_TEST
        ++test_live_mappings;
        test_mapped_spans.push_back(spans[i]);
#endif
      }
    } catch (...) {
#ifndef STANDALONE_TEST
      close(fd);
#endif
      reset();
      throw;
    }
#ifndef STANDALONE_TEST
    close(fd);
#endif
  }
  RomMapping(const RomMapping &) = delete;
  RomMapping &operator=(const RomMapping &) = delete;
  ~RomMapping() { reset(); }
  void reset() {
    for (size_t i = 0; i < spans.size(); ++i) {
      if (memory[i] == MAP_FAILED) continue;
      munmap(memory[i], spans[i].size);
      memory[i] = MAP_FAILED;
#ifdef STANDALONE_TEST
      --test_live_mappings;
#endif
    }
  }
  struct Chunk { void *data; size_t size; };
  Chunk at(uint64_t offset) const {
    for (size_t i = 0; i < spans.size(); ++i) {
      if (offset < spans[i].logical || offset >= spans[i].logical + spans[i].size) continue;
      const auto within = offset - spans[i].logical;
      return {static_cast<char *>(memory[i]) + within, size_t(spans[i].size - within)};
    }
    throw std::runtime_error("ROM transfer outside mapped storage");
  }
};

// SPDX-License-Identifier: GPL-3.0-only
// MiSTer Main recent.cpp file format: 16 records, each containing fixed
// directory[1024], name[256], label[256] C strings. See THIRD_PARTY.md.
#pragma once
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

struct RecentFile {
  std::string directory, name, label;
};
class RecentFiles {
public:
  static constexpr size_t limit = 16, record_size = 1536;
  static std::vector<RecentFile> read(const std::filesystem::path &path) {
    if (!std::filesystem::exists(path)) return {};
    if (std::filesystem::file_size(path) != limit * record_size)
      throw std::runtime_error("Invalid recent-file list size");
    std::ifstream input(path, std::ios::binary);
    std::string data(limit * record_size, '\0');
    if (!input.read(data.data(), data.size()))
      throw std::runtime_error("Cannot read recent-file list");
    std::vector<RecentFile> result;
    for (size_t i = 0; i < limit; ++i) {
      auto field = [&](size_t offset, size_t length) {
        const auto start = i * record_size + offset;
        const auto end = data.find('\0', start);
        if (end == std::string::npos || end >= start + length)
          throw std::runtime_error("Invalid recent-file record");
        return data.substr(start, end - start);
      };
      RecentFile entry{field(0, 1024), field(1024, 256), field(1280, 256)};
      if (entry.name.empty()) break;
      if (entry.label.empty()) entry.label = entry.name;
      result.push_back(entry);
    }
    return result;
  }
  static std::string encode(const std::vector<RecentFile> &entries) {
    std::string data(limit * record_size, '\0');
    for (size_t i = 0; i < std::min(limit, entries.size()); ++i) {
      auto field = [&](size_t offset, size_t length, const std::string &s) {
        if (s.size() >= length || s.find('\0') != std::string::npos)
          throw std::runtime_error("Recent-file path too long");
        data.replace(i * record_size + offset, s.size(), s);
      };
      field(0, 1024, entries[i].directory);
      field(1024, 256, entries[i].name);
      field(1280, 256, entries[i].label);
    }
    return data;
  }
  static void prepend(std::vector<RecentFile> &entries, const RecentFile &entry) {
    entries.erase(std::remove_if(entries.begin(), entries.end(), [&](const auto &e) {
      return e.directory == entry.directory && e.name == entry.name;
    }), entries.end());
    entries.insert(entries.begin(), entry);
    if (entries.size() > limit) entries.resize(limit);
  }
};

// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
namespace nds_storage {
namespace fs = std::filesystem;
using Fields = std::vector<std::string>;
inline std::string pack(const Fields &fields) {
  std::ostringstream s;
  s << fields.size() << '\n';
  for (const auto &v : fields)
    s << std::quoted(v) << '\n';
  return s.str();
}
inline Fields unpack(const std::string &data) {
  std::istringstream s(data);
  size_t count = 0;
  if (!(s >> count) || count > 65536)
    throw std::runtime_error("Invalid storage response");
  Fields out(count);
  for (auto &v : out)
    if (!(s >> std::quoted(v)))
      throw std::runtime_error("Incomplete storage response");
  return out;
}
inline bool inside(const fs::path &path, const fs::path &root) {
  auto rel =
      path.lexically_normal().lexically_relative(root.lexically_normal());
  return !rel.empty() && !rel.is_absolute() && *rel.begin() != "..";
}
struct Volume {
  fs::path path;
  std::string id, label;
};
#ifdef STANDALONE_TEST
inline std::vector<Volume> test_volumes;
#endif
struct Location {
  std::string path, volume, id, relative;
  bool empty() const { return path.empty(); }
  Fields fields() const { return {path, volume, id, relative}; }
  static Location parse(const Fields &f, size_t at = 0) {
    if (f.size() < at + 4)
      throw std::runtime_error("Invalid saved storage location");
    Location l{f[at], f[at + 1], f[at + 2], f[at + 3]};
    if (!l.empty() &&
        (!fs::path(l.path).is_absolute() || !fs::path(l.volume).is_absolute() ||
         fs::path(l.relative).is_absolute() ||
         !inside(fs::path(l.volume) / l.relative, l.volume)))
      throw std::runtime_error("Invalid saved storage path");
    return l;
  }
};
struct Preferences {
  Location games, firmware;
  std::string last; // Relative to the selected games folder, not usbN.
  std::string encode() const {
    auto f = games.fields();
    auto b = firmware.fields();
    f.insert(f.end(), b.begin(), b.end());
    f.push_back(last);
    return "NDS-STORAGE-1\n" + pack(f);
  }
  static Preferences read(const fs::path &path) {
    std::ifstream in(path);
    if (!in)
      return {};
    std::string marker;
    std::getline(in, marker);
    if (marker != "NDS-STORAGE-1")
      throw std::runtime_error("Invalid storage settings");
    auto f = unpack(std::string(std::istreambuf_iterator<char>(in), {}));
    if (f.size() != 9)
      throw std::runtime_error("Invalid storage settings");
    Preferences p{Location::parse(f), Location::parse(f, 4), f[8]};
    if (!p.last.empty() && (fs::path(p.last).is_absolute() ||
                            !inside(fs::path("/root") / p.last, "/root")))
      throw std::runtime_error("Invalid last games folder");
    return p;
  }
};
inline std::string unescapeMount(const std::string &s) {
  std::string out;
  for (size_t i = 0; i < s.size(); ++i) {
    if (s[i] == '\\' && i + 3 < s.size() && s[i + 1] >= '0' &&
        s[i + 1] <= '7' && s[i + 2] >= '0' && s[i + 2] <= '7' &&
        s[i + 3] >= '0' && s[i + 3] <= '7') {
      out +=
          char((s[i + 1] - '0') * 64 + (s[i + 2] - '0') * 8 + s[i + 3] - '0');
      i += 3;
    } else
      out += s[i];
  }
  return out;
}
inline std::vector<Volume>
volumes(const fs::path &sd, const fs::path &mounts = "/proc/mounts",
        const fs::path &uuids = "/dev/disk/by-uuid") {
#ifdef STANDALONE_TEST
  if (!test_volumes.empty())
    return test_volumes;
#endif
  std::vector<Volume> out{{sd, "sd", "SD card"}};
  std::ifstream input(mounts);
  std::string line;
  while (std::getline(input, line)) {
    std::istringstream row(line);
    std::string device, where, type;
    if (!(row >> device >> where >> type))
      continue;
    device = unescapeMount(device);
    where = unescapeMount(where);
    fs::path path(where);
    if (path == sd)
      continue;
    const bool usb = path.parent_path() == "/media" &&
                     path.filename().string().rfind("usb", 0) == 0;
    const bool network = type == "cifs" || type == "nfs" || type == "nfs4";
    if (!usb && !(network && inside(path, "/media")))
      continue;
    std::string id = network ? "network:" + device : "";
    if (usb) {
      std::error_code ec;
      for (const auto &p : fs::directory_iterator(uuids, ec)) {
        auto target = fs::weakly_canonical(p.path(), ec);
        if (!ec && target == fs::path(device)) {
          id = "uuid:" + p.path().filename().string();
          break;
        }
      }
    }
    out.push_back(
        {path, id,
         usb ? "USB " + path.filename().string().substr(3) : "Network"});
  }
  std::sort(out.begin(), out.end(), [](const Volume &a, const Volume &b) {
    return a.path.string().size() > b.path.string().size();
  });
  return out;
}
inline const Volume &owner(const fs::path &path,
                           const std::vector<Volume> &vs) {
  for (const auto &v : vs)
    if (inside(path, v.path))
      return v;
  throw std::runtime_error(
      "Choose a folder on mounted SD, USB or network storage");
}
inline Location locate(const fs::path &path, const std::vector<Volume> &vs) {
  const auto canonical = fs::canonical(path);
  if (!fs::is_directory(canonical))
    throw std::runtime_error("Folder is unavailable");
  const auto &v = owner(canonical, vs);
  return {canonical.string(), v.path.string(), v.id,
          canonical.lexically_relative(v.path).string()};
}
inline fs::path resolve(const Location &l, const std::vector<Volume> &vs) {
  if (l.empty())
    throw std::runtime_error("No folder selected");
  for (const auto &v : vs) {
    if ((!l.id.empty() && l.id == v.id) ||
        (l.id.empty() && l.volume == v.path)) {
      auto p = v.path / l.relative;
      if (fs::is_directory(p)) {
        const auto canonical = fs::canonical(p);
        if (inside(canonical, v.path) && owner(canonical, vs).path == v.path)
          return canonical;
      }
    }
  }
  throw std::runtime_error("Saved location unavailable");
}
inline std::vector<Location> discover(const std::vector<Volume> &vs) {
  std::vector<Location> out;
  for (const auto &v : vs) {
    const auto p = v.path / "games/NDS";
    std::error_code ec;
    if (fs::is_directory(p, ec)) {
      auto l = locate(p, vs);
      if (std::none_of(out.begin(), out.end(),
                       [&](const Location &x) { return x.path == l.path; }))
        out.push_back(l);
    }
  }
  return out;
}
struct Entry {
  std::string name;
  bool directory;
};
inline Fields directory(const fs::path &where, const fs::path &root,
                        bool foldersOnly) {
  const auto dir = fs::canonical(where), base = fs::canonical(root);
  if (!inside(dir, base))
    throw std::runtime_error("Folder is outside the selected storage");
  std::vector<Entry> entries;
  for (const auto &e : fs::directory_iterator(dir)) {
    const auto name = e.path().filename().string();
    if (name.empty() || name.front() == '.')
      continue;
    std::error_code ec;
    const auto target = fs::canonical(e.path(), ec);
    if (ec || !inside(target, base))
      continue;
    if (e.is_directory(ec))
      entries.push_back({name, true});
    else if (!foldersOnly && e.is_regular_file(ec)) {
      auto ext = e.path().extension().string();
      std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
      const auto n = e.file_size(ec);
      if (!ec && ext == ".nds" && n >= 512 && n <= 512ull * 1024 * 1024)
        entries.push_back({name, false});
    }
    if (entries.size() > 8192)
      throw std::runtime_error("Too many files; use smaller subfolders");
  }
  std::sort(entries.begin(), entries.end(), [](const Entry &a, const Entry &b) {
    if (a.directory != b.directory)
      return a.directory;
    auto x = a.name, y = b.name;
    std::transform(x.begin(), x.end(), x.begin(), ::tolower);
    std::transform(y.begin(), y.end(), y.begin(), ::tolower);
    return x < y;
  });
  Fields f{dir.string()};
  for (const auto &e : entries) {
    f.push_back(e.name);
    f.push_back(e.directory ? "1" : "0");
  }
  return f;
}
} // namespace nds_storage

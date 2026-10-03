// SPDX-License-Identifier: GPL-3.0-only
// Production-code filesystem probe. No synthetic fixtures or private dump bytes.
#include "firmware_media.h"
#include <fstream>
#include <iostream>
#include <iterator>

static nds_firmware::Bytes readBytes(const std::filesystem::path &path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) throw std::runtime_error("Probe cannot read " + path.filename().string());
  nds_firmware::Bytes bytes{std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
  if (input.bad()) throw std::runtime_error("Probe read failed for " + path.filename().string());
  return bytes;
}
static void require(bool condition, const char *message) {
  if (!condition) throw std::runtime_error(message);
}
int main(int argc, char **argv) {
  if (argc != 3) {
    std::cerr << "usage: probe_firmware_media SOURCE_DIRECTORY FRESH_WORKING_PATH\n";
    return 2;
  }
  try {
    const std::filesystem::path sources(argv[1]), work(argv[2]);
    struct stat existing{};
    if (!lstat(work.c_str(), &existing))
      throw std::runtime_error("Probe requires a fresh working path; existing data was not changed");
    if (errno != ENOENT) throw std::runtime_error("Probe cannot inspect requested working path");
    const auto bios7 = readBytes(sources / "bios7.bin");
    const auto bios9 = readBytes(sources / "bios9.bin");
    const auto firmware = readBytes(sources / "firmware.bin");
    {
      auto media = nds_firmware::Media::open(sources, work);
      require(media.bios7() == bios7 && media.bios9() == bios9 && media.image() == firmware,
              "Probe media differs from source bytes");
      require(readBytes(work) == firmware, "Probe seeded working file differs from source bytes");
    }
    {
      auto media = nds_firmware::Media::open(sources, work);
      require(media.image() == firmware, "Probe reopened image differs from source bytes");
    }
    require(readBytes(sources / "bios7.bin") == bios7 && readBytes(sources / "bios9.bin") == bios9 &&
            readBytes(sources / "firmware.bin") == firmware, "Probe detected changed original bytes");
    std::cout << "PASS production Media::open created and reopened " << firmware.size()
              << " bytes; originals unchanged; working image and lock retained for inspection\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << "FAIL firmware media probe: " << error.what() << '\n';
    return 1;
  }
}

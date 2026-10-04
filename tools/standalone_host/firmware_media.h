// SPDX-License-Identifier: GPL-3.0-only
#pragma once
// Firmware layout/CRC definitions follow melonDS SPI_Firmware and GBATEK:
// https://mgba-emu.github.io/gbatek/#ds-firmware-header
// https://mgba-emu.github.io/gbatek/#ds-firmware-user-settings
// Personal dumps are runtime inputs, never generated or redistributed assets.
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <functional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/syscall.h>
#else
#include <stdio.h>
#endif

namespace nds_firmware {
namespace fs = std::filesystem;
inline constexpr size_t image_size = 256 * 1024;
inline constexpr size_t sector_size = 512;
using Bytes = std::vector<uint8_t>;
using Sector = std::array<uint8_t, sector_size>;

inline uint16_t le16(const uint8_t *p) { return uint16_t(p[0]) | uint16_t(p[1]) << 8; }
inline uint16_t crc16(const uint8_t *p, size_t n, uint16_t value = 0xffff) {
  for (size_t i = 0; i < n; ++i) {
    value ^= p[i];
    for (unsigned bit = 0; bit < 8; ++bit)
      value = uint16_t((value >> 1) ^ ((value & 1) ? 0xa001 : 0));
  }
  return value;
}
inline uint32_t crc32(const Bytes &bytes) {
  uint32_t value = ~uint32_t(0);
  for (auto byte : bytes) {
    value ^= byte;
    for (unsigned bit = 0; bit < 8; ++bit)
      value = (value >> 1) ^ ((value & 1) ? 0xedb88320u : 0);
  }
  return ~value;
}
struct CalibrationAxis {
  uint16_t adc1 = 0, adc2 = 0;
  uint8_t pixel1 = 0, pixel2 = 0;
  // Map the virtual pixel coordinate into the original dump's ADC domain.
  // Signed arithmetic also handles a reversed calibration axis.
  uint16_t adcForPixel(int pixel) const {
    if (pixel1 == pixel2 || adc1 == adc2 || adc1 > 4095 || adc2 > 4095)
      throw std::runtime_error("Firmware touch calibration is invalid");
    const int64_t value = int64_t(adc1) +
        (int64_t(pixel) - pixel1) * (int64_t(adc2) - adc1) /
        (int64_t(pixel2) - pixel1);
    return uint16_t(std::clamp<int64_t>(value, 0, 4095));
  }
};
struct Profile {
  std::array<uint8_t, 0x70> bytes{};
  uint32_t user_offset = 0, selected_offset = 0;
  uint16_t gui_wifi_crc = 0, data_gfx_crc = 0, update_counter = 0;
  unsigned selected_copy = 0;
  // Diagnostic only: native firmware chooses area0 if neither is a successor.
  bool nonadjacent_counters = false;
  CalibrationAxis x, y;
};
inline uint32_t validateHeader(const Bytes &bytes) {
  if (bytes.size() != image_size)
    throw std::runtime_error("Firmware must be a 256 KiB Nintendo DS/DS Lite image");
  if (bytes[8] != 'M' || bytes[9] != 'A' || bytes[10] != 'C' ||
      (bytes[0x1d] != 0xff && bytes[0x1d] != 0x20))
    throw std::runtime_error("Unsupported firmware: Nintendo DS/DS Lite image required");
  const uint16_t shifts = le16(bytes.data() + 0x14);
  if ((shifts >> 12) != 2)
    throw std::runtime_error("Firmware header does not describe a 256 KiB chip");
  const uint32_t user = uint32_t(le16(bytes.data() + 0x20)) * 8;
  if (user < 0x200 || (user & 0xff) || user > image_size - 0x200)
    throw std::runtime_error("Firmware user settings pointer is invalid");
  // Header addresses are compressed/encrypted code locations, not entry PCs.
  // Full code validity is determined by the native BIOS during boot.
  const std::array<uint32_t, 5> locations{{
      uint32_t(le16(bytes.data())) * 8,
      uint32_t(le16(bytes.data() + 2)) * 8,
      uint32_t(le16(bytes.data() + 0xc)) << (2 + (shifts & 7)),
      uint32_t(le16(bytes.data() + 0x10)) << (2 + ((shifts >> 6) & 7)),
      uint32_t(le16(bytes.data() + 0x16)) * 8}};
  for (auto location : locations)
    if (location < 0x200 || location >= user)
      throw std::runtime_error("Firmware code/data pointer is outside the image");
  const auto wifi_length = le16(bytes.data() + 0x2c);
  if (wifi_length < 2 || wifi_length > 0x200 - 0x2c ||
      crc16(bytes.data() + 0x2c, wifi_length, 0) != le16(bytes.data() + 0x2a))
    throw std::runtime_error("Firmware Wi-Fi calibration checksum is invalid");
  return user;
}
inline Profile inspectProfile(const Bytes &bytes) {
  Profile profile;
  profile.user_offset = validateHeader(bytes);
  std::array<bool, 2> valid{};
  std::array<uint16_t, 2> count{};
  for (unsigned i = 0; i < 2; ++i) {
    const auto *block = bytes.data() + profile.user_offset + i * 0x100;
    count[i] = le16(block + 0x70);
    valid[i] = le16(block) == 5 && le16(block + 0x1a) <= 10 &&
        le16(block + 0x50) <= 26 && count[i] <= 127 &&
        crc16(block, 0x70) == le16(block + 0x72);
  }
  if (!valid[0] && !valid[1])
    throw std::runtime_error("Firmware has no valid user settings copy; original files were preserved");
  // GBATEK/native firmware's successor rule, including 127 -> 0 rollover.
  profile.selected_copy = valid[1] && (!valid[0] || ((count[0] + 1) & 127) == count[1]);
  profile.nonadjacent_counters = valid[0] && valid[1] &&
      ((count[0] + 1) & 127) != count[1] && ((count[1] + 1) & 127) != count[0];
  profile.selected_offset = profile.user_offset + profile.selected_copy * 0x100;
  const auto *block = bytes.data() + profile.selected_offset;
  std::copy_n(block, profile.bytes.size(), profile.bytes.begin());
  profile.update_counter = count[profile.selected_copy];
  profile.gui_wifi_crc = le16(bytes.data() + 4);
  profile.data_gfx_crc = le16(bytes.data() + 0x26);
  profile.x = {le16(block + 0x58), le16(block + 0x5e), block[0x5c], block[0x62]};
  profile.y = {le16(block + 0x5a), le16(block + 0x60), block[0x5d], block[0x63]};
  if (profile.y.pixel1 > 191 || profile.y.pixel2 > 191)
    throw std::runtime_error("Firmware touch calibration Y coordinate is invalid");
  (void)profile.x.adcForPixel(0);
  (void)profile.y.adcForPixel(0);
  return profile;
}

class Media {
  class Fd {
    int value_ = -1;
  public:
    explicit Fd(int value = -1) : value_(value) {}
    ~Fd() { if (value_ >= 0) close(value_); }
    Fd(const Fd &) = delete;
    Fd &operator=(const Fd &) = delete;
    Fd(Fd &&other) noexcept : value_(std::exchange(other.value_, -1)) {}
    Fd &operator=(Fd &&other) noexcept {
      if (this != &other) {
        if (value_ >= 0) close(value_);
        value_ = std::exchange(other.value_, -1);
      }
      return *this;
    }
    int get() const { return value_; }
  };
  struct Identity { dev_t device; ino_t inode; };
  Bytes bios7_, bios9_, image_;
  fs::path working_;
  std::vector<Identity> sources_;
  Fd lock_, directory_;
  bool uncertain_ = false;
  // Kept empty in production; tests inject storage faults at durable boundaries.
  std::function<void(const char *)> fault_;
#ifdef STANDALONE_FIRMWARE_TEST
  int exclusive_rename_error_ = 0;
#endif

  static void fail(const std::string &what) {
    throw std::runtime_error(what + ": " + std::strerror(errno));
  }
  static bool exists(const fs::path &path) {
    struct stat st{};
    if (!lstat(path.c_str(), &st)) return true;
    if (errno == ENOENT) return false;
    fail("Inspect firmware path " + path.string());
    return false;
  }
  void safeDestination(const fs::path &path) const {
    struct stat st{};
    if (lstat(path.c_str(), &st)) {
      if (errno == ENOENT) return;
      fail("Inspect firmware destination " + path.string());
    }
    if (!S_ISREG(st.st_mode))
      throw std::runtime_error("Firmware destination must be a regular file, not a symlink: " + path.string());
    for (const auto &source : sources_)
      if (source.device == st.st_dev && source.inode == st.st_ino)
        throw std::runtime_error("Firmware destination aliases an original dump: " + path.string());
  }
  Bytes readFile(const fs::path &path, size_t size, bool source) {
    Fd file(::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
    if (file.get() < 0) fail("Open " + path.string());
    struct stat st{};
    if (fstat(file.get(), &st)) fail("Stat " + path.string());
    if (!S_ISREG(st.st_mode) || st.st_size != off_t(size))
      throw std::runtime_error(path.filename().string() + " must be a regular " + std::to_string(size) + "-byte file");
    if (source) sources_.push_back({st.st_dev, st.st_ino});
    Bytes result(size);
    size_t done = 0;
    while (done < result.size()) {
      const auto n = read(file.get(), result.data() + done, result.size() - done);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) throw std::runtime_error("Incomplete read of " + path.filename().string());
      done += size_t(n);
    }
    uint8_t extra;
    ssize_t n;
    do { n = read(file.get(), &extra, 1); } while (n < 0 && errno == EINTR);
    if (n != 0) throw std::runtime_error("File changed while reading " + path.filename().string());
    return result;
  }
  static void requireOwnedPath(const fs::path &target, const Identity &owner) {
    struct stat st{};
    if (lstat(target.c_str(), &st)) fail("Inspect new firmware working image");
    if (!S_ISREG(st.st_mode) || st.st_dev != owner.device || st.st_ino != owner.inode)
      throw std::runtime_error("Firmware working path changed during exclusive creation");
  }
  void installExclusive(const fs::path &temp, const fs::path &target,
                        const Bytes &data, bool &preserveTemp, Identity &owner) {
    int result;
#ifdef STANDALONE_FIRMWARE_TEST
    if (exclusive_rename_error_) { errno = exclusive_rename_error_; result = -1; }
    else
#endif
    {
#ifdef __linux__
      result = int(syscall(SYS_renameat2, AT_FDCWD, temp.c_str(), AT_FDCWD, target.c_str(), 1));
#elif defined(__APPLE__)
      result = renamex_np(temp.c_str(), target.c_str(), RENAME_EXCL);
#else
      result = ::link(temp.c_str(), target.c_str());
      if (!result) unlink(temp.c_str());
#endif
    }
    if (!result) return;
    if (errno != EINVAL && errno != ENOSYS && errno != EOPNOTSUPP && errno != ENOTSUP)
      fail("Create firmware working copy without overwriting existing data");

    // exFAT may reject RENAME_NOREPLACE and has no hard links. Never replace
    // a reservation with plain rename: an inode check followed by rename has
    // a clobber race. Write only through an O_EXCL-created descriptor instead.
    // The session flock excludes other Media readers until this finishes. On
    // interruption an incomplete working image is rejected on reopen; retain
    // the already-synced temporary image for explicit recovery, never reseed.
    if (fault_) fault_("exclusive-recovery-sync");
    if (fsync(directory_.get())) fail("Sync firmware recovery directory");
    if (fault_) fault_("exclusive-create");
    Fd destination(::open(target.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600));
    if (destination.get() < 0)
      fail("Create firmware working copy without overwriting existing data");
    preserveTemp = true;
    struct stat st{};
    if (fstat(destination.get(), &st)) fail("Stat new firmware working image");
    owner = {st.st_dev, st.st_ino};
    if (fault_) fault_("exclusive-created");
    size_t done = 0;
    while (done < data.size()) {
      const auto n = write(destination.get(), data.data() + done,
                           std::min<size_t>(64 * 1024, data.size() - done));
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) { if (!n) errno = EIO; fail("Write new firmware working image"); }
      done += size_t(n);
      if (fault_) fault_("exclusive-copy");
    }
    if (fault_) fault_("exclusive-file-sync");
    if (fsync(destination.get())) fail("Sync new firmware working image");
    if (fault_) fault_("exclusive-verify");
    requireOwnedPath(target, owner);
  }
  void atomicWrite(const fs::path &target, const Bytes &data, bool exclusive,
                   const char *stage, bool &installed) {
    safeDestination(target);
    std::string name = target.string() + ".tmp.XXXXXX";
    std::vector<char> temp(name.begin(), name.end());
    temp.push_back('\0');
    Fd file(mkstemp(temp.data()));
    if (file.get() < 0) fail("Create temporary firmware image");
    const fs::path temporary(temp.data());
    bool preserveTemp = false;
    Identity owner{};
    try {
      if (fcntl(file.get(), F_SETFD, FD_CLOEXEC)) fail("Set firmware temporary descriptor flags");
      if (fault_) fault_(stage);
      size_t done = 0;
      while (done < data.size()) {
        auto n = write(file.get(), data.data() + done, data.size() - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) fail("Write firmware image");
        done += size_t(n);
      }
      if (fault_) fault_("file-sync");
      if (fsync(file.get())) fail("Sync firmware image");
      safeDestination(target);
      if (fault_) fault_("rename");
      if (exclusive) installExclusive(temporary, target, data, preserveTemp, owner);
      else if (rename(temporary.c_str(), target.c_str())) fail("Replace firmware image");
      installed = true;
      if (fault_) fault_("directory-sync");
      if (fsync(directory_.get())) fail("Sync firmware directory");
      if (preserveTemp) {
        requireOwnedPath(target, owner);
        if (unlink(temporary.c_str())) fail("Remove completed firmware recovery copy");
        preserveTemp = false;
        if (fsync(directory_.get())) fail("Sync firmware recovery cleanup");
      }
    } catch (const std::exception &error) {
      if (preserveTemp)
        throw std::runtime_error(std::string(error.what()) +
            "; new working image may need recovery; synced recovery copy preserved at " + temporary.string());
      unlink(temporary.c_str());
      throw;
    } catch (...) {
      if (!preserveTemp) unlink(temporary.c_str());
      throw;
    }
  }
  void usable() const {
    if (uncertain_)
      throw std::runtime_error("Firmware commit needs recovery; reopen the preserved working image before continuing");
  }
  Media() = default;
public:
  Media(const Media &) = delete;
  Media &operator=(const Media &) = delete;
  Media(Media &&) noexcept = default;
  Media &operator=(Media &&) noexcept = default;

  struct Originals {
    Bytes bios7, bios9, firmware;
    std::vector<std::pair<uint64_t, uint64_t>> identities;
  };
  static void validateOriginals(const Originals &originals) {
    // Same known-native identifiers used by melonDS MemConstants.h/NDS.cpp.
    if (originals.bios7.size() != 16384 ||
        crc32(originals.bios7) != 0x1280f0d5u)
      throw std::runtime_error(
          "bios7.bin is not the supported native Nintendo DS BIOS");
    if (originals.bios9.size() != 4096 || crc32(originals.bios9) != 0x2ab23573u)
      throw std::runtime_error(
          "bios9.bin is not the supported native Nintendo DS BIOS");
    if (originals.identities.size() != 3)
      throw std::runtime_error("Incomplete original firmware identities");
    (void)inspectProfile(originals.firmware);
  }
  static Originals readOriginals(const fs::path &sourceDirectory) {
    Media reader;
    Originals originals;
    originals.bios7 =
        reader.readFile(sourceDirectory / "bios7.bin", 16384, true);
    originals.bios9 =
        reader.readFile(sourceDirectory / "bios9.bin", 4096, true);
    originals.firmware =
        reader.readFile(sourceDirectory / "firmware.bin", image_size, true);
    for (const auto &id : reader.sources_)
      originals.identities.emplace_back(id.device, id.inode);
    validateOriginals(originals);
    return originals;
  }
  void setOriginals(Originals originals) {
    validateOriginals(originals);
    auto old = sources_;
    sources_.clear();
    for (const auto &id : originals.identities)
      sources_.push_back({dev_t(id.first), ino_t(id.second)});
    try {
      safeDestination(working_);
      safeDestination(working_.string() + ".previous");
      safeDestination(working_.string() + ".lock");
    } catch (...) {
      sources_ = std::move(old);
      throw;
    }
    bios7_ = std::move(originals.bios7);
    bios9_ = std::move(originals.bios9);
  }
  static Media open(const fs::path &sourceDirectory, const fs::path &workingPath
#ifdef STANDALONE_FIRMWARE_TEST
                    ,
                    std::function<void(const char *)> fault = {},
                    int exclusiveRenameError = 0
#endif
  ) {
    return openPrepared(readOriginals(sourceDirectory), workingPath
#ifdef STANDALONE_FIRMWARE_TEST
                        ,
                        std::move(fault), exclusiveRenameError
#endif
    );
  }
  static Media openPrepared(Originals originals, const fs::path &workingPath
#ifdef STANDALONE_FIRMWARE_TEST
                            ,
                            std::function<void(const char *)> fault = {},
                            int exclusiveRenameError = 0
#endif
  ) {
    Media media;
#ifdef STANDALONE_FIRMWARE_TEST
    media.fault_ = std::move(fault);
    media.exclusive_rename_error_ = exclusiveRenameError;
#endif
    media.working_ = fs::absolute(workingPath);
    media.setOriginals(originals);
    auto original = std::move(originals.firmware);
    // Only after all original assets validate may any persistent file be made.
    fs::create_directories(media.working_.parent_path());
    media.safeDestination(media.working_);
    media.safeDestination(media.working_.string() + ".previous");
    const fs::path lockPath = media.working_.string() + ".lock";
    media.safeDestination(lockPath);
    media.lock_ = Fd(::open(lockPath.c_str(), O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600));
    if (media.lock_.get() < 0) fail("Open firmware media lock");
    if (flock(media.lock_.get(), LOCK_EX | LOCK_NB))
      throw std::runtime_error("Firmware working image is already open by another session");
    media.directory_ = Fd(::open(media.working_.parent_path().c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    if (media.directory_.get() < 0) fail("Open firmware directory");
    if (exists(media.working_)) {
      media.safeDestination(media.working_);
      media.image_ = media.readFile(media.working_, image_size, false);
      (void)inspectProfile(media.image_); // No silent reseed or repair.
    } else {
      // A previous image with missing current data is a recovery case, not a
      // first installation. Preserve it and require an explicit decision.
      if (exists(media.working_.string() + ".previous"))
        throw std::runtime_error("Firmware working image is missing but its previous copy exists; restore it before booting");
      bool installed = false;
      media.atomicWrite(media.working_, original, true, "seed-write", installed);
      media.image_ = std::move(original);
    }
    return media;
  }
  const Bytes &bios7() const { return bios7_; }
  const Bytes &bios9() const { return bios9_; }
  const Bytes &image() const { usable(); return image_; }
  Profile profile() const { usable(); return inspectProfile(image_); }
  Sector readSector(uint32_t lba) const {
    usable();
    if (lba >= image_size / sector_size)
      throw std::runtime_error("Firmware sector is outside the image");
    Sector sector{};
    std::copy_n(image_.data() + lba * sector_size, sector_size, sector.begin());
    return sector;
  }
  void commitSector(uint32_t lba, const Sector &sector) {
    usable();
    if (lba >= image_size / sector_size)
      throw std::runtime_error("Firmware sector is outside the image");
    if (std::equal(sector.begin(), sector.end(), image_.data() + lba * sector_size)) return;
    auto next = image_;
    std::copy(sector.begin(), sector.end(), next.begin() + lba * sector_size);
    // Native firmware owns the byte stream/CRCs. A multi-page update may
    // temporarily leave a user block invalid; never "repair" or reject it here.
    bool installed = false, backupInstalled = false;
    try {
      // Preserve the preceding complete byte image before publishing a new one.
      // No persistent image fd is held, so replacement cannot leave stale writes
      // targeting the old unlinked inode.
      atomicWrite(working_.string() + ".previous", image_, false, "backup-write", backupInstalled);
      atomicWrite(working_, next, false, "current-write", installed);
      image_.swap(next); // Durable completion; caller may now acknowledge commit.
    } catch (...) {
      // A rename followed by a failed directory sync has uncertain durability.
      // Freeze this instance; reopen explicitly to select the actual on-disk copy.
      if (installed) uncertain_ = true;
      throw;
    }
  }
#ifdef STANDALONE_FIRMWARE_TEST
  void setFaultHook(std::function<void(const char *)> hook) { fault_ = std::move(hook); }
#endif
};
} // namespace nds_firmware

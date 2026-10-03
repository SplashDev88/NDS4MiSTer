// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_FIRMWARE_TEST
#include "firmware_media.h"
#include "test_firmware_fixture.h"
#include <cassert>
#include <fstream>
#include <iostream>
#include <sys/resource.h>
#include <sys/wait.h>
#include <signal.h>
using namespace nds_firmware;

using namespace firmware_fixture;
static std::string throws(const std::function<void()> &operation) {
  try { operation(); } catch (const std::exception &error) { return error.what(); }
  assert(false && "expected rejection");
  return {};
}
static void expect(const std::function<void()> &operation, const std::string &part) {
  const auto error = throws(operation);
  if (error.find(part) == std::string::npos) {
    std::cerr << "Expected " << part << "; received " << error << '\n';
    std::abort();
  }
}
static void profileTests() {
  auto bytes = syntheticFirmware();
  auto profile = inspectProfile(bytes);
  assert(profile.selected_copy == 0 && profile.bytes[6] == 'A');
  assert(profile.user_offset == user && profile.selected_offset == user);
  assert(profile.x.adcForPixel(128) == 2048 && profile.y.adcForPixel(96) == 1536);
  assert(profile.x.adcForPixel(-1) == 0 && profile.x.adcForPixel(999) == 4095);
  put16(bytes, user + 0x70, 127); put16(bytes, user + 0x170, 0);
  assert(inspectProfile(bytes).selected_copy == 1); // native wrap
  put16(bytes, user + 0x70, 1); put16(bytes, user + 0x170, 80);
  profile = inspectProfile(bytes);
  assert(profile.selected_copy == 0 && profile.nonadjacent_counters);
  bytes[user] ^= 1;
  assert(inspectProfile(bytes).selected_copy == 1);
  bytes[user + 0x100] ^= 1;
  expect([&] { inspectProfile(bytes); }, "no valid user settings");
  bytes = syntheticFirmware(); put16(bytes, 0x20, 0xffff);
  expect([&] { inspectProfile(bytes); }, "pointer");
  bytes = syntheticFirmware(); bytes[0x40] ^= 1;
  expect([&] { inspectProfile(bytes); }, "Wi-Fi calibration checksum");
  bytes = syntheticFirmware(); put16(bytes, 0xc, 0xffff);
  expect([&] { inspectProfile(bytes); }, "code/data pointer");
  bytes = syntheticFirmware(); bytes[0x1d] = 0x57;
  expect([&] { inspectProfile(bytes); }, "Unsupported firmware");
  bytes = syntheticFirmware(); bytes.resize(0x20000);
  expect([&] { inspectProfile(bytes); }, "256 KiB");
  bytes = syntheticFirmware();
  // Original physical calibration is retained and usable without patching.
  put16(bytes, user + 0x58, 3500); put16(bytes, user + 0x5e, 500);
  bytes[user + 0x5c] = 20; bytes[user + 0x62] = 220; checksum(bytes, 0);
  assert(inspectProfile(bytes).x.adcForPixel(120) == 2000);
  const auto unchanged = bytes;
  (void)inspectProfile(bytes); assert(bytes == unchanged);
  bytes[user + 0x62] = 20; checksum(bytes, 0);
  expect([&] { inspectProfile(bytes); }, "touch calibration");
  bytes = syntheticFirmware(); put16(bytes, user + 0x1a, 11); checksum(bytes, 0);
  assert(inspectProfile(bytes).selected_copy == 1);
}
static std::vector<fs::path> recoveryFiles(const fs::path &work) {
  std::vector<fs::path> result;
  for (const auto &entry : fs::directory_iterator(work.parent_path()))
    if (entry.path().filename().string().find(work.filename().string() + ".tmp.") == 0)
      result.push_back(entry.path());
  return result;
}
static void exclusiveFallbackTests(const fs::path &root) {
  const auto sources = root / "originals";
  fs::create_directories(sources);
  const auto bios7 = syntheticBios(16384, 0x5a, 0x1280f0d5);
  const auto bios9 = syntheticBios(4096, 0xc3, 0x2ab23573);
  const auto original = syntheticFirmware();
  writeBytes(sources / "bios7.bin", bios7); writeBytes(sources / "bios9.bin", bios9);
  writeBytes(sources / "firmware.bin", original);
  auto changed = original;
  changed[510 * 512] ^= 1; // Outside the checked profile and Wi-Fi data.
  unsigned sequence = 0;
  const auto fresh = [&] {
    const auto work = root / std::to_string(++sequence) / "working.bin";
    fs::create_directories(work.parent_path());
    return work;
  };
  const auto checkRecovery = [&](const fs::path &work) {
    const auto files = recoveryFiles(work);
    assert(files.size() == 1 && readBytes(files[0]) == original);
  };
  for (const int unsupported : {EINVAL, ENOSYS, EOPNOTSUPP, ENOTSUP}) {
    const auto work = fresh();
    std::vector<std::string> stages;
    {
      auto media = Media::open(sources, work, [&](const char *stage) { stages.emplace_back(stage); }, unsupported);
      assert(media.image() == original && readBytes(work) == original);
      assert(recoveryFiles(work).empty());
      expect([&] { auto second = Media::open(sources, work, {}, unsupported); }, "already open");
      assert(std::count(stages.begin(), stages.end(), "exclusive-copy") == 4);
      assert(std::find(stages.begin(), stages.end(), "exclusive-file-sync") <
             std::find(stages.begin(), stages.end(), "directory-sync"));
      Sector sector{}; std::copy_n(changed.begin() + 510 * 512, 512, sector.begin());
      media.commitSector(510, sector);
      assert(readBytes(work) == changed);
      assert(readBytes(work.string() + ".previous") == original);
    }
    { // Existing working bytes are authoritative even with forced unsupported rename.
      auto media = Media::open(sources, work, [](const char *) { assert(false); }, unsupported);
      assert(media.image() == changed);
    }
  }
  // A target arriving between the absence check and O_EXCL is never replaced.
  for (const unsigned kind : {0u, 1u, 2u}) {
    const auto work = fresh();
    expect([&] {
      auto media = Media::open(sources, work, [&](const char *stage) {
        if (std::string(stage) != "exclusive-create") return;
        if (kind == 0) writeBytes(work, changed);
        if (kind == 1) fs::create_symlink(sources / "firmware.bin", work);
        if (kind == 2) fs::create_hard_link(sources / "firmware.bin", work);
      }, EINVAL);
    }, "without overwriting existing data");
    assert(readBytes(work) == (kind == 0 ? changed : original));
    assert(kind != 1 || fs::is_symlink(work));
    assert(recoveryFiles(work).empty());
  }
  // Permission, collision and I/O errors must not be reinterpreted as unsupported.
  for (const int failure : {EEXIST, EACCES, EIO}) {
    const auto work = fresh();
    expect([&] { auto media = Media::open(sources, work, {}, failure); }, "without overwriting existing data");
    assert(!fs::exists(work) && recoveryFiles(work).empty());
  }
  for (const char *point : {"exclusive-created", "exclusive-copy", "exclusive-file-sync", "directory-sync"}) {
    const auto work = fresh();
    const auto error = throws([&] {
      auto media = Media::open(sources, work, [&](const char *stage) {
        if (std::string(stage) == point) throw std::runtime_error("injected seed failure");
      }, EINVAL);
    });
    assert(error.find("synced recovery copy preserved at") != std::string::npos);
    checkRecovery(work);
    const auto size = fs::file_size(work);
    if (std::string(point) == "exclusive-created") assert(size == 0);
    else if (std::string(point) == "exclusive-copy") assert(size == 65536);
    else assert(readBytes(work) == original);
    if (size != image_size)
      expect([&] { auto media = Media::open(sources, work); }, "262144-byte file");
    else { auto media = Media::open(sources, work); assert(media.image() == original); }
    checkRecovery(work); // No automatic deletion or reseeding on reopen.
  }
  // Failure to persist the recovery name happens before creating a working path.
  {
    const auto work = fresh();
    expect([&] {
      auto media = Media::open(sources, work, [](const char *stage) {
        if (std::string(stage) == "exclusive-recovery-sync") throw std::runtime_error("recovery sync failure");
      }, EINVAL);
    }, "recovery sync failure");
    assert(!fs::exists(work) && recoveryFiles(work).empty());
  }
  // A foreign replacement is neither unlinked nor overwritten by verification.
  {
    const auto work = fresh();
    expect([&] {
      auto media = Media::open(sources, work, [&](const char *stage) {
        if (std::string(stage) == "exclusive-verify") {
          fs::rename(work, work.string() + ".moved"); writeBytes(work, changed);
        }
      }, EINVAL);
    }, "path changed during exclusive creation");
    assert(readBytes(work) == changed && readBytes(work.string() + ".moved") == original);
    checkRecovery(work);
  }
  // Real partial write/EFBIG and abrupt process exit after O_EXCL both fail closed.
  for (const bool abrupt : {false, true}) {
    const auto work = fresh();
    const pid_t child = fork(); assert(child >= 0);
    if (!child) {
      signal(SIGXFSZ, SIG_IGN);
      try {
        auto media = Media::open(sources, work, [&](const char *stage) {
          if (abrupt && std::string(stage) == "exclusive-copy") _exit(0);
          if (!abrupt && std::string(stage) == "exclusive-created") {
            struct rlimit limit{1024, 1024};
            if (setrlimit(RLIMIT_FSIZE, &limit)) _exit(10);
          }
        }, EINVAL);
        _exit(11);
      } catch (const std::exception &error) {
        _exit(!abrupt && std::string(error.what()).find("synced recovery copy preserved at") != std::string::npos ? 0 : 12);
      }
    }
    int status = 0; assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    assert(fs::file_size(work) == (abrupt ? 65536 : 1024));
    checkRecovery(work);
    expect([&] { auto media = Media::open(sources, work); }, "262144-byte file");
  }
  assert(readBytes(sources / "bios7.bin") == bios7);
  assert(readBytes(sources / "bios9.bin") == bios9);
  assert(readBytes(sources / "firmware.bin") == original);
}
static void mediaTests(const fs::path &root) {
  const auto sources = root / "originals", work = root / "persistent/firmware-working.bin";
  fs::create_directories(sources);
  const auto bios7 = syntheticBios(16384, 0x5a, 0x1280f0d5);
  const auto bios9 = syntheticBios(4096, 0xc3, 0x2ab23573);
  const auto original = syntheticFirmware();
  writeBytes(sources / "bios7.bin", bios7); writeBytes(sources / "bios9.bin", bios9);
  writeBytes(sources / "firmware.bin", original);
  Bytes changed;
  {
    auto media = Media::open(sources, work);
    assert(media.bios7() == bios7 && media.bios9() == bios9 && media.image() == original);
    assert(readBytes(work) == original);
    expect([&] { auto second = Media::open(sources, work); }, "already open");
    expect([&] { media.readSector(512); }, "outside");
    expect([&] { media.commitSector(512, {}); }, "outside");
    auto next = original;
    put16(next, user + 0x106, 'Z'); put16(next, user + 0x170, 9); checksum(next, 1);
    Sector sector{}; std::copy_n(next.begin() + user, 512, sector.begin());
    media.commitSector(511, sector);
    assert(media.profile().bytes[6] == 'Z');
    assert(media.image() == next && readBytes(work) == next);
    assert(readBytes(work.string() + ".previous") == original);
    changed = next;
    // Same data is a no-op even under an injected storage failure.
    media.setFaultHook([](const char *) { throw std::runtime_error("disk-full"); });
    media.commitSector(511, sector);
    sector[0] ^= 1;
    expect([&] { media.commitSector(511, sector); }, "disk-full");
    assert(media.image() == next && readBytes(work) == next);
    // Fail the current image stage, after backup durability succeeds.
    media.setFaultHook([](const char *stage) {
      if (std::string(stage) == "current-write") throw std::runtime_error("disk-full current");
    });
    expect([&] { media.commitSector(511, sector); }, "disk-full current");
    assert(media.image() == next && readBytes(work) == next);
    for (const char *point : {"file-sync", "rename"}) {
      unsigned hits = 0;
      media.setFaultHook([&](const char *stage) {
        if (std::string(stage) == point && ++hits == 2) throw std::runtime_error("storage failure");
      });
      expect([&] { media.commitSector(511, sector); }, "storage failure");
      assert(media.image() == next && readBytes(work) == next);
    }
    // Failed directory sync after the final rename is explicitly uncertain.
    unsigned syncs = 0;
    media.setFaultHook([&](const char *stage) {
      if (std::string(stage) == "directory-sync" && ++syncs == 2)
        throw std::runtime_error("directory failure");
    });
    expect([&] { media.commitSector(511, sector); }, "directory failure");
    expect([&] { media.readSector(0); }, "needs recovery");
    expect([&] { media.profile(); }, "needs recovery");
    // Area0 was damaged, but newer area1 remains a valid complete user block.
    changed[user] ^= 1;
    assert(readBytes(work) == changed);
    assert(readBytes(work.string() + ".previous") == next);
  }
  {
    auto reopened = Media::open(sources, work);
    assert(reopened.image() == changed && reopened.profile().bytes[6] == 'Z');
    // Two replacements after reopen prove no stale inode/descriptor is used.
    auto sector = reopened.readSector(510);
    sector[0] = 17; reopened.commitSector(510, sector);
    sector[0] = 29; reopened.commitSector(510, sector);
    assert(readBytes(work)[510 * 512] == 29);
  }
  // Originals are byte-for-byte unchanged through all success/failure paths.
  assert(readBytes(sources / "firmware.bin") == original);
  assert(readBytes(sources / "bios7.bin") == bios7);
  assert(readBytes(sources / "bios9.bin") == bios9);
  const auto alias = root / "alias.bin";
  fs::create_hard_link(sources / "firmware.bin", alias);
  expect([&] { auto media = Media::open(sources, alias); }, "aliases an original");
  fs::remove(alias); fs::create_symlink(sources / "firmware.bin", alias);
  expect([&] { auto media = Media::open(sources, alias); }, "not a symlink");
  expect([&] { auto media = Media::open(sources, sources / "firmware.bin"); }, "aliases an original");
  const auto backed = root / "backup-alias.bin";
  fs::create_hard_link(sources / "firmware.bin", backed.string() + ".previous");
  expect([&] { auto media = Media::open(sources, backed); }, "aliases an original");
  const auto lockAlias = root / "lock-alias.bin";
  fs::create_hard_link(sources / "bios7.bin", lockAlias.string() + ".lock");
  expect([&] { auto media = Media::open(sources, lockAlias); }, "aliases an original");
  // Corrupt work must not be silently replaced from source or previous image.
  auto bad = changed; bad[user + 0x100] ^= 1;
  writeBytes(work, bad);
  expect([&] { auto media = Media::open(sources, work); }, "no valid user settings");
  assert(readBytes(work) == bad && readBytes(sources / "firmware.bin") == original);
  fs::remove(work);
  expect([&] { auto media = Media::open(sources, work); }, "previous copy exists");
  const auto invalidWork = root / "must-not-create/image.bin";
  auto badBios = bios7; badBios[0] ^= 1; writeBytes(sources / "bios7.bin", badBios);
  expect([&] { auto media = Media::open(sources, invalidWork); }, "not the supported native");
  assert(!fs::exists(invalidWork.parent_path()));
  writeBytes(sources / "bios7.bin", bios7);
  writeBytes(sources / "bios9.bin", Bytes(128));
  expect([&] { auto media = Media::open(sources, invalidWork); }, "4096-byte");
  assert(!fs::exists(invalidWork.parent_path()));
  writeBytes(sources / "bios9.bin", bios9);
  fs::rename(sources / "firmware.bin", sources / "firmware.saved");
  expect([&] { auto media = Media::open(sources, invalidWork); }, "firmware.bin");
  fs::rename(sources / "firmware.saved", sources / "firmware.bin");
  // Real OS short write followed by EFBIG, not only a simulated exception.
  const auto limited = root / "limited/image.bin";
  { auto media = Media::open(sources, limited); }
  const pid_t child = fork(); assert(child >= 0);
  if (!child) {
    signal(SIGXFSZ, SIG_IGN);
    struct rlimit limit{1024, 1024};
    if (setrlimit(RLIMIT_FSIZE, &limit)) _exit(10);
    try {
      auto media = Media::open(sources, limited);
      auto sector = media.readSector(510); sector[0] ^= 1;
      try { media.commitSector(510, sector); _exit(11); }
      catch (const std::exception &) {
        _exit(media.image() == original && readBytes(limited) == original ? 0 : 12);
      }
    } catch (...) { _exit(13); }
  }
  int status = 0; assert(waitpid(child, &status, 0) == child);
  assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
  assert(readBytes(limited) == original);
  for (const auto &entry : fs::recursive_directory_iterator(root))
    assert(entry.path().filename().string().find(".tmp.") == std::string::npos);
}
int main(int argc, char **argv) {
  if (argc == 2) {
    // Private read-only validation: work image is seeded only inside a temporary
    // directory and removed on exit. No original path is ever written.
    char name[] = "/tmp/nds-firmware-private-XXXXXX";
    const auto directory = mkdtemp(name); assert(directory);
    try {
      { auto media = Media::open(argv[1], fs::path(directory) / "working.bin");
        const auto profile = media.profile();
        std::cout << "PASS private source validation; firmware bytes=" << media.image().size()
                  << " settings offset=" << profile.user_offset
                  << " selected copy=" << profile.selected_copy
                  << " source data preserved\n"; }
      fs::remove_all(directory);
    } catch (...) { fs::remove_all(directory); throw; }
    return 0;
  }
  char name[] = "/tmp/nds-firmware-test-XXXXXX";
  const auto directory = mkdtemp(name); assert(directory);
  try { profileTests(); mediaTests(directory); exclusiveFallbackTests(fs::path(directory) / "exclusive"); fs::remove_all(directory); }
  catch (...) { fs::remove_all(directory); throw; }
  std::cout << "PASS firmware validation, native profile rollover/calibration, separate durable media,\n"
            << "     restart/alias/locking, atomic failure recovery and real short-write preservation,\n"
            << "     unsupported exclusive-rename fallback, races, sync failure and interrupted seed recovery\n";
}

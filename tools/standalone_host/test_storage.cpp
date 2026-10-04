// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#include "storage_job.h"
#include "storage_locations.h"
#include <cassert>
#include <chrono>
#include <iostream>
#include <sys/file.h>
using namespace nds_storage;
int main() {
  const auto root = fs::temp_directory_path() /
                    ("nds-storage-test-" + std::to_string(getpid()));
  fs::create_directories(root);
  const auto sd = root / "sd", usb0 = root / "usb0", usb1 = root / "usb1";
  fs::create_directories(sd / "games/NDS");
  fs::create_directories(usb0 / "games/NDS/Sub");
  std::vector<Volume> vs{{sd, "sd", "SD card"}, {usb0, "uuid:disk-a", "USB 0"}};
  auto choices = discover(vs);
  assert(choices.size() == 2);
  Preferences p;
  p.games = locate(usb0 / "games/NDS", vs);
  p.last = "Sub";
  std::ofstream(root / "storage.cfg") << p.encode();
  auto restored = Preferences::read(root / "storage.cfg");
  assert(restored.games.path == p.games.path && restored.last == "Sub");
  fs::rename(usb0, usb1);
  vs[1].path = usb1;
  assert(resolve(restored.games, vs) == usb1 / "games/NDS");
  vs[1].id = "uuid:wrong-disk";
  bool missing = false;
  try {
    resolve(restored.games, vs);
  } catch (...) {
    missing = true;
  }
  assert(missing);
  vs[1].id = "uuid:disk-a";
  fs::create_directories(sd / "bios");
  p.firmware = locate(sd / "bios", vs);
  assert(resolve(p.firmware, vs) == sd / "bios");
  std::ofstream(usb1 / "games/NDS/Play.nds") << std::string(512, 'x');
  std::ofstream(usb1 / "games/NDS/tiny.nds") << "x";
  std::ofstream(usb1 / "games/NDS/ignore.txt") << "not a game";
  fs::create_symlink(root, usb1 / "games/NDS/escape");
  auto listing = directory(usb1 / "games/NDS", usb1 / "games/NDS", false);
  assert((listing ==
          Fields{(usb1 / "games/NDS").string(), "Sub", "1", "Play.nds", "0"}));
  auto encoded =
      pack({"spaces and \"quotes\"", "line\nbreak", std::string("a\0b", 3)});
  assert(unpack(encoded) == (Fields{"spaces and \"quotes\"", "line\nbreak",
                                    std::string("a\0b", 3)}));
  bool traversal = false;
  try {
    Location::parse({"/media/fat/a", "/media/fat", "sd", "../../etc"});
  } catch (...) {
    traversal = true;
  }
  assert(traversal);
  std::ofstream(root / "device").put(0);
  std::ofstream(root / "mounts") << (root / "device").string()
                                 << " /media/usb0 exfat rw 0 0\n//server/share "
                                    "/media/fat/cifs cifs rw 0 0\n";
  fs::create_directories(root / "uuids");
  fs::create_symlink(root / "device", root / "uuids/1234-ABCD");
  auto mounted = volumes(sd, root / "mounts", root / "uuids");
  assert(mounted.size() == 3);
  assert(std::any_of(mounted.begin(), mounted.end(),
                     [](const Volume &v) { return v.id == "uuid:1234-ABCD"; }));
  auto wait = [](StorageJob &job) {
    std::optional<std::string> result;
    unsigned serviced = 0;
    while (!(result = job.poll(3000))) {
      ++serviced;
      usleep(1000);
    }
    return std::make_pair(*result, serviced);
  };
  StorageJob slow([] {
    usleep(150000);
    return std::string(200000, 'a');
  });
  auto read = wait(slow);
  assert(read.first == std::string(200000, 'a') && read.second > 30);
  const auto lockPath = root / "lock";
  int lock = open(lockPath.c_str(), O_CREAT | O_RDWR, 0600);
  assert(flock(lock, LOCK_EX | LOCK_NB) == 0);
  auto blocked = std::make_unique<StorageJob>([] {
    sleep(30);
    return std::string();
  });
  usleep(50000);
  close(lock);
  lock = open(lockPath.c_str(), O_RDWR);
  assert(flock(lock, LOCK_EX | LOCK_NB) == 0);
  close(lock);
  auto before = std::chrono::steady_clock::now();
  blocked.reset();
  assert(std::chrono::steady_clock::now() - before <
         std::chrono::milliseconds(100));
  StorageJob timeout([] {
    sleep(30);
    return std::string();
  });
  usleep(20000);
  bool timed = false;
  try {
    timeout.poll(10);
  } catch (...) {
    timed = true;
  }
  assert(timed);
  StorageJob failure([]() -> std::string { throw std::runtime_error("gone"); });
  bool error = false;
  try {
    wait(failure);
  } catch (const std::exception &e) {
    error = std::string(e.what()) == "gone";
  }
  assert(error);
  fs::remove_all(root);
  std::cout
      << "PASS: discovery, persistence, USB renumbering/identity, separate "
         "BIOS location, directory bounds, binary IPC, responsive reads, "
         "descriptor isolation, cancellation and timeout\n";
}

// SPDX-License-Identifier: GPL-3.0-only
// Exercise real device discovery and event handling without physical evdev nodes.
#include <sys/ioctl.h>
#include <linux/input.h>
#include <cerrno>
static int motion_test_ioctl(int fd, unsigned long request, void *argument);
// The display host also uses integer I2C ioctls. Input fixtures must never
// access the transmitter, but still need to compile that overload.
static int motion_test_ioctl(int, unsigned long, int) {
  errno = ENOTTY;
  return -1;
}
#define ioctl motion_test_ioctl
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#undef ioctl
#include <cassert>
#include <iostream>

namespace {
struct Device {
  static constexpr unsigned word_bits = sizeof(unsigned long) * 8;
  std::string name;
  input_id id{BUS_USB, 0x054c, 0x0ce6, 0x0100};
  unsigned long properties = 0;
  bool properties_supported = true;
  unsigned property_queries = 0;
  bool keys_supported = true;
  unsigned key_queries = 0;
  std::array<unsigned long, (KEY_CNT + word_bits - 1) / word_bits> keys{};
  std::array<input_absinfo, ABS_CNT> axes{};
  void setKey(unsigned code, bool enabled = true) {
    const auto mask = 1UL << (code % word_bits);
    if (enabled) keys[code / word_bits] |= mask;
    else keys[code / word_bits] &= ~mask;
  }
};
using NodeKey = std::pair<dev_t, ino_t>;
std::map<NodeKey, Device> devices;

NodeKey nodeKey(int fd) {
  struct stat st{};
  assert(fstat(fd, &st) == 0);
  return {st.st_dev, st.st_ino};
}

Device &createNode(const fs::path &path, Device device) {
  const int fd = open(path.c_str(), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600);
  assert(fd >= 0);
  const auto key = nodeKey(fd);
  close(fd);
  devices[key] = std::move(device);
  return devices.at(key);
}

void emit(const fs::path &path,
          std::initializer_list<std::array<int, 3>> events) {
  std::ofstream out(path, std::ios::binary | std::ios::app);
  assert(out);
  for (const auto &values : events) {
    input_event event{};
    event.type = values[0];
    event.code = values[1];
    event.value = values[2];
    out.write(reinterpret_cast<const char *>(&event), sizeof(event));
  }
  out.flush();
  assert(out);
}

Device gamepad() {
  Device device;
  device.name = "Sony Interactive Entertainment DualSense Wireless Controller";
  for (const int axis : {ABS_X, ABS_Y, ABS_Z, ABS_RX, ABS_RY, ABS_RZ})
    device.axes[axis] = {128, 0, 255, 0, 0, 0};
  device.axes[ABS_HAT0X] = device.axes[ABS_HAT0Y] = {0, -1, 1, 0, 0, 0};
  device.axes[ABS_Z].value = device.axes[ABS_RZ].value = 0;
  for (const int key : {BTN_WEST, BTN_NORTH, BTN_EAST, BTN_SOUTH, BTN_TL,
                        BTN_TR, BTN_TL2, BTN_TR2, BTN_SELECT, BTN_START,
                        BTN_THUMBL, BTN_THUMBR, BTN_MODE})
    device.setKey(key);
  return device;
}

Device sensors() {
  Device device;
  device.name = gamepad().name + " Motion Sensors";
  device.properties = 1UL << INPUT_PROP_ACCELEROMETER;
  for (const int axis : {ABS_X, ABS_Y, ABS_Z})
    device.axes[axis] = {0, -32768, 32768, 16, 0, 8192};
  for (const int axis : {ABS_RX, ABS_RY, ABS_RZ})
    device.axes[axis] = {0, -2097152, 2097152, 16, 0, 1024};
  return device;
}
} // namespace

static int motion_test_ioctl(int fd, unsigned long request, void *argument) {
  const auto found = devices.find(nodeKey(fd));
  assert(found != devices.end()); // Never fall through to a physical device.
  auto &device = found->second;
  if (request == EVIOCGID) {
    *static_cast<input_id *>(argument) = device.id;
    return 0;
  }
  if (_IOC_TYPE(request) == 'E' && _IOC_NR(request) == _IOC_NR(EVIOCGNAME(1))) {
    std::snprintf(static_cast<char *>(argument), _IOC_SIZE(request), "%s",
                  device.name.c_str());
    return std::min(size_t(_IOC_SIZE(request)), device.name.size() + 1);
  }
  if (_IOC_TYPE(request) == 'E' && _IOC_NR(request) == _IOC_NR(EVIOCGPROP(1))) {
    ++device.property_queries;
    if (!device.properties_supported) {
      errno = ENOTTY;
      return -1;
    }
    std::memset(argument, 0, _IOC_SIZE(request));
    std::memcpy(argument, &device.properties,
                std::min(size_t(_IOC_SIZE(request)), sizeof(device.properties)));
    return std::min(size_t(_IOC_SIZE(request)), sizeof(device.properties));
  }
  if (_IOC_TYPE(request) == 'E' && _IOC_NR(request) == _IOC_NR(EVIOCGBIT(EV_KEY, 1))) {
    ++device.key_queries;
    if (!device.keys_supported) {
      errno = ENOTTY;
      return -1;
    }
    std::memset(argument, 0, _IOC_SIZE(request));
    std::memcpy(argument, device.keys.data(),
                std::min(size_t(_IOC_SIZE(request)), sizeof(device.keys)));
    return std::min(size_t(_IOC_SIZE(request)), sizeof(device.keys));
  }
  if (_IOC_TYPE(request) == 'E' && _IOC_NR(request) >= _IOC_NR(EVIOCGABS(0)) &&
      _IOC_NR(request) < _IOC_NR(EVIOCGABS(0)) + ABS_CNT) {
    const auto &axis = device.axes[_IOC_NR(request) - _IOC_NR(EVIOCGABS(0))];
    if (axis.maximum > axis.minimum) {
      *static_cast<input_absinfo *>(argument) = axis;
      return 0;
    }
  }
  errno = EINVAL;
  return -1;
}

struct HostTest {
  static void poll(Host &host) {
    errno = 0; // Regular fixture files end at EOF rather than EAGAIN.
    host.inputs();
  }
  static size_t commands(const Host &host, uint16_t command) {
    return std::count_if(host.spi.history.begin(), host.spi.history.end(),
                         [&](const auto &entry) { return entry.command == command; });
  }
  static uint16_t lastAnalog(const Host &host) {
    for (auto it = host.spi.history.rbegin(); it != host.spi.history.rend(); ++it)
      if (it->command == 0x3d) {
        assert(it->words.size() == 2 && it->words[0] == 0);
        return it->words[1];
      }
    assert(false && "expected a real analog SPI transfer");
    return 0;
  }
  static void triggerMappings(const fs::path &root) {
    unsigned cases = 0;
    for (const int bus : {BUS_USB, BUS_BLUETOOTH})
      for (const bool abs_first : {false, true})
        for (const bool right : {false, true}) {
          const auto dir = root / std::to_string(cases++);
          const auto kit = dir / "kit", sd = dir / "sd", input = dir / "input";
          fs::create_directories(kit);
          fs::create_directories(input);
          auto device = gamepad();
          device.id.bustype = bus;
          auto &fixture = createNode(input / "event0", device);
          const auto node = input / "event0";
          Host host(kit.string(), (sd / "games/NDS").string(), sd);
          host.scan(input);
          assert(host.pads.size() == 1);
          host.mapping_step = 0;
          const int axis = right ? ABS_RZ : ABS_Z;
          const int button = right ? BTN_TR2 : BTN_TL2;
          // A trigger rests at its minimum, not its center. That idle sample
          // must not map the axis's synthetic negative direction.
          emit(node, {{EV_ABS, axis, 0}, {EV_SYN, SYN_REPORT, 0}});
          poll(host);
          assert(host.mapping_step == 0 &&
                 "idle/released digital trigger must not map its analog axis");
          for (int pull = 0; pull < 2; ++pull) {
            if (abs_first)
              emit(node, {{EV_ABS, axis, 24}, {EV_ABS, axis, 96},
                          {EV_KEY, button, 1}, {EV_ABS, axis, 240},
                          {EV_SYN, SYN_REPORT, 0}});
            else
              emit(node, {{EV_KEY, button, 1}, {EV_ABS, axis, 24},
                          {EV_ABS, axis, 96}, {EV_ABS, axis, 240},
                          {EV_SYN, SYN_REPORT, 0}});
            poll(host);
            assert(host.mapping_step == pull + 1 &&
                   "one physical trigger pull must advance exactly one prompt");
            assert(host.new_map[pull] == unsigned(button));
            // Digital hold/repeat plus analog jitter around both synthesized
            // direction thresholds must never spill into the following prompt.
            for (const int value : {255, 250, 192, 188, 194, 190, 96, 62, 65, 63, 240}) {
              emit(node, {{EV_ABS, axis, value}, {EV_KEY, button, 1},
                          {EV_KEY, button, 2}, {EV_SYN, SYN_REPORT, 0}});
              poll(host);
              assert(host.mapping_step == pull + 1 &&
                     "held trigger and analog jitter must not advance prompts");
            }
            if (abs_first)
              emit(node, {{EV_ABS, axis, 40}, {EV_ABS, axis, 0},
                          {EV_KEY, button, 0}, {EV_SYN, SYN_REPORT, 0}});
            else
              emit(node, {{EV_KEY, button, 0}, {EV_ABS, axis, 40},
                          {EV_ABS, axis, 0}, {EV_SYN, SYN_REPORT, 0}});
            poll(host);
            assert(host.mapping_step == pull + 1 &&
                   "trigger release must not advance the following prompt");
            for (const int value : {1, 2, 0}) {
              emit(node, {{EV_ABS, axis, value}, {EV_KEY, button, 0},
                          {EV_SYN, SYN_REPORT, 0}});
              poll(host);
              assert(host.mapping_step == pull + 1);
            }
          }
          assert(fixture.key_queries == 1);
          // A regular stick remains available in the same mapping wizard.
          emit(node, {{EV_ABS, ABS_X, 255}, {EV_SYN, SYN_REPORT, 0}});
          poll(host);
          assert(host.mapping_step == 3 && host.new_map[2] == 0x301);

          // Existing axis-based gameplay mappings must still receive both
          // trigger directions outside the wizard; buttons retain their edges.
          host.mapping_step = -1;
          host.menu = false;
          auto &pad = host.pads[0];
          pad.pressed.fill(false);
          pad.map.fill(0);
          pad.map[4] = 0x301 + axis * 2;
          pad.map[5] = 0x300 + axis * 2;
          pad.map[8] = button;
          emit(node, {{EV_ABS, axis, 255}, {EV_KEY, button, 1},
                      {EV_SYN, SYN_REPORT, 0}});
          poll(host);
          assert(host.lastjoy == ((1u << 4) | (1u << 8)));
          emit(node, {{EV_KEY, button, 0}, {EV_ABS, axis, 0},
                      {EV_SYN, SYN_REPORT, 0}});
          poll(host);
          assert(host.lastjoy == (1u << 5));
        }

    // Detect each corresponding button independently. Pads with analog-only
    // triggers, or without the capability ioctl, keep their existing mapping.
    for (const bool right : {false, true})
      for (const bool query_supported : {false, true}) {
        const auto dir = root / std::to_string(cases++);
        const auto kit = dir / "kit", sd = dir / "sd", input = dir / "input";
        fs::create_directories(kit);
        fs::create_directories(input);
        auto device = gamepad();
        device.id = {BUS_USB, 0x1234, 0x0200, 1};
        device.keys_supported = query_supported;
        const int axis = right ? ABS_RZ : ABS_Z;
        const int button = right ? BTN_TR2 : BTN_TL2;
        device.setKey(button, false); // Opposite trigger button stays present.
        auto &fixture = createNode(input / "event0", device);
        Host host(kit.string(), (sd / "games/NDS").string(), sd);
        host.scan(input);
        host.mapping_step = 0;
        emit(input / "event0", {{EV_ABS, axis, 255}, {EV_SYN, SYN_REPORT, 0}});
        poll(host);
        assert(host.mapping_step == 1 && host.new_map[0] == unsigned(0x301 + axis * 2));
        assert(fixture.key_queries == 1);
        if (query_supported) {
          const int other_axis = right ? ABS_Z : ABS_RZ;
          const int other_button = right ? BTN_TL2 : BTN_TR2;
          emit(input / "event0", {{EV_ABS, other_axis, 0},
                                 {EV_KEY, other_button, 1},
                                 {EV_ABS, other_axis, 255},
                                 {EV_SYN, SYN_REPORT, 0}});
          poll(host);
          assert(host.mapping_step == 2 && host.new_map[1] == unsigned(other_button));
        }
      }
    std::cout << "PASS trigger mapping: " << cases
              << " USB/Bluetooth, event-order, L2/R2 and capability cases; "
                 "one prompt per pull, no hold/jitter/release advances, "
                 "stick mapping and legacy gameplay preserved\n";
  }
  static void run(const fs::path &root) {
    const auto kit = root / "kit", sd = root / "sd", input = root / "input";
    fs::create_directories(kit);
    fs::create_directories(sd / "config/inputs");
    fs::create_directories(input);
    const auto stick = input / "event0", sensor = input / "event1";
    const auto keyboard = input / "event2", mouse = input / "event3";
    auto &pad_device = createNode(stick, gamepad());
    auto &sensor_device = createNode(sensor, sensors());
    Device keys;
    keys.name = "Fixture keyboard";
    keys.id = {BUS_USB, 0x1234, 0x0001, 1};
    createNode(keyboard, keys);
    Device pointer;
    pointer.name = "Fixture relative mouse";
    pointer.id = {BUS_USB, 0x1234, 0x0002, 1};
    createNode(mouse, pointer);

    Host host(kit.string(), (sd / "games/NDS").string(), sd);
    host.scan(input);
    host.menu = false;
    host.spi.history.clear();
    emit(stick, {{EV_ABS, ABS_RX, 224}, {EV_ABS, ABS_RY, 64},
                 {EV_SYN, SYN_REPORT, 0}});
    poll(host);
    assert(lastAnalog(host) == 0xc060);
    const auto before_sensor = host.spi.history.size();
    // Noise while resting and large physical motion must not write a competing
    // near-center/full-scale stylus position or synthesize D-pad presses.
    emit(sensor, {{EV_ABS, ABS_RX, 0}, {EV_ABS, ABS_RY, -200},
                  {EV_SYN, SYN_REPORT, 0}, {EV_ABS, ABS_RX, 1700000},
                  {EV_ABS, ABS_RY, -1700000}, {EV_ABS, ABS_X, 32768},
                  {EV_ABS, ABS_Y, -32768}, {EV_SYN, SYN_REPORT, 0}});
    poll(host);
    assert(host.spi.history.size() == before_sensor &&
           "motion sensor events must never reach SPI or DS buttons");
    assert(lastAnalog(host) == 0xc060 && host.lastjoy == 0);
    assert(host.pads.size() == 3);
    assert(pad_device.property_queries == 1 && sensor_device.property_queries == 1);

    // Ignored sensors must never enter the key-mapping wizard or reset another
    // node's touch/mouse state after a dropped sensor packet.
    host.menu = true;
    host.mapping_step = 0;
    host.mapping_pad.clear();
    emit(sensor, {{EV_ABS, ABS_X, -32768}, {EV_SYN, SYN_REPORT, 0},
                  {EV_SYN, SYN_DROPPED, 0}, {EV_SYN, SYN_REPORT, 0}});
    const auto before_dropped = host.spi.history.size();
    poll(host);
    assert(host.mapping_step == 0 && host.mapping_pad.empty());
    assert(host.spi.history.size() == before_dropped);
    host.mapping_step = -1;
    emit(stick, {{EV_ABS, ABS_RX, 160}, {EV_ABS, ABS_RY, 208},
                 {EV_SYN, SYN_REPORT, 0}});
    host.spi.history.clear();
    poll(host);
    assert(commands(host, 0x3d) == 0);
    host.togglemenu();
    assert(!host.menu && lastAnalog(host) == 0x5020);

    // Rescanning an ignored node is harmless and never duplicates active pads.
    host.spi.history.clear();
    host.scan(input);
    poll(host);
    assert(host.pads.size() == 3 && sensor_device.property_queries == 2);
    assert(host.spi.history.empty());
    fs::remove(sensor);
    host.scan(input);
    assert(host.spi.history.empty());
    auto bluetooth_sensor = sensors();
    bluetooth_sensor.id.bustype = BUS_BLUETOOTH;
    auto &reconnected_sensor = createNode(input / "event4", bluetooth_sensor);
    host.scan(input);
    emit(input / "event4", {{EV_ABS, ABS_RX, 0}, {EV_SYN, SYN_DROPPED, 0},
                           {EV_SYN, SYN_REPORT, 0}});
    poll(host);
    assert(host.pads.size() == 3 && host.spi.history.empty());
    assert(reconnected_sensor.property_queries == 1);

    // The legitimate same-VID/PID pad can reconnect via Bluetooth normally.
    fs::remove(stick);
    host.scan(input);
    assert(host.pads.size() == 2);
    auto bluetooth_pad = gamepad();
    bluetooth_pad.id.bustype = BUS_BLUETOOTH;
    createNode(input / "event5", bluetooth_pad);
    host.scan(input);
    emit(input / "event5", {{EV_ABS, ABS_RX, 255}, {EV_ABS, ABS_RY, 0},
                           {EV_KEY, BTN_SOUTH, 1}, {EV_SYN, SYN_REPORT, 0}});
    poll(host);
    assert(host.pads.size() == 3 && lastAnalog(host) == 0x807f);
    assert(host.lastjoy == (1u << 5));
    emit(input / "event5", {{EV_KEY, BTN_SOUTH, 0}, {EV_SYN, SYN_REPORT, 0}});
    poll(host);
    assert(host.lastjoy == 0);

    emit(keyboard, {{EV_KEY, KEY_X, 1}, {EV_SYN, SYN_REPORT, 0}});
    poll(host);
    assert(host.lastjoy == (1u << 4));
    emit(keyboard, {{EV_KEY, KEY_X, 0}, {EV_SYN, SYN_REPORT, 0}});
    poll(host);
    assert(host.lastjoy == 0);
    host.spi.history.clear();
    emit(mouse, {{EV_REL, REL_X, 12}, {EV_REL, REL_Y, -7},
                 {EV_KEY, BTN_LEFT, 1}, {EV_SYN, SYN_REPORT, 0}});
    poll(host);
    assert(commands(host, 4) == 1);
    assert(host.spi.history.back().words == std::vector<uint16_t>({9, 12, 7}));
    emit(mouse, {{EV_KEY, BTN_LEFT, 0}, {EV_SYN, SYN_REPORT, 0}});
    poll(host);
    assert(host.spi.history.back().words == std::vector<uint16_t>({8, 0, 0}));

    // An unsupported property ioctl preserves legacy devices. Avoid imposing
    // a vendor blacklist or requiring successful property reads for all pads.
    auto legacy = gamepad();
    legacy.name = "Legacy gamepad without property ioctl";
    legacy.id = {BUS_USB, 0x1234, 0x0003, 1};
    legacy.properties_supported = false;
    auto &legacy_device = createNode(input / "event6", legacy);
    host.scan(input);
    emit(input / "event6", {{EV_ABS, ABS_RX, 192}, {EV_ABS, ABS_RY, 96},
                           {EV_SYN, SYN_REPORT, 0}});
    poll(host);
    assert(host.pads.size() == 4 && legacy_device.property_queries == 1);
    assert(lastAnalog(host) == 0xe040);
    std::cout << "PASS actual evdev discovery: DualSense gyro exclusion, resting "
                 "noise/large motion, mapping/drop isolation, menu restore, "
                 "USB/Bluetooth rescan/reconnect, buttons, keyboard, mouse, "
                 "property-ioctl fallback\n";
  }
};

int main() {
  char directory[] = "/tmp/nds-motion-input-XXXXXX";
  assert(mkdtemp(directory));
  HostTest::run(directory);
  HostTest::triggerMappings(fs::path(directory) / "triggers");
  fs::remove_all(directory);
}

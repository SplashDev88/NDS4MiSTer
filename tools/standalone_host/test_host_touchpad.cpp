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
  std::array<unsigned long, (KEY_CNT + word_bits - 1) / word_bits> held{};
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

[[maybe_unused]] Device sensors() {
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
  if (_IOC_TYPE(request) == 'E' && _IOC_NR(request) == _IOC_NR(EVIOCGKEY(1))) {
    std::memset(argument, 0, _IOC_SIZE(request));
    std::memcpy(argument, device.held.data(),
                std::min(size_t(_IOC_SIZE(request)), sizeof(device.held)));
    return std::min(size_t(_IOC_SIZE(request)), sizeof(device.held));
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
 static Device pointer(unsigned product=0x0ce6,unsigned bus=BUS_USB) {
  Device d;d.name="Sony Wireless Controller Touchpad";
  d.id={uint16_t(bus),0x054c,uint16_t(product),0x8100};
  d.properties=(1UL<<INPUT_PROP_POINTER)|(1UL<<INPUT_PROP_BUTTONPAD);
  const int height=product==0x05c4||product==0x09cc?942:1080;
  d.axes[ABS_X]=d.axes[ABS_MT_POSITION_X]={800,0,1919,0,0,0};
  d.axes[ABS_Y]=d.axes[ABS_MT_POSITION_Y]={400,0,height-1,0,0,0};
  d.axes[ABS_MT_SLOT]={0,0,1,0,0,0};d.axes[ABS_MT_TRACKING_ID]={0,0,65535,0,0,0};
  for(int key:{BTN_LEFT,BTN_TOUCH,BTN_TOOL_FINGER,BTN_TOOL_DOUBLETAP})d.setKey(key);
  return d;
 }
 static std::vector<std::vector<uint16_t>> mouse(Host &h) {
  std::vector<std::vector<uint16_t>> result;
  for(const auto &t:h.spi.history)if(t.select==Spi::IO&&t.command==4)result.push_back(t.words);
  h.spi.history.clear();return result;
 }
 static void poll(Host &h) {errno=0;h.inputs();}
 static void packet(Host &h,const fs::path &node,std::initializer_list<std::array<int,3>> rows) {
  emit(node,rows);emit(node,{{EV_SYN,SYN_REPORT,0}});poll(h);
  assert(h.lastjoy==0 && h.pads[0].joy==0 && !h.pads[0].touch_analog_valid);
 }
 static void contact(Host &h,const fs::path &node,int id,int x,int y) {
  packet(h,node,{{EV_ABS,ABS_MT_TRACKING_ID,id},{EV_KEY,BTN_TOUCH,1},{EV_KEY,BTN_TOOL_FINGER,1},
   {EV_ABS,ABS_MT_POSITION_X,x},{EV_ABS,ABS_MT_POSITION_Y,y},{EV_ABS,ABS_X,x},{EV_ABS,ABS_Y,y}});
 }
 static void check(const fs::path &root,unsigned product,unsigned bus) {
  auto input=root/"input",kit=root/"kit",sd=root/"sd";fs::create_directories(input);fs::create_directories(kit);
  const auto node=input/"event0";auto &d=createNode(node,pointer(product,bus));
  Host h(kit.string(),(sd/"games/NDS").string(),sd);h.scan(input);
  assert(h.pads.size()==1 && h.pads[0].touchpad.enabled && !h.pads[0].pad);
  h.menu=false;h.spi.history.clear();
  contact(h,node,1,800,400);assert(mouse(h).empty());
  packet(h,node,{{EV_ABS,ABS_MT_POSITION_X,860},{EV_ABS,ABS_MT_POSITION_Y,430},
   {EV_ABS,ABS_X,860},{EV_ABS,ABS_Y,430}});
  assert(mouse(h)==std::vector<std::vector<uint16_t>>({{40,10,251}})); // +10,+5; no double counting
  // Fractional movement survives six small reports, even around zero.
  unsigned reports=0;
  for(int x=861;x<=866;++x){packet(h,node,{{EV_ABS,ABS_X,x}});auto m=mouse(h);if(!m.empty()){++reports;assert(m[0]==std::vector<uint16_t>({8,1,0}));}}
  assert(reports==1);
  packet(h,node,{{EV_KEY,BTN_LEFT,1}});assert(mouse(h)==std::vector<std::vector<uint16_t>>({{9,0,0}}));
  packet(h,node,{{EV_ABS,ABS_X,854}});assert(mouse(h)==std::vector<std::vector<uint16_t>>({{25,254,0}}));
  packet(h,node,{{EV_KEY,BTN_LEFT,0}});assert(mouse(h)==std::vector<std::vector<uint16_t>>({{8,0,0}}));
  // Lift, re-touch at a different position, and single-contact handover.
  packet(h,node,{{EV_ABS,ABS_MT_TRACKING_ID,-1},{EV_KEY,BTN_TOUCH,0},{EV_KEY,BTN_TOOL_FINGER,0}});assert(mouse(h).empty());
  contact(h,node,2,100,100);assert(mouse(h).empty());
  contact(h,node,3,1800,800);assert(mouse(h).empty());
  packet(h,node,{{EV_ABS,ABS_X,1794}});assert(mouse(h)==std::vector<std::vector<uint16_t>>({{24,255,0}}));
  // Two fingers freeze motion. Return to one finger reanchors without jumps.
  packet(h,node,{{EV_ABS,ABS_MT_SLOT,1},{EV_ABS,ABS_MT_TRACKING_ID,4},
   {EV_KEY,BTN_TOOL_FINGER,0},{EV_KEY,BTN_TOOL_DOUBLETAP,1},{EV_ABS,ABS_X,50}});assert(mouse(h).empty());
  packet(h,node,{{EV_ABS,ABS_X,150}});assert(mouse(h).empty());
  packet(h,node,{{EV_ABS,ABS_MT_TRACKING_ID,-1},{EV_KEY,BTN_TOOL_DOUBLETAP,0},
   {EV_KEY,BTN_TOOL_FINGER,1},{EV_ABS,ABS_X,600}});assert(mouse(h).empty());
  packet(h,node,{{EV_ABS,ABS_X,606}});assert(mouse(h)==std::vector<std::vector<uint16_t>>({{8,1,0}}));
  // Menu transitions and reset release a held click and rebase motion.
  packet(h,node,{{EV_KEY,BTN_LEFT,1}});mouse(h);h.togglemenu();mouse(h);
  int cursor=h.cursor;
  packet(h,node,{{EV_ABS,ABS_X,1800},{EV_ABS,ABS_Y,900}});
  assert(mouse(h).empty() && h.cursor==cursor);
  h.togglemenu();mouse(h);packet(h,node,{{EV_ABS,ABS_X,100}});assert(mouse(h).empty());
  packet(h,node,{{EV_ABS,ABS_X,106}});assert(mouse(h)==std::vector<std::vector<uint16_t>>({{8,1,0}}));
  packet(h,node,{{EV_KEY,BTN_LEFT,1}});mouse(h);h.clearConsoleInputs();mouse(h);
  packet(h,node,{{EV_ABS,ABS_X,1500}});assert(mouse(h).empty());
  packet(h,node,{{EV_ABS,ABS_X,1506}});assert(mouse(h)==std::vector<std::vector<uint16_t>>({{8,1,0}}));
  // Drop: release, ignore buffered motion/clicks, requery contact and anchor.
  packet(h,node,{{EV_KEY,BTN_LEFT,1}});mouse(h);
  d.held[BTN_TOUCH/Device::word_bits]|=1UL<<(BTN_TOUCH%Device::word_bits);
  d.held[BTN_TOOL_FINGER/Device::word_bits]|=1UL<<(BTN_TOOL_FINGER%Device::word_bits);
  emit(node,{{EV_SYN,SYN_DROPPED,0},{EV_ABS,ABS_X,50},{EV_KEY,BTN_LEFT,1},{EV_SYN,SYN_REPORT,0}});poll(h);
  assert(mouse(h)==std::vector<std::vector<uint16_t>>({{8,0,0}}));
  packet(h,node,{{EV_ABS,ABS_X,100}});assert(mouse(h).empty());
  packet(h,node,{{EV_ABS,ABS_X,106}});assert(mouse(h)==std::vector<std::vector<uint16_t>>({{8,1,0}}));
  // Rotation uses the same downstream mouse path, with click state retained.
  h.touch_rotation=TouchRotation::Clockwise; // Right becomes down.
  packet(h,node,{{EV_KEY,BTN_LEFT,1},{EV_ABS,ABS_X,166}});
  assert(mouse(h)==std::vector<std::vector<uint16_t>>({{41,0,246}}));
  // The separate controller can still map buttons while the touchpad is active.
  h.menu=true;h.mapping_step=0;h.mapping_ready=true;h.mapping_pending=false;
  packet(h,node,{{EV_ABS,ABS_X,1919},{EV_KEY,BTN_TOUCH,0},{EV_KEY,BTN_LEFT,0}});
  assert(h.mapping_step==0 && h.mapping_pad.empty() && mouse(h).empty());
  h.mapping_step=-1;h.menu=false;
  // Disconnect releases the click without sending a stick recenter packet.
  packet(h,node,{{EV_KEY,BTN_LEFT,1}});mouse(h);fs::remove(node);h.scan(input);
  assert(h.pads.empty());for(const auto &t:h.spi.history)assert(t.command!=0x3d);
  assert(mouse(h)==std::vector<std::vector<uint16_t>>({{8,0,0}}));
  createNode(node,d);h.scan(input);h.spi.history.clear();
  packet(h,node,{{EV_ABS,ABS_X,1800},{EV_ABS,ABS_Y,900}});assert(mouse(h).empty());
 }
 static void classification(const fs::path &root) {
  auto input=root/"input",kit=root/"kit";fs::create_directories(input);fs::create_directories(kit);
  auto direct=pointer();direct.properties|=1UL<<INPUT_PROP_DIRECT;createNode(input/"event0",direct);
  auto other=pointer();other.id.vendor=0x1234;createNode(input/"event1",other);
  createNode(input/"event2",gamepad());createNode(input/"event3",sensors());
  Host h(kit.string(),(root/"sd/games/NDS").string(),root/"sd");h.scan(input);
  assert(h.pads.size()==3);for(const auto &p:h.pads)assert(!p.touchpad.enabled);
 }
 static void sensitivity(const fs::path &root) {
  auto input=root/"input",kit=root/"kit",sd=root/"sd";
  fs::create_directories(input);fs::create_directories(kit);
  const auto node=input/"event0",config=kit/"NDS_touchpad.cfg";
  createNode(node,pointer());Host h(kit.string(),(sd/"games/NDS").string(),sd);h.scan(input);
  assert(h.touchpad_sensitivity==nds_touchpad::DEFAULT_SENSITIVITY && !fs::exists(config));
  const auto status=h.status;const auto full_status=h.full_status;
  // Reach the setting on the first page in both current and legacy layouts.
  for(int mode=0;mode<3;++mode) {
   h.independent_outputs_supported=mode==2;
   h.status=status|(mode==1?CRT_TIMING:0);h.cursor=0;
   for(int n=0;n<20 && h.cursor!=Host::TOUCHPAD_SENSITIVITY_CURSOR;++n)h.action(1);
   assert(h.cursor==Host::TOUCHPAD_SENSITIVITY_CURSOR && !h.system_menu && !h.display_menu);
   h.draw();const int row=mode==2?8:10;
   if(mode==2)assert(h.osd_rows[6]==h.frame.renderRow(6,"",false,nds_osd::arrow_right));
   assert(h.osd_rows[row]==h.frame.renderRow(row,touchpadSensitivityLabel(100),true,nds_osd::arrow_right));
   h.action(6);assert(h.system_menu && h.cursor==0);
   for(const auto &r:h.system_rows)assert(r.text.find("Touchpad")==std::string::npos);
   h.action(5);assert(!h.system_menu && h.cursor==0);
  }
  h.independent_outputs_supported=false;h.status=status;h.cursor=Host::TOUCHPAD_SENSITIVITY_CURSOR;
  assert(h.touchpad_sensitivity==0);
  h.action(7);assert(h.touchpad_sensitivity==5);h.action(8);assert(h.touchpad_sensitivity==0);
  for(unsigned i=0;i<nds_touchpad::SENSITIVITY_PERCENT.size();++i) {
   if(!h.menu){h.togglemenu();h.cursor=Host::TOUCHPAD_SENSITIVITY_CURSOR;}
   while(h.touchpad_sensitivity!=i)h.action(2);
   h.draw();
   assert(h.osd_rows[10]==h.frame.renderRow(10,
     touchpadSensitivityLabel(nds_touchpad::SENSITIVITY_PERCENT[i]),true,nds_osd::arrow_right));
   assert(h.status==status && h.full_status==full_status && !fs::exists(config));
   h.togglemenu();mouse(h);contact(h,node,10+i,800,400);assert(mouse(h).empty());
   // Single sensor-unit reports retain fractional movement at every speed.
   int total_x=0,total_y=0;
   for(int step=1;step<=24;++step) {
    packet(h,node,{{EV_ABS,ABS_X,800+step},{EV_ABS,ABS_Y,400-step}});
    for(const auto &m:mouse(h)){total_x+=int8_t(m[1]);total_y+=int8_t(m[2]);}
   }
   assert(total_x==int(nds_touchpad::SENSITIVITY_PERCENT[i]/25) && total_y==total_x);
   packet(h,node,{{EV_KEY,BTN_LEFT,1}});assert(mouse(h)==std::vector<std::vector<uint16_t>>({{9,0,0}}));
   total_x=total_y=0;
   for(int step=1;step<=24;++step) {
    packet(h,node,{{EV_ABS,ABS_X,824-step},{EV_ABS,ABS_Y,376+step}});
    for(const auto &m:mouse(h)){assert((m[0]&1)==1);total_x+=int8_t(m[1]);total_y+=int8_t(m[2]);}
   }
   assert(total_x==-int(nds_touchpad::SENSITIVITY_PERCENT[i]/25) && total_y==total_x);
   packet(h,node,{{EV_KEY,BTN_LEFT,0}});assert(mouse(h)==std::vector<std::vector<uint16_t>>({{8,0,0}}));
  }
  // A separate relative mouse retains its speed at maximum touchpad gain.
  Device ordinary;ordinary.name="Ordinary mouse";const auto mouse_node=input/"event1";
  createNode(mouse_node,ordinary);h.scan(input);mouse(h);
  packet(h,mouse_node,{{EV_REL,REL_X,6},{EV_REL,REL_Y,-3}});
  assert(mouse(h)==std::vector<std::vector<uint16_t>>({{8,6,3}}));
  h.togglemenu();h.action(6);h.cursor=3;h.action(2);
  {Host restored(kit.string(),(sd/"games/NDS").string(),sd);assert(restored.touchpad_sensitivity==5);}
  assert(std::ifstream(config).good());
  h.action(6);h.cursor=2;h.action(2);h.action(0);h.action(2);
  assert(h.touchpad_sensitivity==nds_touchpad::DEFAULT_SENSITIVITY);
  {Host restored(kit.string(),(sd/"games/NDS").string(),sd);assert(restored.touchpad_sensitivity==nds_touchpad::DEFAULT_SENSITIVITY);}
  for(const char *bad:{"","NDS-Touchpad-v1\n0\n","NDS-Touchpad-v1\n-100\n",
   "NDS-Touchpad-v1\n25\n","NDS-Touchpad-v1\n50\n","NDS-Touchpad-v1\n75\n",
   "NDS-Touchpad-v1\n999999999\n","NDS-Touchpad-v2\n200\n","NDS-Touchpad-v1\n200\nextra"}) {
   std::ofstream(config)<<bad;Host invalid(kit.string(),(sd/"games/NDS").string(),sd);
   assert(invalid.touchpad_sensitivity==nds_touchpad::DEFAULT_SENSITIVITY);
  }
  std::cout<<"PASS touchpad sensitivity: all six speeds, fractional motion, reverse/drag, ordinary mouse isolation, first-menu access in three layouts, save/reload/reset/removed and invalid values\n";
 }
 static void replay(const fs::path &root,const char *path) {
  auto input=root/"input",kit=root/"kit";fs::create_directories(input);fs::create_directories(kit);
  auto node=input/"event0";createNode(node,pointer(0x0ce6,BUS_BLUETOOTH));
  Host h(kit.string(),(root/"sd/games/NDS").string(),root/"sd");h.scan(input);h.menu=false;h.spi.history.clear();
  std::ifstream in(path);assert(in);int type,code,value;unsigned motion=0,clicks=0,reports=0;
  while(in>>type>>code>>value){emit(node,{{type,code,value}});if(type!=EV_SYN||code!=SYN_REPORT)continue;
   poll(h);++reports;assert(h.lastjoy==0 && h.pads[0].joy==0);
   for(const auto &m:mouse(h)){if(m[1]||m[2])++motion;else ++clicks;}
  }
  assert(reports==1298 && motion>100 && clicks==2);
  std::cout<<"PASS physical DualSense trace: reports="<<reports<<" motion_packets="<<motion<<" click_release="<<clicks<<" dpad=0\n";
 }
};
int main(int argc,char **argv){
 char root[]="/tmp/nds-touchpad-test-XXXXXX";assert(mkdtemp(root));
 for(unsigned id:{0x05c4u,0x09ccu,0x0ce6u,0x0df2u})for(unsigned bus:{BUS_USB,BUS_BLUETOOTH})
  HostTest::check(fs::path(root)/(std::to_string(id)+"-"+std::to_string(bus)),id,bus);
 HostTest::classification(fs::path(root)/"classification");
 HostTest::sensitivity(fs::path(root)/"sensitivity");
 if(argc>1)HostTest::replay(fs::path(root)/"replay",argv[1]);
 fs::remove_all(root);
 std::cout<<"PASS Sony touchpad: 8 USB/Bluetooth device profiles, motion/precision/click/drag, lift/handover/multifinger, rotation, menu/reset/drop/reconnect, mapping and classification\n";
}

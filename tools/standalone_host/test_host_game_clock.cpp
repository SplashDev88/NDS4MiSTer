// SPDX-License-Identifier: GPL-3.0-or-later
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>
struct HostTest {
  struct Device {
    Host &h;
    nds_clock::Date live{0,1,1,6,0,0,0};
    std::array<uint8_t,8> captured{},seed{};
    uint32_t sequence=0,captured_sequence=0;
    unsigned seeds=0,requests=0;
    bool ready=false,old=false,stuck=false;
    explicit Device(Host &host):h(host) {
      h.spi.response=[&](uint32_t select,uint16_t command,size_t pos,uint16_t value)->uint16_t {
        assert(select==Spi::IO);
        if(command==0x22 && pos) {
          seed[(pos-1)*2]=uint8_t(value);seed[(pos-1)*2+1]=uint8_t(value>>8);
          if(pos==4){++seeds;live=nds_clock::unpack(seed);}
          return 0;
        }
        if(command!=0x47 || old) return 0;
        if(!pos)return 0x5254;
        if(pos==1) {
          const auto flags=uint16_t(0x100 | (ready && !stuck));
          if(value==1){captured=nds_clock::pack(live);captured_sequence=sequence;ready=true;++requests;}
          return flags;
        }
        if(pos<=5)return uint16_t(captured[(pos-2)*2]) | uint16_t(captured[(pos-2)*2+1])<<8;
        return pos==6 ? uint16_t(captured_sequence) : uint16_t(captured_sequence>>16);
      };
    }
    ~Device(){h.spi.response={};}
  };
  template<class F> static void rejects(F f){bool bad=false;try{f();}catch(const std::exception&){bad=true;}assert(bad);}
  static void run(const fs::path &base) {
    fs::create_directories(base/"kit");
    const nds_clock::Date now{26,10,14,3,13,15,42},edit{45,2,28,2,23,59,59};
    {
      Host h((base/"kit").string(),(base/"roms").string(),base/"sd");Device d(h);
      h.game_clock_now=[&]{return now;};
      d.old=true;rejects([&]{h.seedGameClock();});assert(!d.seeds && !h.spi.selected && !h.game_clock_seeded);
      d.old=false;h.seedGameClock();assert(d.seeds==1 && d.live==now);
      h.seedGameClock();assert(d.seeds==1);
      assert(!fs::exists(h.gameClockPath()));
      h.serviceGameClock();h.serviceGameClock();assert(!fs::exists(h.gameClockPath()));
      // Two complete guest writes between polls. The count, not toggle parity,
      // detects the edit; 2045 does not pass through ARM's old 32-bit time_t.
      d.live=edit;d.sequence=2;h.flushGameClock();
      const auto read=[&]{std::ifstream f(h.gameClockPath());return std::string(std::istreambuf_iterator<char>(f),{});};
      const auto original=read();assert(nds_clock::Offset::parse(original).apply(now)==edit);
      assert(h.game_clock_sequence==2 && d.seeds==1);
      // Atomic-write failure keeps the old file and sequence, then retries the
      // same capture after wall time has changed, preserving its offset.
      fs::create_directory(h.gameClockPath().string()+".new");
      d.live[6]=58;++d.sequence;rejects([&]{h.flushGameClock();});
      assert(h.game_clock_sequence==2 && read()==original && h.game_clock_pending);
      const auto failed_time=h.game_clock_request_time;
      h.game_clock_now=[&]{return nds_clock::date(nds_clock::seconds(now)+120);};
      fs::remove(h.gameClockPath().string()+".new");h.serviceGameClock();
      assert(h.game_clock_sequence==3);
      assert(nds_clock::Offset::parse(read()).apply(failed_time)==d.live);
      // Read-only snapshots/elapsed ticks never cause extra durable writes.
      const auto stable=read();d.live[6]=59;h.flushGameClock();assert(read()==stable);
      d.stuck=true;rejects([&]{h.waitGameClock();});assert(!h.spi.selected);
    }
    {
      // A new host/FPGA session advances the saved edited time while powered off.
      Host h((base/"kit").string(),(base/"roms").string(),base/"sd");Device d(h);
      h.game_clock_now=[&]{return nds_clock::date(nds_clock::seconds(now)+86400);};
      h.seedGameClock();assert((d.live==nds_clock::Date{45,3,1,3,23,59,58}));
    }
    {
      std::ofstream(base/"kit/NDS_rtc.cfg")<<"damaged";
      Host h((base/"kit").string(),(base/"roms").string(),base/"sd");Device d(h);
      h.game_clock_now=[&]{return now;};
      rejects([&]{h.seedGameClock();});assert(d.seeds==0 && !h.game_clock_seeded);
    }
    {
      // A late host time correction does not reseed the running DS. Without a
      // guest clock edit it must not fabricate a persistent offset, either.
      const auto kit=base/"late-sync";fs::create_directories(kit);
      nds_clock::Date wall{20,1,1,3,0,0,0};
      {
        Host h(kit.string(),(base/"roms").string(),base/"sd");Device d(h);
        h.game_clock_now=[&]{return wall;};h.seedGameClock();
        const auto initial=d.live;
        for(const auto &corrected:{nds_clock::Date{26,10,14,3,13,0,0},
                                  nds_clock::Date{26,10,14,3,8,0,0}}) {
          wall=corrected;h.seedGameClock();h.flushGameClock();
          assert(d.seeds==1 && d.live==initial);
          assert(!fs::exists(h.gameClockPath()));
        }
      }
      Host h(kit.string(),(base/"roms").string(),base/"sd");Device d(h);
      h.game_clock_now=[&]{return wall;};h.seedGameClock();
      assert(d.live==wall && d.seeds==1);
    }
    {
      // A long offline interval and a host timezone/DST adjustment apply to
      // the next launch's local-clock basis without modifying stored settings.
      const auto kit=base/"long-offline";fs::create_directories(kit);
      const std::string saved="NDS-RTC-v1\n3600\n0\n";
      std::ofstream(kit/"NDS_rtc.cfg")<<saved;
      for(const auto &wall:{nds_clock::Date{26,10,14,3,13,0,0},
                           nds_clock::Date{27,4,12,1,13,0,0},
                           nds_clock::Date{27,4,12,1,12,0,0}}) {
        Host h(kit.string(),(base/"roms").string(),base/"sd");Device d(h);
        h.game_clock_now=[&]{return wall;};h.seedGameClock();
        auto expected=wall;++expected[4];assert(d.live==expected);
        h.flushGameClock();
        std::ifstream in(kit/"NDS_rtc.cfg");
        assert(std::string(std::istreambuf_iterator<char>(in),{})==saved);
      }
    }
    std::cout<<"PASS RTC matched core, single seed, edit capture, durable offset, storage failure/retry, restart, malformed config, late synchronization, timezone shift and 180-day offline interval\n";
  }
};
int main(){auto root=fs::temp_directory_path()/("nds-clock-"+std::to_string(getpid()));
  HostTest::run(root);fs::remove_all(root);}

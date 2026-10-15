// SPDX-License-Identifier: GPL-3.0-or-later
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>
// Only this executable overrides wall time; never change the machine clock.
static std::time_t clock_fixture=1792000800LL;
extern "C" std::time_t time(std::time_t *out) noexcept {
  if(out) *out=clock_fixture;
  return clock_fixture;
}
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
    assert(setenv("TZ","UTC0",1)==0);tzset();
    {
      const auto kit=base/"fallback-damaged";fs::create_directories(kit);
      clock_fixture=0;
      for(const auto &text:{"damaged", "NDS-RTC-v2\noffline\n26 2 29 0 0 0 0\n"}) {
        std::ofstream(kit/"NDS_rtc.cfg")<<text;
        Host h(kit.string(),(base/"roms").string(),base/"sd");Device d(h);
        rejects([&]{h.seedGameClock();});assert(!d.seeds && !h.game_clock_seeded);
        std::ifstream in(h.gameClockPath());assert(std::string(std::istreambuf_iterator<char>(in),{})==text);
      }
    }
    for (const auto unavailable:{-1LL,0LL,946684799LL,4102444800LL}) {
      const auto kit=base/("fallback-"+std::to_string(unavailable));fs::create_directories(kit);
      clock_fixture=unavailable;
      {
        Host h(kit.string(),(base/"roms").string(),base/"sd");Device d(h);
        uint64_t elapsed=100;h.game_clock_millis=[&]{return elapsed;};
        h.seedGameClock();assert(d.live==nds_clock::date(0) && h.game_clock_fallback);
        elapsed+=86401000;d.live=nds_clock::date(86401);
        assert(h.gameClockNow()==d.live);
        clock_fixture=1792000800LL; // NTP arrives during the fallback session.
        h.seedGameClock();h.flushGameClock();
        assert(d.seeds==1 && d.live==nds_clock::date(86401));
        assert(!fs::exists(h.gameClockPath()));
      }
      Host h(kit.string(),(base/"roms").string(),base/"sd");Device d(h);
      h.seedGameClock();assert(d.live==nds_clock::localNow() && !h.game_clock_fallback);
    }
    {
      // Offline boot preserves an existing legacy offset byte-for-byte until
      // the guest explicitly edits the clock. Valid-clock boot still applies it.
      const auto kit=base/"fallback-legacy";fs::create_directories(kit);
      const std::string saved="NDS-RTC-v1\n3600\n0\n";
      std::ofstream(kit/"NDS_rtc.cfg")<<saved;
      clock_fixture=0;
      {
        Host h(kit.string(),(base/"roms").string(),base/"sd");Device d(h);
        h.seedGameClock();assert(d.live==nds_clock::date(3600));h.flushGameClock();
        std::ifstream in(h.gameClockPath());assert(std::string(std::istreambuf_iterator<char>(in),{})==saved);
      }
      clock_fixture=1792000800LL;
      Host h(kit.string(),(base/"roms").string(),base/"sd");Device d(h);
      h.seedGameClock();assert(d.live==nds_clock::date(nds_clock::seconds(nds_clock::localNow())+3600));
    }
    {
      const auto kit=base/"fallback-edited";fs::create_directories(kit);
      const auto path=kit/"NDS_rtc.cfg";
      const auto read=[&]{std::ifstream f(path);return std::string(std::istreambuf_iterator<char>(f),{});};
      clock_fixture=0;nds_clock::Date last;
      {
        Host h(kit.string(),(base/"roms").string(),base/"sd");Device d(h);
        uint64_t elapsed=0;h.game_clock_millis=[&]{return elapsed;};
        h.seedGameClock();elapsed=60000;d.live=edit;d.sequence=2;h.flushGameClock();
        assert(nds_clock::Setting::parse(read()).clock==edit);
        const auto saved=read();
        d.live=nds_clock::date(nds_clock::seconds(edit)+10,1);h.serviceGameClock();h.serviceGameClock();
        assert(read()==saved); // No disk write on ordinary ticks/polls.
        fs::create_directory(path.string()+".new");++d.sequence;
        rejects([&]{h.flushGameClock();});assert(read()==saved && h.game_clock_sequence==2);
        clock_fixture=1792000800LL;elapsed+=120000;
        fs::remove(path.string()+".new");h.serviceGameClock();
        assert(nds_clock::Setting::parse(read()).clock==d.live && h.game_clock_sequence==3);
        d.live=nds_clock::date(nds_clock::seconds(d.live)+120,1);last=d.live;
        const auto before_checkpoint=read();fs::create_directory(path.string()+".new");
        rejects([&]{h.flushGameClock();});
        assert(read()==before_checkpoint && h.game_clock_checkpoint_pending);
        fs::remove(path.string()+".new");h.serviceGameClock();
        assert(nds_clock::Setting::parse(read()).clock==last && !h.game_clock_checkpoint_pending);
      }
      clock_fixture=0;
      {
        Host h(kit.string(),(base/"roms").string(),base/"sd");Device d(h);
        h.seedGameClock();assert(d.live==last && h.game_clock_fallback);
        h.flushGameClock();assert(nds_clock::Setting::parse(read()).clock==last);
      }
      clock_fixture=1792000800LL;
      {
        Host h(kit.string(),(base/"roms").string(),base/"sd");Device d(h);
        const auto saved=read();fs::create_directory(path.string()+".new");
        rejects([&]{h.seedGameClock();});assert(read()==saved && !h.game_clock_seeded);
        fs::remove(path.string()+".new");h.seedGameClock();
        assert(d.live==last && !h.game_clock_fallback);
        assert(nds_clock::Offset::parse(read()).apply(nds_clock::localNow())==last);
      }
      clock_fixture+=86400;
      Host h(kit.string(),(base/"roms").string(),base/"sd");Device d(h);
      h.seedGameClock();const auto offset=nds_clock::Offset::between(last,nds_clock::date(nds_clock::seconds(nds_clock::localNow())-86400));
      assert(d.live==offset.apply(nds_clock::localNow()));
    }
    std::cout<<"PASS RTC matched core, single seed, edit capture, durable offset, failure/retry, restart, malformed config, DST/offline elapsed time, invalid-clock fallback, late sync and offline-edit migration\n";
  }
};
int main(){auto root=fs::temp_directory_path()/("nds-clock-"+std::to_string(getpid()));
  HostTest::run(root);fs::remove_all(root);}

// SPDX-License-Identifier: GPL-3.0-or-later
// DS civil time, independent of time_t's range and host timezone/DST arithmetic.
#pragma once
#include <array>
#include <cstdint>
#include <ctime>
#include <sstream>
#include <stdexcept>
#include <string>
namespace nds_clock {
constexpr int64_t century_seconds = 36525LL * 86400;
using Date = std::array<unsigned, 7>; // year (0..99), month, day, weekday, hour, minute, second
inline unsigned monthDays(unsigned year, unsigned month) {
  static constexpr unsigned days[] = {31,28,31,30,31,30,31,31,30,31,30,31};
  return days[month - 1] + (month == 2 && year % 4 == 0);
}
inline void validate(const Date &d) {
  if (d[0] > 99 || d[1] < 1 || d[1] > 12 || d[2] < 1 ||
      d[2] > monthDays(d[0], d[1]) || d[3] > 6 || d[4] > 23 || d[5] > 59 || d[6] > 59)
    throw std::runtime_error("Invalid DS clock date");
}
inline int64_t seconds(const Date &d) {
  validate(d);
  int64_t days = 0;
  for (unsigned y=0;y<d[0];++y) days += y%4 ? 365 : 366;
  for (unsigned m=1;m<d[1];++m) days += monthDays(d[0],m);
  days += d[2]-1;
  return days*86400 + d[4]*3600 + d[5]*60 + d[6];
}
inline int64_t mod(int64_t value,int64_t modulus) {
  return (value % modulus + modulus) % modulus;
}
inline Date date(int64_t value, unsigned weekday_adjustment = 0) {
  // Keep the unwrapped day count for weekday continuity at 2099 -> 2000.
  const int64_t day_count = value >= 0 ? value/86400 : (value-86399)/86400;
  value=mod(value,century_seconds);
  Date d{0,1,1,unsigned(mod(day_count+6+weekday_adjustment,7)),
         unsigned(value%86400/3600),unsigned(value%3600/60),unsigned(value%60)};
  unsigned days=unsigned(value/86400);
  while(days >= (d[0]%4 ? 365u : 366u)) {days-=d[0]%4 ? 365u : 366u;++d[0];}
  while(days >= monthDays(d[0],d[1])) {days-=monthDays(d[0],d[1]);++d[1];}
  d[2]+=days;
  return d;
}
inline std::array<uint8_t,8> pack(const Date &d) {
  validate(d);std::array<uint8_t,8> result{};
  for(unsigned i=0;i<7;++i) result[i]=uint8_t(d[i]/10*16+d[i]%10);
  return result;
}
inline Date unpack(const std::array<uint8_t,8> &bytes) {
  Date d{};
  if(bytes[7]) throw std::runtime_error("Invalid DS clock snapshot padding");
  for(unsigned i=0;i<7;++i) {
    if((bytes[i]&15)>9 || (bytes[i]>>4)>9) throw std::runtime_error("Invalid DS clock BCD");
    d[i]=(bytes[i]>>4)*10+(bytes[i]&15);
  }
  validate(d);return d;
}
struct Unavailable : std::runtime_error {
  Unavailable() : std::runtime_error("MiSTer clock is unavailable or outside 2000–2099") {}
};
inline Date localNow() {
  const auto now=std::time(nullptr);std::tm t{};
  if(now==std::time_t(-1) || !localtime_r(&now,&t) || t.tm_year<100 || t.tm_year>199)
    throw Unavailable();
  return Date{unsigned(t.tm_year-100),unsigned(t.tm_mon+1),unsigned(t.tm_mday),
              unsigned(t.tm_wday),unsigned(t.tm_hour),unsigned(t.tm_min),unsigned(t.tm_sec>59?59:t.tm_sec)};
}
struct Offset {
  int64_t seconds=0;
  unsigned weekday=0;
  Date apply(const Date &now) const {return date(nds_clock::seconds(now)+seconds,weekday);}
  static Offset between(const Date &clock,const Date &now) {
    const auto time=nds_clock::seconds(clock);
    return {time-nds_clock::seconds(now),unsigned(mod(int64_t(clock[3])-date(time)[3],7))};
  }
  std::string serialize() const {
    return "NDS-RTC-v1\n"+std::to_string(seconds)+"\n"+std::to_string(weekday)+"\n";
  }
  static Offset parse(const std::string &text) {
    std::istringstream stream(text);std::string header,extra;Offset value;
    if(!std::getline(stream,header) || header!="NDS-RTC-v1" ||
       !(stream>>value.seconds>>value.weekday) || (stream>>extra) ||
       value.seconds<=-century_seconds || value.seconds>=century_seconds || value.weekday>6)
      throw std::runtime_error("Invalid NDS_rtc.cfg; restore it or remove it to use the MiSTer clock");
    return value;
  }
};
// Existing offsets remain v1. A guest edit made without a usable wall clock
// needs an absolute calendar instead: it cannot safely be applied to a later
// synchronized wall clock as an offset from the fallback year 2000.
struct Setting {
  Offset offset;
  bool offline = false;
  Date clock{};
  static Setting savedOffline(const Date &value) {
    validate(value);return {{},true,value};
  }
  std::string serialize() const {
    if (!offline) return offset.serialize();
    validate(clock);
    std::ostringstream out;out<<"NDS-RTC-v2\noffline\n";
    for (unsigned v:clock) out<<v<<' ';
    out<<'\n';return out.str();
  }
  static Setting parse(const std::string &text) {
    std::istringstream in(text);std::string header,mode,extra;Setting value;
    std::getline(in,header);
    if (header!="NDS-RTC-v2") {value.offset=Offset::parse(text);return value;}
    if (!std::getline(in,mode) || mode!="offline")
      throw std::runtime_error("Invalid NDS_rtc.cfg offline clock");
    for (auto &v:value.clock)
      if (!(in>>v)) throw std::runtime_error("Invalid NDS_rtc.cfg offline date");
    if (in>>extra) throw std::runtime_error("Invalid NDS_rtc.cfg offline fields");
    validate(value.clock);value.offline=true;return value;
  }
};
struct Snapshot {
  bool ready=false;
  std::array<uint8_t,8> bytes{};
  uint32_t sequence=0;
};
}

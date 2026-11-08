// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>

namespace fpga3d {
// Set before renderer threads start. No clock reads or logging when disabled.
inline bool profileEnabled=false;
enum class Outcome : unsigned {
 Accepted, NotFullFrame, Empty, Unavailable, EdgeMark, BitmapClear,
 Cooldown, LightScene, Wireframe, ShadowMode, Toon, TextureMissing,
 TextureCapacity, TextureAlpha, TextureState, Span, CommandCapacity,
 Transport, SubmitFailed, TextureTraffic, Count
};
enum class Stage : unsigned { Preflight, Textures, Emit, Submit, Count };
inline constexpr const char* outcomeNames[]={
 "accepted","not_full_frame","empty","unavailable","edge_mark","bitmap_clear",
 "cooldown","light_scene","wireframe","shadow_mode","toon","texture_missing",
 "texture_capacity","texture_alpha","texture_state","span","command_capacity",
 "transport","submit_failed","texture_traffic"
};
struct Profile {
 static constexpr unsigned Reasons=unsigned(Outcome::Count),Stages=unsigned(Stage::Count);
 using Times=std::array<uint64_t,Stages>;
 std::array<uint64_t,Reasons> counts{};
 std::array<Times,Reasons> times{};
 uint64_t attempts=0,polygons=0,commands=0,textureBytes=0,uploadUs=0,waitUs=0,copyUs=0;
 uint32_t displayControl=0;
 void reset(){*this=Profile{};}
 void record(Outcome reason,const Times& elapsed,unsigned polys,uint32_t display,
             size_t cmd,size_t bytes,uint64_t upload,uint64_t wait,uint64_t copy){
  const unsigned r=unsigned(reason);++attempts;++counts[r];polygons+=polys;displayControl=display;
  for(unsigned i=0;i<Stages;++i)times[r][i]+=elapsed[i];
  if(reason==Outcome::Accepted){commands+=cmd;textureBytes+=bytes;uploadUs+=upload;waitUs+=wait;copyUs+=copy;}
 }
 void report()const{
  std::fprintf(stderr,"FPGA3D_PROFILE attempts=%llu polygons=%llu dispcnt=%04x commands=%llu texture_bytes=%llu upload_us=%llu wait_us=%llu copy_us=%llu\n",
   (unsigned long long)attempts,(unsigned long long)polygons,displayControl,
   (unsigned long long)commands,(unsigned long long)textureBytes,
   (unsigned long long)uploadUs,(unsigned long long)waitUs,(unsigned long long)copyUs);
  for(unsigned r=0;r<Reasons;++r)if(counts[r])
   std::fprintf(stderr,"FPGA3D_REASON reason=%s frames=%llu preflight_us=%llu textures_us=%llu emit_us=%llu submit_us=%llu\n",
    outcomeNames[r],(unsigned long long)counts[r],(unsigned long long)times[r][0],
    (unsigned long long)times[r][1],(unsigned long long)times[r][2],(unsigned long long)times[r][3]);
 }
};
struct Attempt {
 using Clock=std::chrono::steady_clock;
 Profile* profile;
 unsigned polygons;uint32_t display;
 Stage stage=Stage::Preflight;Profile::Times elapsed{};Clock::time_point last{};
 Attempt(Profile& p,unsigned polys,uint32_t disp):profile(profileEnabled?&p:nullptr),polygons(polys),display(disp){if(profile)last=Clock::now();}
 void next(Stage s){
  if(!profile)return;
  auto now=Clock::now();elapsed[unsigned(stage)]+=std::chrono::duration_cast<std::chrono::microseconds>(now-last).count();last=now;stage=s;
 }
 bool finish(Outcome reason,size_t commands=0,size_t bytes=0,uint64_t upload=0,uint64_t wait=0,uint64_t copy=0){
  if(profile){
   next(stage);profile->record(reason,elapsed,polygons,display,commands,bytes,upload,wait,copy);
   if(profile->attempts%120==0)profile->report();
  }
  return reason==Outcome::Accepted;
 }
};
}

// SPDX-License-Identifier: GPL-3.0-only
#pragma once
namespace fpga3d {
// Rasterizing a small foreground object does not repay the fixed full-plane
// clear, resolve and transfer costs. Keep large scenes and simple demos on
// FPGA; native rendering is exact for the small, many-polygon case.
inline bool adaptiveAdmission=false;
// Enabled by the live service after commercial-game A/B measurements. Large
// decoded sets require palette reloads or slow Device descriptor uploads.
// Keep the unrestricted encoder available for qualification and future tuning.
inline bool textureTrafficGuard=false;
inline bool ffiiiIndexedTextures=false;
inline bool lightScene(unsigned polygons,unsigned projectedPixels){
 return polygons>=32 && projectedPixels<32768;
}
struct Admission {
 unsigned cooldown=0;
 bool defer(){if(!cooldown)return false;--cooldown;return true;}
 void unsupported(){cooldown=60;}
 void reset(){cooldown=0;}
};
}

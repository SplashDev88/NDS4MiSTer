#ifndef NDS4MISTER_2DTRACE_H
#define NDS4MISTER_2DTRACE_H

#include <stddef.h>

#include "types.h"

namespace melonDS
{
class GPU;

namespace NDS4MiSTer
{

constexpr u32 Trace2DMagic = 0x3244534E; // "NSD2", little-endian
constexpr u16 Trace2DVersion = 9;

enum class Trace2DRecordType : u16
{
    Scanline = 1,
    MemoryDelta = 2,
    Renderer3DScanline = 3,
    ExtendedPaletteMap = 4,
    GeometryCommand = 5,
    GeometryFrame = 6,
    GeometryRegister = 7,
    FramebufferScanline = 8,
    Internal2DLatch = 9,
    OBJBufferHash = 10,
    OBJInputHash = 11,
};

enum class Trace2DMemoryRegion : u8
{
    Palette = 0,
    OAM = 1,
    VRAMA = 2,
    VRAMB = 3,
    VRAMC = 4,
    VRAMD = 5,
    VRAME = 6,
    VRAMF = 7,
    VRAMG = 8,
    VRAMH = 9,
    VRAMI = 10,
    FlatAOBJ = 11,
    FlatBOBJ = 12,
};

#pragma pack(push, 1)
struct Trace2DFileHeader
{
    u32 Magic;
    u16 Version;
    u16 HeaderSize;
    u32 PacketSize;
    u32 Reserved;
};

struct Trace2DRecordHeader
{
    u16 Type;
    u16 Size;
};

struct Trace2DMemoryDeltaHeader
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u16 Line;
    u8 Region;
    u8 Reserved;
    u32 Offset;
};

struct Trace2DRenderer3DHeader
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u16 Line;
    u16 PixelCount;
};

struct Trace2DExtendedPaletteMapPacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u16 Line;
    u16 Reserved;
    u32 ABG[4];
    u32 AOBJ;
    u32 BBG[4];
    u32 BOBJ;
};

struct Trace2DGeometryCommandPacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u64 Timestamp;
    u8 Command;
    u8 Reserved[3];
    u32 Parameter;
};

struct Trace2DGeometryFramePacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u64 Timestamp;
    u32 Vertices;
    u32 Polygons;
    u32 FlushAttributes;
};

struct Trace2DGeometryRegisterPacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u64 Timestamp;
    u32 Address;
    u32 Value;
    u8 Width;
    u8 Reserved[3];
};

struct Trace2DFramebufferScanlinePacket
{
    Trace2DRecordHeader Record;
    u32 Frame;
    u16 Line;
    u16 PixelCount;
    u32 Top[256];
    u32 Bottom[256];
};

struct Trace2DInternal2DEngine
{
    s32 BGXRefInternal[2]; s32 BGYRefInternal[2];
    u8 BGMosaicY; u8 BGMosaicYMax; u8 OBJMosaicY; u8 Flags;
    u32 BGMosaicLine; u32 OBJMosaicLine;
};

struct Trace2DInternal2DLatchPacket
{
    Trace2DRecordHeader Record; u32 Frame; u16 Line; u16 Reserved;
    Trace2DInternal2DEngine Engine[2];
};

struct Trace2DOBJBufferHashPacket
{
    Trace2DRecordHeader Record; u32 Frame; u16 Line; u16 Reserved;
    u64 Hashes[4]; // A line, A window, B line, B window
};

struct Trace2DOBJInputHashPacket
{
    Trace2DRecordHeader Record; u32 Frame; u16 Line; u16 Reserved;
    u64 OAMA; u64 OAMB; u64 FlatAOBJ; u64 FlatBOBJ;
};

struct Trace2DEngine
{
    u32 DispCnt;
    u8 LayerEnable;
    u8 OBJEnable;
    u8 ForcedBlank;
    u8 Reserved0;
    u16 BGCnt[4];
    u16 BGXPos[4];
    u16 BGYPos[4];
    s32 BGXRef[2];
    s32 BGYRef[2];
    s16 BGRotA[2];
    s16 BGRotB[2];
    s16 BGRotC[2];
    s16 BGRotD[2];
    u8 Win0Coords[4];
    u8 Win1Coords[4];
    u8 WinCnt[4];
    u8 Win0Active;
    u8 Win1Active;
    u8 BGMosaicSize[2];
    u8 OBJMosaicSize[2];
    u16 BlendCnt;
    u16 BlendAlpha;
    u8 EVA;
    u8 EVB;
    u8 EVY;
    u8 Reserved1;
};

struct Trace2DScanlinePacket
{
    u32 Frame;
    u16 Line;
    u16 VCount;
    u8 ScreensEnabled;
    u8 ScreenSwap;
    u8 CaptureEnable;
    u8 Reserved0;
    u16 MasterBrightnessA;
    u16 MasterBrightnessB;
    u8 VRAMCNT[9];
    u8 Reserved1[3];
    u32 VRAMMapABG[0x20];
    u32 VRAMMapAOBJ[0x10];
    u32 VRAMMapBBG[0x8];
    u32 VRAMMapBOBJ[0x8];
    u32 OAMDirty;
    u32 PaletteDirty;
    Trace2DEngine Engine[2];
};
#pragma pack(pop)

using Trace2DSink = void (*)(const void* data, size_t size, void* userdata);
using CompositeLineSink = void (*)(u32 frame, u16 line, u8 engine, bool screenSwap,
    const u32* top, const u32* second, const u8* windowMask,
    u16 blendCnt, u8 eva, u8 evb, u8 evy, u8 displayMode,
    u16 masterBrightness, void* userdata);
using OutputLineSink = void (*)(u32 frame, u16 line, const u32* top,
    const u32* bottom, void* userdata);
using VBlankSink = void (*)(u32 frame, void* userdata);
using PreDrawScrollSink = void (*)(u32 frame, u16 line, u16 bg1hofs,
    u16 bg2hofs, void* userdata);

extern bool Trace2DActive;
extern thread_local bool Trace2DThreadSuppressed;
Trace2DFileHeader MakeTrace2DFileHeader() noexcept;
void SetTrace2DSink(Trace2DSink sink, void* userdata) noexcept;
void SetCompositeLineSink(CompositeLineSink sink, void* userdata) noexcept;
void SetCompositeLineBypass(bool enabled) noexcept;
void SetOutputLineSink(OutputLineSink sink, void* userdata) noexcept;
void SetVBlankSink(VBlankSink sink, void* userdata) noexcept;
void SetPreDrawScrollSink(PreDrawScrollSink sink, void* userdata) noexcept;
bool CompositeLineEnabled() noexcept;
bool CompositeLineBypassEnabled() noexcept;
void EmitCompositeLine(u32 frame, u16 line, u8 engine, bool screenSwap,
    const u32* top, const u32* second, const u8* windowMask,
    u16 blendCnt, u8 eva, u8 evb, u8 evy, u8 displayMode,
    u16 masterBrightness) noexcept;
void EmitOutputLine(u32 frame, u16 line, const u32* top, const u32* bottom) noexcept;
void EmitVBlank(u32 frame) noexcept;
void EmitPreDrawScroll(u32 frame, u16 line, u16 bg1hofs, u16 bg2hofs) noexcept;
inline bool Trace2DEnabled() noexcept { return Trace2DActive && !Trace2DThreadSuppressed; }
void EmitTrace2DScanline(GPU& gpu, u32 line) noexcept;
void EmitTrace3DCommand(u32 frame, u64 timestamp, u8 command, u32 parameter) noexcept;
void EmitTrace3DFrame(u32 frame, u64 timestamp, u32 vertices, u32 polygons, u32 flushAttributes) noexcept;
void EmitTrace3DRegister(u32 frame, u64 timestamp, u32 address, u32 value, u8 width) noexcept;
void EmitTraceFramebufferScanline(u32 frame, u16 line, const u32* top, const u32* bottom) noexcept;

} // namespace NDS4MiSTer
} // namespace melonDS

#endif

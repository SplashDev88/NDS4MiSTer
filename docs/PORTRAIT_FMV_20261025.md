# Portrait of Ruin movie acceleration

Private follow-up to the accepted Portrait Beta3 / DS Lite menu baseline at
61b95dc2809271468aadb5e8f649ca5e943f51e8. The FPGA core and host are unchanged.

The four retail cartridges in the 2026.10.07 No-Intro metadata are covered:
USA ACBE revision 0, Europe ACBP revision 0 (all five menu languages), Japan
ACBJ revision 0, and Japan ACBJ revision 1. The separate preview-trailer video
cartridge is not a regional revision of the game. Full original SHA-256,
original converter hash, and every displaced instruction guard are required.
Modified or unknown cartridges retain the original decoder.

All versions contain identical mv/vamp.vx: 1,801 frames, 256 x 192, 30 fps.
No frame interpolation, transcoding, audio replacement, or source-ROM write
is performed. The existing VX decoder and original color table are reused.
Each version has its own exact addresses, including the Japanese Rev 1 decoder
fallback. The original wait-for-read callback is moved before the ping-pong
buffer header read; accelerated execution otherwise observes incomplete data.
This is a completion wait, not a fixed delay or a new playback clock.

Full reference runs decode every source frame. The 1,797 RGB conversion results
match the original converter's complete sequence in all four versions. The
original player itself omits four decoded frames from conversion. The separate
VX decoder's 132,784,128 YUV bytes and all consumed lengths match the USA guest;
the movie payload is identical across regions. The original game owns display
scheduling and background music. The USA prepared header retains the existing
qualified Portrait gameplay policy. Regional movie eligibility does not
silently expand the separate gameplay optimization policy.

The receiver registry is rebuilt with the accepted combo3 profile data and
coverage mismatch errors enabled. Renderer self-tests, 17-header selection,
all seven ARM wait-hook interpreter cases, and all 59 loader/cache tests pass.
The existing core timing caveats and RetroTINK LCD-grid limitations remain.
Hardware acceptance is recorded separately in the private beta handoff.

Detailed software qualification: `release/PORTRAIT_FMV_SOFTWARE_20261025.json`.
Private fixtures and ROM/movie bytes are excluded from source and packages.

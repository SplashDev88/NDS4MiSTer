# Lid and microphone hardware diagnostic

Build with `bash build-rom.sh` using the existing `skylyrac/blocksds:slim-latest`
Docker toolchain. Output: `build/LidMicDiagnostic.nds`. The ROM is authored test
code and contains no proprietary BIOS, game, save or audio assets.

ARM7 reads EXTKEYIN, samples TSC microphone channel6 in batches of256, and
writes HALTCNT=0xC0 when the lid closes. Only IRQ22 is enabled, with IME=0.
Reopening must resume sampling, increment the wake count once, report IRQ
`00400000`, and leave wake errors at0. ARM9 draws the mailbox without data
caching. HALTCNT Sleep pauses ARM9 and the LCD/timer cadence until ARM7 wakes,
so the on-screen mailbox remains frozen while closed, as in melonDS.

Released mic: MIN/MAX/AVG `800`, energy `000`. Held synthetic blow: varying
MIN/MAX and nonzero energy. Touch channels remain separate. Controls come
through the ordinary standalone frontend: F10 toggles lid, F11 blows while
held, or assign the equivalent optional controller inputs.

Mailbox: guest mainRAM0x023e0000,16little-endian words. A copy is written to
LCDC VRAM E0x06880000 for read-only renderer inspection. Words0..13 are magic
`4c4d4231`,batch counter,lid,sleep-requested,wake count,mic min,max,average,
mean absolute offset from2048,last IRQ,wake errors,touch X,touch Y,pen-up.
No card-save or firmware commands are issued. The normal frontend may create
an empty save file when mounting any ROM; it is not used by this test.

# NSM3 — private passive scanline / DMA observer

Based on NSM2, with no functional CPU, DMA, renderer, memory or sound change.
NSM2 reduces incorrect GX-cache invalidations and fixes sampled W1-1 scroll
bands at normal polling. A 100-us ARM intake test reaches about native game
timer cadence but delays the last scroll band from line 89 into lines 132–147.
That faster configuration is rejected pending a real cause and fix.

The existing heartbeat word now carries a passive snapshot on one selected
scanline each guest frame, rotating four sampling points. Tags C/D/E/F mean
lines 88/89/100/150 at drawline. The observation does not drive any handshake.
Bits 27..0:

- 27: GX readback owner busy.
- 26: ARM9 CPU bus idle.
- 25/24: DMA pause request / DMA bus ownership.
- 23..20: DMA FSM state (existing debug encoding).
- 19..17: accepted ARM9 membus FSM (existing encoding).
- 16/15: accepted transaction active / read.
- 14..12: accepted transaction age bits 6..4 (saturating source counter).
- 11..0: accepted transaction address low 12 bits.

The key distinction is accepted transaction versus the CPU's next pending
address. Earlier project diagnostics already showed those can differ while
DMA waits for a grant. This build changes the PC heartbeat into this diagnostic
word; it is not a user beta and must not be packaged as a release.

# NSMB DMA / matrix cache experiment (NSM2)

Private candidate on published v0.5.0 (`4dd5624`). Hardware qualification is
pending. No Engine B policy, CPU timing, raster cadence or readback data change.

The Mega Man ZX integration extended `dma_gx_write_valid` from GXFIFO writes
to all graphics IO writes so ARM sees DMA-written 2D registers too. The GPU
readback cache invalidation tap still treated every asserted DMA valid as a
geometry mutation. NSMB writes BG1HOFS using repeating HBlank DMA. Those writes
therefore discarded cached clip-matrix snapshots between CPU reads, although
2D scroll registers do not affect the matrix.

NSM2 applies the existing geometry/GXSTAT/power address qualifier to both CPU
and DMA sources. Held DMA geometry writes still invalidate before acceptance.
All 2D DMA events are still mirrored, and real matrix/BOX/POS queries retain
the same ordered request/reply protocol.

A focused test injects the **actual expression extracted from console_top**
into the real readback owner. It checks a 2D write during an outstanding query,
192 scanline DMA writes followed by cached matrix reads, other 2D/VRAM-control
registers, and held/accepted CPU and DMA writes to geometry, GXSTAT and power.
The unmodified v0.5.0 expression fails this same test. Existing readback-owner
handshake, cache invalidation, busy-result, reset and exhausted-token tests pass.

The physical baseline's trace alternates correct BG1 bands (lines 9, 56, 89)
with updates stretched over most of the frame; a full-CPU melonDS run of the
same ROM confirms the intended band boundaries. Baseline 500-us intake sleep
produces about 39.7 published pairs/s in stationary W1-1. A diagnostic 100-us
sleep steadies those bands but drops output to 29.9 pairs/s, so that workaround
is rejected. NSM2 retains the ordinary sleep and stock 1 GHz + WC.

This is an evidenced cache-invalidation defect; fixing all NSMB flicker and
improving gameplay FPS are still hardware hypotheses until measured.

EBO3 combines this independently tested invalidation fix with the optional-B
transport and full-frame adoption candidate. Both modes require hardware
qualification; no gameplay gain is claimed by the build itself.

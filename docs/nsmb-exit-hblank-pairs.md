# NSMB outdoor exit HBlank updates

The World 1-2 outdoor exit can show split/floating hill tops at roughly 60 published FPS. The cuts are present in native rendered frames before display scanout. A private ARM trace found only 121–171 BG1 writes per frame instead of the normal visible-line cadence; the intended transition at line 58 can arrive around line 79–110.

The full-system reference configures DMA1 as two repeating halfwords to BG3X (0x04000038, control 0x92600002) and DMA2 as one repeating halfword to BG1HOFS (0x04000014, control 0x92600001). The existing GX-read overlap only accepted a one-unit DMA. The higher-priority paired update could therefore keep both channels waiting for the CPU. HBlank requests coalesce in a pending bit during the wait, shifting the subsequent scroll table.

The candidate permits an aligned pair of incrementing halfwords spanning exactly one main-RAM word and one 2D register. Count, address, width, increment and cache/lock/query guards remain enforced. A partially completed pair may resume its remaining unit. It never falls back to the parked CPU's memory bus. This leaves the renderer's full resolution and normal frame cadence intact.

GRANT also reconsiders newly pending higher-priority channels before accepting bus ownership. A previously selected lower-priority request remains pending, preserving its progress.

`tools/test_dma9_gx_overlap.sh` covers the actual console grant expression and real DMA/readback/completion modules. It includes NSMB's paired and single channels together, repeated pointers, delayed RAM grant, IO backpressure, retention of a genuine GX reply, pending lower-priority request preservation, and rejected unsafe pairs. The paired case fails with published RTL and passes with the candidate. Existing main-RAM and GX/VRAM backpressure tests pass.

Hardware qualification is pending. Build and comparison evidence lives outside the source tree in evidence/nsmb-1-2-tearing-20261115. Private diagnostic observers are excluded from the candidate build.

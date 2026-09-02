# Project provenance

This repository joins the complete published histories of two related Nintendo
DS-on-MiSTer projects. The graft commit has two parents:

- `Nitro_DarkSide`, developed by Heni, including the original ARM9 CPU work,
  FPGA 2D engines, memory/VRAM fabric, DMA, system integration, and their
  supporting tests and documentation.
- `NDS4MiSTer`, maintained by SplashDev88, including the later public release
  line and its substantial ARM-assisted 3D renderer, integration, performance,
  packaging, and release work.

The post-graft working tree follows the NDS4MiSTer layout and current public
tip. Git history remains authoritative for individual changes and authorship;
the graft does not reassign copyright or authorship from either parent.

## Licensing

The combined work is distributed under GNU GPL version 3. `LICENSE.txt` is the
license file from the NDS4MiSTer parent. `LICENSE` is retained unchanged from
the Nitro_DarkSide parent so its file-level history and licensing provenance
remain directly inspectable. Vendored components retain the licenses and
notices found in their own trees.

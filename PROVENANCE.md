# Project provenance

This repository joins the complete published histories of two related Nintendo
DS-on-MiSTer projects. The graft commit has two parents:

- `Nitro_DarkSide`, developed by Heni. Her work includes the original ARM9 CPU,
  FPGA 2D engines, memory/VRAM fabric, DMA, system integration, and the
  supporting tests and documentation.
- `NDS4MiSTer`, maintained by SplashDev88, including the later public release
  line and its substantial ARM-assisted 3D renderer, integration, performance,
  packaging, and release work.

The post-graft working tree follows the NDS4MiSTer layout and current public
tip. Git history remains authoritative for individual changes and authorship;
the graft does not reassign copyright or authorship from either parent.

## Licensing

The combined work is distributed under GNU GPL version 3. The root `LICENSE`
contains the complete canonical GPLv3 text inherited from the NDS4MiSTer
parent. The earlier root license files from both parents remain directly
inspectable in Git history. Vendored components retain the licenses and notices
found in their own trees.

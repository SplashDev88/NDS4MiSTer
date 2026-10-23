# NSMB A/B Beta1 — private experiment

This build exposes two optional single-player bookkeeping shortcuts for New
Super Mario Bros. (USA), A2DE revision 0. **Repeated hardware tests did not
demonstrate a speed or smoothness gain. Both switches default to Off.**
It is an investigation build, not a faster release candidate.

It retains the previous Touch Range Beta3 renderer, normal FPGA bitstream,
FMV support and alternative-launcher support. The diagnostic PC-sampling
bitstream is not the gameplay bitstream in this package.

## Install and compare

1. Exit the current core through System → Reboot.
2. Extract the private ZIP at the SD root, including the hidden folder. It
   installs separately from the public core and the Touch Range beta.
3. Run **Scripts → NDS_NSMB_AB_Beta**, then load your own USA NSMB cartridge.
4. Open **Speed hacks**. **Local packet lookup** and **Skip inactive clients**
   can be changed independently. Reload the game after changing either option.
   System → Save settings remembers the choices in this kit only.
5. Compare the same scene and save. To return to the prior runtime, exit cleanly
   and run the earlier launcher. Use your normal save backups.

An enabled experiment adds roughly 50 seconds to game preparation on the
tested 1 GHz board. The source ROM file is never written. The loader changes
only a temporary virtual load image, checks game code/revision, ARM9 CRC32,
full-image hashes and 16-byte target guards, and falls back to the original
image on a mismatch. The original game path/save identity is retained.
Other cartridge versions are not qualified. These are guest-code shims;
they are not FPGA/HPS interception-only hooks.

No ROM, original BIOS/firmware dump, game save, personal settings or controller
map is included. Keep the launcher and paired support files together.

## Validation and limits

* 500 randomized function-state comparisons passed. The tested return values,
  callee-saved registers, stack and memory effects matched. IRQ interleavings
  and nonempty callback registrations were not exhaustively covered.
* A reference interpreter produced identical paired images over 1,500 sampled
  gameplay frames with 3.6–3.9% fewer ARM9 instructions. This did not translate
  into a demonstrated MiSTer performance improvement.
* Interleaved W2-5 jumping and scrolling runs used the same host/RBF/renderer,
  1 GHz and an isolated save. The menu-controlled build also passed a fresh
  launch, independent switches, saved-setting reload and short gameplay check.
  No transport faults or capture drops were reported, and saves were unchanged.
* Full-game compatibility, wireless behavior, long sessions and other boards
  are not qualified. The normal FPGA's existing static-timing limitation remains.

The requested instant divider, busy-loop skipping, bulk display-list handoff,
ITCM math/animation HLE and cache-maintenance stubs are **not implemented**.
Native profiling points first to clip-matrix readback waits; HALT already
stops instruction execution and cache flushing cannot safely be removed.

See [the architecture audit](NSMB_SPEED_HACK_AUDIT_20261023.md) and
[native top-30 PC report](NSMB_NATIVE_PC_PROFILE_20261023.md) for evidence,
implementation status and the recommended next investigation.

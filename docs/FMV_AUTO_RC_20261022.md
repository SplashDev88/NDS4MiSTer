# Automatic FMV private release candidate

This candidate moves the qualified movie work into ordinary ROM loading.
Launch **NDS_FMV_RC1** and use **Load *.NDS** as usual. There is no prepared-ROM
selector. The original ROM and its filename remain unchanged, and the host
uses the usual save and recent-file identity. The existing release and movie
test launcher remain separate rollback choices.

This is a private candidate, not approval to publish a public release.

## Supported scope

The shared HPS renderer includes MobiClip and VX decoding. Exact cartridge,
player code, movie packets and transport assumptions must also match before
the automatic loader enables them.

| Original cartridge | Revision | Accelerated assets |
| --- | --- | --- |
| Shin Megami Tensei: Strange Journey, USA (BMTE) | 0 | Opening, Snd/001.mods |
| Ni no Kuni, Japan (B2KJ) | 0 | Both opening streams |
| Chrono Trigger, USA (YQUE) | 0 | Opening, movie/op_ds.mods |
| Final Fantasy XII: Revenant Wings, USA (AXFE) | 0 | Upper/lower opening streams |
| Sonic Chronicles, USA (YWSE) | 0 | Upper/lower opening streams |
| Castlevania: Dawn of Sorrow, USA (ACVE) | 0 | Existing guarded guest decoder/converter/audio routines |

Five virtual cartridge images reproduce their earlier qualified private images
byte for byte. That covers eight opening assets and 10,455 encoded video frames.
Castlevania uses the existing staged-memory substitutions instead.

Unknown games, revisions, translations and modified cartridge contents keep
their original decoder path. Other movie assets are not silently reframed.
Common decoder implementation does not prove compatible player behavior or
safe VRAM ownership in every game. Ordinary gameplay does not receive a general
3D acceleration from this change.

## Loading and ownership

`NDS_FMV_AUTO=1` is set only by the paired private launcher. The native reader
checks a small cartridge identity header and delegates recognized revisions to
the bundled Python worker. Other games retain the native streaming reader.
The worker holds only its read-only source FD, output pipe and diagnostic log;
it inherits no SPI, save, framebuffer or session-lock ownership.

The worker verifies the complete source hash, builds an SDK autoload extension,
modifies exact guarded call sites and reconstructs the selected movie packets.
Every original compressed video and audio payload byte is retained. Only
technical packet metadata and project-owned transport hooks are packaged.
Original converter bytes are obtained from the caller's ROM, never shipped in
the profiles. ndspy 4.2.0 handles SDK executable structures and compressed
overlays; its unchanged source subset and GPL license are included.

The virtual image streams directly into the existing cartridge apertures.
It creates neither a patched ROM file nor a persistent cache. Hashing and
assembly can extend loading, especially over a network share. Progress records
keep the host's heartbeat and save service responsive during preparation.
The worker validates source file metadata again after streaming, then sends a
completion record. Missing completion, shortened reads and interruption prevent
cartridge release. The worker exits before gameplay; nothing extra remains
running to compete with the renderer.

Audio decoding and scheduling stay with the original guest/FPGA path. The
renderer, FPGA image and 1 GHz clock are unchanged from helper O qualification.

## Source reproduction

Build the transport hooks with the ARM cross-toolchain:

```sh
python3 tools/standalone_host/fmv/build_guest.py
bash tools/standalone_host/build.sh
python3 tools/standalone_host/fmv/test_prepare.py
python3 tools/test_private_fmv_auto_launcher.py
```

The `.bin` hooks are generated artifacts. The assembly sources and build script
are tracked. With locally owned cartridges named `SJ.nds`, `NINO.nds`,
`CHRONO.nds`, `FF12.nds` and `SONIC.nds` in a private directory, run:

```sh
python3 tools/standalone_host/fmv/verify_qualified.py /path/to/private/originals
```

This emits only lengths and hashes. It writes no cartridge output. Renderer
dependency provenance, build flags, licenses and the E-I VRAM regression are
documented in `FMV_OFFLOAD_EXPERIMENT_20261022.md` and `third_party/fmv`.

## Validation

Automated checks cover exact reconstruction, guest-hook reproduction, fallback,
virtual image boundaries, source mutation, movie packet/audio preservation,
keyframe offsets, incomplete worker streams, heartbeat service, cancellation,
large cartridge apertures and package pairing. Native playback, transition and
gameplay comparisons must be completed and recorded before declaring this RC
ready. Existing helper O results are supporting evidence, not a substitute for
testing the new loader and package.

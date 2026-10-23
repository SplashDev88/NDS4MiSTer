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

The five automatic cartridge profiles require a complete source-hash match;
unmatched revisions or modified contents keep their original decoder path.
Castlevania separately checks its header and exact routine bytes, rather than
the complete cartridge hash. Translations and modifications are not qualified.
Other movie assets are not silently reframed.
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
renderer enables its movie receiver only for the five qualified virtual-header
fingerprints, selected at each fresh session. Other games bypass the receiver,
and reset clears the selection. Castlevania retains its guest-only routines.
The decoder implementation, FPGA image and 1 GHz clock are unchanged from
helper O qualification. Building with FMV support disabled still produces the
byte-identical earlier renderer.

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

Automated checks passed for exact reconstruction, guest-hook reproduction,
fallback, virtual image boundaries, source mutation, movie packet/audio
preservation, keyframe offsets, incomplete worker streams, heartbeat service,
cancellation, large cartridge apertures and package pairing.

The new loader, host and helper were tested together at 1 GHz through the
RetroTINK-4K capture rig, using original ROM inputs and isolated saves:

| Game | Recorded opening test |
| --- | ---: |
| Castlevania: Dawn of Sorrow | 140 seconds |
| Chrono Trigger | 230 seconds |
| Ni no Kuni | 480 seconds, both opening streams |
| Final Fantasy XII: Revenant Wings | 180 seconds |
| Sonic Chronicles | 210 seconds |
| Shin Megami Tensei: Strange Journey | 180 seconds |

All six sessions exited cleanly. No transport faults, decoder errors or
detected audio-dropout windows occurred. Five recordings had no capture drops;
the Ni no Kuni recording limitation is described below. In the selected moving
portions, no source-relative pause exceeded 50 ms beyond the expected movie
cadence. These are bounded measurements, not a guarantee of perfect playback
in every scene. Source movies retain their original frame rate.
Audio comparisons use nonquiet 100 ms windows; they do not independently
establish audio/video lip-sync.

Transition checks reached the Chrono Trigger title/New Game menu, the
Castlevania equipment menu from a seeded save, Ni no Kuni's normal Japanese
startup warning, the Revenant Wings aerial canyon scene, the Sonic Chronicles
battle scene and Strange Journey's Antarctic briefing. These do not establish
complete gameplay or save compatibility for those titles.

The gameplay controls used the same save seeds and bounded inputs at 1 GHz.
The baseline is the preceding private gameplay renderer with FMV off, not
public rc.9. Each primary mean below contains two active samples of about
20 seconds.

| Game and scene | Baseline updates/sec | RC updates/sec | Change |
| --- | ---: | ---: | ---: |
| Castlevania, cave/bat room idle | 21.60 | 21.31 | -1.34% |
| NSMB, World 2-5 jumping | 59.51 | 59.55 | +0.06% |
| Mario Kart, Figure-8 Time Trial | 23.45 | 23.64 | +0.79% |

Castlevania was repeated in reverse order (RC then baseline); that repeat is
shown in the table. The first gated comparison was -1.91%; combining
all gated samples gives -1.67%. Mario Kart's separate Grand Prix check
was -1.46%; Time Trial removes AI racers and gives a more repeatable control.
The retained reports include these earlier samples, rather than discarding
lower results. No tested comparison crossed the preselected 3% slowdown gate.
Small variations remain, so this does not prove exact parity or every-game
behavior. Completed screen updates may reuse images and are not whole-game FPS.

The same host process loaded Chrono Trigger, NSMB, then Chrono Trigger again.
Movie decoding resumed on return to Chrono Trigger; the intervening NSMB
session recorded no movie conversions or decodes. Normal menu/recent-file
selection and the original save basename were verified with isolated saves.
The original user saves, settings, launchers and recent-file list were protected.
These checks do not establish an in-game save-write or full-game compatibility.

Both Ni no Kuni captures had one OBS render drop and zero encoding drops.
Their core transport, decoder, selected movie-cadence and audio checks passed.
Movie cadence is measured by framebuffer probes running on MiSTer, independently
of OBS. Both attempts are retained; these recordings are not certified drop-free.
This is an explicit capture limitation of the private candidate's evidence.

The detailed report is [FMV_AUTO_RC1_QUALIFICATION.json](release/FMV_AUTO_RC1_QUALIFICATION.json).
Archive integrity and the installed-launcher smoke are recorded separately
when the private package is installed.

### Loading tradeoff

This RC prioritizes verification over loading speed. On the test CIFS share,
Chrono Trigger took about 37 seconds and the 512 MiB Ni no Kuni cartridge took
about 202 seconds from host loading to cartridge start. Network and storage
speed affect these times. There is no persistent cache. The preparation worker
exits before gameplay, so it does not consume CPU during movie playback or play.

### Remaining limits

Only the cartridge revisions and assets above have been qualified. Long
sessions, later movies, translations, other revisions and other boards need
more coverage. The inherited FPGA static-timing limitation remains unresolved.
The release keeps the existing 1 GHz setting; no overclock is required.

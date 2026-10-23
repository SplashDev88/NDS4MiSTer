# NSMB Speed Beta1 — private experiment

This beta adds a guarded in-memory speed option for New Super Mario Bros.
(USA), revision 0. The user reported substantially faster play and much less
rubberbanding in the World 1 castle. Some slowdown remains, particularly when
new 3D elements appear. This is an experimental compatibility tradeoff, not a
60 FPS claim or a fully qualified release.

## Run it

1. Exit the current core with **System → Reboot** and back up your saves.
2. Extract the private ZIP to the SD root, including its hidden folder.
3. Run **Scripts → NDS_NSMB_Speed_Beta** and load your own USA NSMB ROM.

The launcher uses a separate folder, `.NDS_NSMB_Speed_20261023_B1`. Keep all
files in that folder together. The prior launcher remains available for
comparison and rollback. The retained frontend may still identify itself
as rc.8 internally; the launcher and manifest identify this private build.

## Compare the patch

Open **Speed hacks → Reduce bone reads**. Turn it off to compare, then reload
the game. **System → Save settings** remembers the choice. Pending changes do
not alter a running game.

The fresh private package includes these experiment defaults:

- Local packet lookup: **On**.
- Skip inactive clients: **Off**.
- Reduce bone reads: **On**.

The lookup setting matches the paired development control. The new bone-read
option produced the demonstrated gameplay change. Only the exact verified
A2DE revision-0 cartridge and ARM9 binary are eligible. Other identities keep
the ordinary loading path. Preparation can add roughly a minute before NSMB
starts. The source ROM remains unchanged; the loader changes a virtual image.

## What the measurements mean

In matched short castle jump tests at 1 GHz, geometry submissions increased
from about **34.5–34.8/sec to 55.8–56.4/sec**. Completed paired-screen output
went from about **44.1/sec to 35.5–36.6/sec**. These are different pipeline
stages: the game advances more quickly, while rendering remains limited.
Neither submission count nor the capture's motion detector is displayed FPS.

The tracked airborne portion of repeated jumps was shorter in the physical
capture, approximately 0.85 seconds versus 0.65 seconds. This is a bounded
motion measurement, not a full-jump or whole-game performance specification.
The same real-time button pulses can span different numbers of game frames.

This package also includes parallel final-image processing, packed affine
rows and shorter waits for geometry-query intake. With those combined,
repeated NSMB tests reached about **58 submissions/sec and 35 complete
pictures/sec**. Short Castlevania and Mario Kart comparisons showed no
slowdown: about 21.0 to 21.1 and 27.1 to 28.3 complete pictures/sec,
respectively. These are scene measurements, not whole-game FPS guarantees.
The selected renderer and final package checks are recorded in the manifest
and `NSMB_SPEED_BETA_VALIDATION_20261023.md`.

## Scope and remaining checks

The patch skips six cached body-part transform updates while retaining both
hands, the face, and the final graphics-state/completion operation. It checks
the target code and live overlay before taking the shortcut. An earlier,
more aggressive nine-update version broke effects and was rejected.

Two reference sequences, one 9,000 frames and one 6,000 frames, matched both
screens throughout. They cover running, jumping, firing, crouching and down
while airborne in the tested World 2-5 route. Native testing includes the
World 1 castle and the user's playtest. This does not establish correctness
for all power-ups, carried objects, damage effects, levels or multiplayer.
Turn **Reduce bone reads** off and reload if effects or animations are wrong.

Regular save identity is retained. The automated development tests used an
isolated save; loading your ordinary ROM normally uses your ordinary save.
This beta does not implement save states. No games, saves, controller maps or
private BIOS/firmware dumps are included. The only included settings file is
the explicit experiment-default file for this separate private kit.

See `NSMB_BONE_READBACK_EXPERIMENT_20261023.md` for exact scope, rejected
experiments and counter limitations. The FPGA is the retained normal build;
no diagnostic bitstream is installed by this package.

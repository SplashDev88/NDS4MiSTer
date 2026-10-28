# Pokémon Platinum guest-code optimization — 27 October 2026

Platinum became the sole active target when the user explicitly advanced from
FFT due diminishing returns. Use exact rc12 with cumulative accepted changes;
preserve the earlier player-character and furniture fixes. Historical PBOX
binaries, timings and room screenshots are context, not the current baseline.
No guest patch is enabled and no new speed gain is claimed.

The owned local ROM is USA CPUE revision 1, 128 MiB, SHA-256
`fbce4c4def0c7797f8dd238a3d7a5e48b4a7e3abd86890ac65f6321cef781bdb`.
The identity-only manifest is `platinum-cpue-r1.json`. Original ROM and saves
remain untouched. Two private seed candidates are hashed: the earlier
hardware-created room save and a backup of the user's original save.
Fresh region/CIFS inventory remains pending; other revisions are not assumed
missing or qualified.

Initial targets are active walking, menus and room transitions, followed by a
battle and intro route as reachable from the seed. Establish a deterministic,
visually verified unpatched replay and fixed RTC behavior before selecting
hotspots or patches. Native expected cadence, gameplay timing, pacing and
audio require current measurements; instruction samples and buffer publication
counts cannot substitute for those measurements. Intro visuals are not assumed
to be FMV assets without inspection.

Reuse `tools/game_optimization/replay_oracle.cpp`, the existing generic
profilers/scanners and `prepare.VirtualRom`/`hook_guard.py`. There are 122
ARM9 overlays and no ARM7 overlays in this image. A patch in an overlay needs
its ID, exact content identity and a verified reload mechanism; a reused RAM
address is insufficient. Persistent core save states remain unsupported.

The existing ARM structural scanner completed read-only main/autoload
screening. It flags the known branch-heavy halfword-copy shape at ARM9
`020c4b18` and ARM7 `037fb040`. These are unprofiled structural matches, not
proven hotspots or safe patch sites. The analogous FFT rewrite failed whole-
game exactness; do not transplant it on signature similarity alone. This scan
does not cover Thumb code or overlays, and establishes no shared SDK identity.

| Measurement | Baseline | Candidate |
|---|---|---|
| Exact ROM and private seed identity | Verified locally | No candidate |
| Deterministic gameplay replay | Pending setup | Not run |
| ARM9/ARM7 active-scene profile | Pending | Not run |
| Native speed, pacing and audio | Not measured in this workflow | Not measured |
| Golden framebuffer/RAM/audio/save comparison | Pending | Not run |

Private evidence: `platinum-optimization-20261027/INPUTS_V1.json`,
`STATIC_PATTERN_SCREEN_V1.json` and `WORKFLOW.json`. The last verified
cumulative beta remains FFTA2 Beta2 until a Platinum change qualifies.

Next three investigations: establish the active-scene baseline; classify its
largest guest hotspots including live overlay identities; inspect intro and
transition asset work for actual repetition. No RTL, new HPS service,
save-state-format change or non-bit-exact acceptance is authorized here.

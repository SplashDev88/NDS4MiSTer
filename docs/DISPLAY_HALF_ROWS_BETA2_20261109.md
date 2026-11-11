# RC15 Beta2: 3D resolution in Display options

Display options > 3D Resolution selects Native or Half Rows at runtime. Native
is the default. Half Rows draws alternate 3D rows and repeats each vertically;
2D composition keeps native resolution. This can increase rendered updates but
has not demonstrated faster game-clock progression. Thin 3D details may disappear
or flicker. The measured results and scene limits remain in
[the experiment report](ALTERNATE_ROW_3D_20261109.md).

Half Rows selects AA Off. Selecting AA On restores Native. Returning to Native
alone preserves AA Off, allowing a direct resolution comparison. System > Save
settings persists both choices. Reset settings restores Native and AA On.
Existing v1 AA preferences load as Native; missing or malformed settings use
Native and AA On. The separate Beta2 launcher has its own preferences.

The host publishes both options in a single atomic CPU-coherent word. The
renderer takes one snapshot at a frame boundary, invalidates stale frame reuse
and raster scheduling history when resolution changes, and retains the previous
scanline/AA admission checks. No FPGA, clock or game-patch changes are included.
The mapped menu setting takes priority over the old experimental launcher flag.

Validation: host navigation, rendered menu rows, save/reload, v1 migration,
reset, malformed settings and read-only control checks; independent raster
oracle with native/half/AA transitions under five worker schedules; full helper
self-test. Hardware qualification and artifact hashes are recorded alongside
the private package after deployment.

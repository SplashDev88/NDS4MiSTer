# MATCH4 matched display

This is the display configuration packaged in v0.4.0-beta.4. It retains the
MATCH1 FPGA protocol with the later MATCH4 helper. Both screens and 3D are
composed together on ARM and published as a complete pair. FPGA native pixel
writes are disabled; CPUs, sound, input, cartridge, saves and ordered LCD
events remain active. Engine B must be On. A different core/helper pairing or
an Engine B Off stream fails the session-policy check.

At line zero, drawing is admitted when replay is within one logical H3B frame
of input and at most four packets are queued. Full-rate mode allows every
eligible frame. Obsolete drawing may be skipped, but all architecture records
still replay. Render time is not bounded by the admission threshold; a state
replay workload that itself exceeds available CPU time can still overload.

The renderer primes row-zero sprites at line 262 and starts fresh 3D work from
latched geometry. Completed banks remain immutable until acknowledged. Engine B
composition caching requires matching state, memory revisions and preceding
sprite-phase identity. Engine A is not cached through that B-only cache.

Kickstart supplies the matched-display, full-rate and weighted-band flags, in
addition to the existing dual-core raster and WC settings. The raw helper still
requires those flags when launched without Kickstart. Do not use a launcher
from an earlier release with this pair. Engine B Off remains in the OSD but
is unsupported in this configuration.

Validation: tools/test_matched_display.sh and its admission model; Engine B
quiescence/session-policy tests; full host and emulated ARM helper tests; and
the focused physical --self-test-matched-full-rate. See SOURCE_PACKAGE.txt
for exact binary identities, test coverage and timing limits. Synthetic pixel
checks are not gameplay FPS or broad compatibility measurements.

The maintainer reports much faster gameplay with several remaining graphical
regressions. Castlevania bottom-screen flashes are unresolved. The initial
MATCH1 helper overflowed its event queue during testing; this release includes
subsequent backlog control, B caching and full-rate work in MATCH4. Historical
MATCH2/MATCH3 cadence measurements are not measurements of this release.

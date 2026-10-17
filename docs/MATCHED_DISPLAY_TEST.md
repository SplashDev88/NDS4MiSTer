# Matched display: current contract and MATCH4 history

Updated 17 October 2026. The current private freeze keeps matched ARM composition
with the later replay, cache, direct-publication and scheduling improvements.
Use [architecture](architecture.md) and [private beta](PRIVATE_BETA_20261017.md)
for its exact configuration and qualifications.

This display configuration originated in v0.4.0-beta.4 and continued in beta.5. It retains the
MATCH1 FPGA protocol with the later MATCH4 helper. Both screens and 3D are
composed together on ARM and published as a complete pair. FPGA native pixel
writes are disabled; CPUs, sound, input, cartridge, saves and ordered LCD
events remain active. Engine B Off requires a matching core with complete
optional-B transport; older matched Off streams fail the policy check. See
[session policy](hybrid-3d-session-policy.md).

At line zero, drawing admission checks replay distance from input and queued
packets. The early MATCH4 configuration used a four-packet limit; the current
private runtime explicitly selects 16 in its manifest. Full-rate mode allows every
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
from an earlier release with this pair. Engine B Off support depends on the
explicit optional-B capability, not merely a menu label.

Validation: tools/test_matched_display.sh and its admission model; Engine B
quiescence/session-policy tests; full host and emulated ARM helper tests; and
the focused physical --self-test-matched-full-rate. See SOURCE_PACKAGE.txt
for historical public binary identities; use the private freeze manifest for
the later package. Synthetic pixel
checks are not gameplay FPS or broad compatibility measurements.

## Historical beta.5 observations

The maintainer reported much faster gameplay with several remaining graphical
regressions. The beta.5 upload-snapshot correction passed the Castlevania gameplay test;
see CASTLEVANIA_UPLOAD_SNAPSHOT.md for the bounded policy and its tradeoff. The initial
MATCH1 helper overflowed its event queue during testing; this release includes
subsequent backlog control, B caching and full-rate work in MATCH4. Historical
MATCH2/MATCH3 cadence measurements are not measurements of this release.

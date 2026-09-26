# Optional Engine B with the NSMB HBlank fix

Private EBO6 combines EBO5's optional-B policy and inactive local A drawing with
NSM5's bounded HBlank DMA overlap, retained real GX completion, and passive
ownership heartbeat. The paired ARM service remains the optional-B b2d build.
Use its existing fast matrix-query polling option only after hardware validation.

NSM5 with the production d596 helper reached W1-1 at a median 0.7135 seconds per
HUD timer tick. The diagnostic-helper run had no wrong BG1 boundaries in 32
stationary and 128 moving sampled frames. This is game progression evidence,
not a claim of 60 unique rendered frames per second. EBO6 must establish its own
On/Off boot, graphics, timing and reset/ROM-switch results before distribution.

An earlier full-size placement (NSM4) stalled after the title despite passing
standalone regressions. The passive-observer placement NSM5 boots. Preserve the
exact hardware-qualified RBF rather than treating simulation success or matching
RTL behavior as evidence that every new Quartus placement is safe.

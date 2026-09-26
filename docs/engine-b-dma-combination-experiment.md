# Optional Engine B with the NSMB HBlank fix

> Historical experiment notes. The accepted combined v0.5.1 build and
> current validation are documented in [V051_GRAPHICS_AND_PERFORMANCE.md](V051_GRAPHICS_AND_PERFORMANCE.md).

Private EBO6 combines EBO3's already tested optional-B policy with NSM5's
bounded HBlank DMA overlap, retained real GX completion, and passive ownership
heartbeat. The paired ARM service remains the optional-B b2d build. Use its
existing fast matrix-query polling option only after hardware validation.

EBO5's additional local-A-idle area reduction was removed before compiling
EBO6: EBO5 hit FPGA/ARM transport fault 8/16 during NSMB startup. The cause has
not been established. The EBO5 source and full fit remain in its own worktree;
this candidate keeps the established local renderer and avoids that experiment.

NSM5 with production d596 reached W1-1 at a median .7135 seconds per HUD timer
tick, with no wrong BG1 boundaries in 32 stationary and 128 moving diagnostic
frames. Its six-session reset/switch check and repeated W1-1 entry passed.
Game progression is separate from unique rendered FPS. EBO6 must establish
its own On/Off startup, graphics, timing, reset and ROM-switch results.

An earlier full-size placement (NSM4) stalled after the title despite passing
standalone regressions. The passive-observer placement NSM5 boots. Preserve
the exact hardware-qualified RBF; matching RTL alone does not qualify a new fit.

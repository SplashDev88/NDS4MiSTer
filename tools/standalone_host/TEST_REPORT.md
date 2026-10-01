# v0.6.0-beta package qualification

The FPGA, ARM renderer and write-combining module are byte-identical to the accepted September 30 standalone build. The user preferred this build in NSMB and accepted the 1080p TATE setup on a second MiSTer. This is focused gameplay acceptance, not a universal FPS or full-game compatibility claim.

The public frontend updates its release identity and includes the isolated slow-ROM-read worker fix. All five C++ menu/OSD/host/reader tests pass, including ARM32 host and reader tests. A 21.5-second injected read stall kept the actual Host::load heartbeat age at or below 538 ms, beneath the unchanged 20-second watchdog. Cancellation, missing/truncated files and worker cleanup preserve saves and prevent starting a partial ROM. Real slow-Wi-Fi testing remains pending. Public launcher cleanup has 25 passing offline lifecycle/preflight/configuration tests and an independent source review. Existing configuration preservation, no previous NDS installation, mismatched core refusal, interrupted settings writes and process-generation/SPI ownership checks are covered.

The renamed public package has not yet received its final hardware launch-and-return smoke test. Release notes remain pending user approval; no publication has been authorized for this package. FPGA timing is not closed; the preserved core is the user-accepted hardware build.

The accepted runtime flags, source commits and exact component hashes are recorded in SOURCE_PACKAGE.txt and the installer manifest. The later combined game-fix changes remain excluded. Only the isolated network ROM-loader fix was backported; network directory browsing and Recent Files availability checks still use synchronous I/O.

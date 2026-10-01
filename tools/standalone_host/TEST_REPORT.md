# v0.6.0-beta package qualification

The FPGA, ARM renderer and write-combining module are byte-identical to the accepted September 30 standalone build. The user preferred this build in NSMB and accepted the 1080p TATE setup on a second MiSTer. This is focused gameplay acceptance, not a universal FPS or full-game compatibility claim.

The public frontend rebuild changes only its displayed release version and startup-log identity. All four C++ menu/OSD/host test programs pass. Public launcher cleanup has 25 passing offline lifecycle/preflight/configuration tests and an independent source review. Existing configuration preservation, no previous NDS installation, mismatched core refusal, interrupted settings writes and process-generation/SPI ownership checks are covered.

The renamed public package has not yet received its final hardware launch-and-return smoke test. Release notes remain pending user approval; no publication has been authorized for this package. FPGA timing is not closed; the preserved core is the user-accepted hardware build.

The accepted runtime flags, source commits and exact component hashes are recorded in SOURCE_PACKAGE.txt and the installer manifest. Later combined game-fix and asynchronous network-loader candidates are excluded.

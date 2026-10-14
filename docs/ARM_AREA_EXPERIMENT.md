# ARM area experiment

This private SPLIT8 candidate starts from SPLIT7 (`cc773ffa47d862e2f5b9de46a9800625ef4a97f6`). The `NDS_ARM_AREA` assignment enables two area reductions in the matched ARM-frame configuration. Routing and gameplay remain unverified until this candidate is compiled and tested on hardware.

Engine A uses `nds_gpu2d_register_shadow` instead of the local text, affine and sprite drawers. Its full DISPCNT, byte-write behavior, full address decode and bus-reset semantics match the original Engine A renderer. Engine B retains its existing mask. Architectural palette readback, VRAM, graphics event capture, LCD/IRQ/DMA timing and display capture remain in their existing paths. Legacy drawer requests and merge outputs are idle. The full-frame descriptor reader and scanout adoption acknowledgement remain connected; full ARM frames already bypass the legacy merge boundary. This configuration requires `NDS_MATCHED_DISPLAY_TEST`.

The standalone host computes the cartridge save type from the same pinned melonDS table that generated the FPGA ROM. It preserves all types 0–7, default type 1, and the two special no-save defaults. Only the lookup ROM disappears. The save device, cache, persistence protocol and file format are unchanged.

## Matched host/core protocol

Firmware command `0x45` status bit 10 advertises host-provided save profiles; bit 11 means a complete profile is committed. The host checks capability before uploading assets or a ROM. FIO index 8 uploads exactly eight little-endian bytes while the console is held: game code (32 bits), save type (16 bits, value 0–7), and protocol marker `0x5351` (16 bits).

Every new ROM download invalidates the profile, including a replacement with the same game code. The host finishes and mounts the ROM, then uploads the profile before requesting direct-boot release. Truncated, reordered, invalid-type and invalid-marker uploads cannot commit. An old host cannot release direct boot without metadata. A guest reset retains the immutable current-cartridge metadata; a media reset clears it.

Validity crosses into the console through three synchronizer stages after the held payload settles. The loader compares the supplied code to the header it actually reads. Missing or mismatched metadata raises boot error while CPUs remain held. The selected type is latched, then validity publishes one cycle later for the existing save bridge. Native firmware boot has no cartridge and needs no cartridge profile.

Use the newly built `tools/standalone_host/nds_standalone_host` with this core. The renderer binary is unchanged. Do not package this host with SPLIT7 or a public core.

## Focused checks

- `bash tools/test_nds_gpu2d_a_shadow.sh`: original GPU versus Engine A shadow, partial writes, reads, reset and address isolation.
- `bash tools/test_nds_gpu2d_register_shadow.sh`: existing Engine B contract.
- `bash tools/test_host_save_profile.sh`: compiled host table against the frozen FPGA table; controller transfer and loader validation tests.
- `bash tools/test_firmware_control.sh`: existing firmware/BIOS lifecycle.
- `bash tools/test_nitro_save_8k_64k.sh`: existing EEPROM/FRAM/flash behavior.
- `tools/standalone_host/test_host.cpp`, `test_host_firmware.cpp`, `test_host_storage.cpp` and `test_host_split_output.cpp`: host loading, mismatch rejection, persistence, reset, interruption, storage and display behavior.
- `bash tools/test_nitro_console_vhdl_analyze.sh` with `ALTERA_MF_COMPONENTS` set: complete console analysis.
- Existing palette, graphics event, full-frame publication/adoption and matched-output tests.

Regenerate the host table with `tools/generate_nds_save_profiles.py` and its optional `--host-output tools/standalone_host/save_profiles.h` argument. The host table check rejects stale generated content.

Only begin the FPGA compile after SPLIT7 has exited with a real build failure and no compiler remains. Preserve its logs/reports first. A successful SPLIT7 build does not trigger this contingency. Static timing remains diagnostic under the existing project policy; routing success alone does not establish gameplay acceptance.

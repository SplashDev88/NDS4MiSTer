# RC14 validation and scope

RC14 packages independent CRT-targeted DV1 Y/C with the original RC13 game
loader and 22-entry guest catalog. Mario Kart course optimizations, their
regional recipes, preparation code and cache enablement are excluded.
Earlier game and FMV optimizations, including the existing movie cache,
remain unchanged. No new analog layout or rotation feature is included.

The FPGA is the accepted Y/C Beta2 binary. The renderer is unchanged from
RC13. The host is the previously verified RC14 version-only rebuild of the
Y/C Beta2 host; no new host or FPGA build was needed for this package revision.
The prior host was reproduced byte for byte before relabeling. The shorter
release label changes addresses, so binary identity with Beta2 is not claimed.

Release checks include 63 launcher/recovery/display/clock/preflight tests and
136 loader, progress, preparation and movie-cache tests. The compiled host's
Python ROM-reader integration is rerun against the restored loader. Earlier
Direct Video, menu, RTC, firmware and framed-transfer checks still apply to
the unchanged host. Package audits check hashes, permissions, source/runtime
agreement, normal installation paths, frozen source inventories and absence
of personal data.

The extracted runtime is tested with original Mario Kart USA, Europe, Japan
and Korea revision-0 inputs. Both catalog selection and the complete worker
stream must return the original ROM byte for byte without preparing course
assets, including when a leftover course-cache setting is present. A seeded
upgrade fixture verifies that display/controller/clock settings, saves, INI
and storage configuration survive extraction. The unchanged RC13 catalog and
loader are checked byte for byte against the accepted Y/C package.

The retained Y/C production video test covered 1,024 routing combinations,
six carrier/burst waveforms and independent-picture tests. The shared RTC/Y/C
command test passed and rejected the original command-collision negative
control. Y/C Beta2 passed bounded RT4K checks for startup, menus, Main/Touch
selection, timing and CRT/Scaler switching. The user subsequently reported
that Y/C output worked well on the tester setup.

This revised RC14 archive and Mr. Moro's contributed display profiles have
not been relaunched on hardware. The active game session was not changed.
These checks do not establish all adapters, games, firmware or displays.
FPGA timing remains unclosed. Save states, wireless multiplayer, DSi mode,
PAL 50 Hz and full-playthrough certification are not added. Four inherited
Platinum gameplay-validation gaps remain in VERSION_COVERAGE.md.

The runtime and corresponding source are separate ZIPs. Mr. Moro's original
profile ZIP is an optional third asset with its bytes and instructions
preserved. Each asset has a SHA-256 sidecar. Package-specific receipts are
retained with the prepared release artifacts.

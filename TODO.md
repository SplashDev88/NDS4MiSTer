# Core TODO

- [ ] **Fix Reset settings clearing the bundled NSMB preset and blocking the next launch.** Confirmed by source inspection in RC15 (`bf87d812860eeb32d72c78f5563bd39a14defaef`) and an offline package-validation reproduction; no hardware reset test was performed.

  The release ships `Scripts/.NDS_RC15/NDS_speed.cfg` with `NDS-SpeedHacks-v1` and value `5` (`lookup+bones`). The [reset handler](tools/standalone_host/host.cpp#L1729) assigns `speed_hacks = 0`, then calls [saveSettings](tools/standalone_host/host.cpp#L508), which overwrites the file with `0` (`off`). Further ROM loads in that running session use Off. Resetting settings does not undo patches already loaded into the current game. The package also pins this writable file in `manifest.json → automatic_movie_files`: the [launcher validator](tools/standalone_host/auto_movies.py#L25) rejects the changed bytes on the next launch, before starting the host.

  Reproduce on a clean RC15 installation: confirm preset `5`; select **System → Reset settings → Yes**; inspect the preset file, then exit and relaunch **Scripts → NDS_RC15**. The persisted preset is now `0`, and launch fails with `NDS FMV RC: Mismatched package file: NDS_speed.cfg`. There is no menu control to restore it. In an isolated extracted ZIP, `auto_movies.py --validate-only` passed with the original value 5 and failed with exactly this error after writing the reset-produced value 0.

  Restore the release's intended defaults consistently during reset, including the bundled NSMB preset. Resolve the conflict between writable preferences and immutable package hash checks. Add a regression check covering reset → save → normal launcher validation → host restart → ROM-load preset, expecting successful launch and preset `5` for RC15. Resolve the related first-install/reset layout difference (Top/bottom versus Side-by-side) when defining the shared defaults.

  Workaround: exit NDS, back up settings, and restore only `Scripts/.NDS_RC15/NDS_speed.cfg` from the matching release ZIP. No source fix has been made by this documentation audit.

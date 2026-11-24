# Core TODO

- [x] Separate writable speed preferences from immutable package data so Save/Reset settings cannot break launcher validation. Reset restores the release speed preset. Offline migration, launcher validation and host restart tests cover the change.
- [x] Keep the public launcher and settings paths fixed at `Scripts/NDS.sh` and `Scripts/.NDS/`; import existing RC14/RC15 preferences and clock data automatically.
- [ ] Align the remaining first-install and Reset settings display defaults (Top/bottom versus Side-by-side).
- [ ] Qualify the v1.0.3 Pixel Grid experiment on hardware. The scaled-HDMI
  option supports Off/Light/Medium/Strong at 720p and 1080p, follows integer
  scaling and rotation, and precedes the OSD. The DSP implementation retains
  the approved beta18 coefficients with a four-cycle pipeline. Unsupported
  modes bypass the effect; 1440p remains deferred. See
  `docs/PIXEL_GRID_V103.md` for resource measurements and validation status.

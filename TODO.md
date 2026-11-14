# Core TODO

- [x] Separate writable speed preferences from immutable package data so Save/Reset settings cannot break launcher validation. Reset restores the release speed preset. Offline migration, launcher validation and host restart tests cover the change.
- [x] Keep the public launcher and settings paths fixed at `Scripts/NDS.sh` and `Scripts/.NDS/`; import existing RC14/RC15 preferences and clock data automatically.
- [ ] Align the remaining first-install and Reset settings display defaults (Top/bottom versus Side-by-side).

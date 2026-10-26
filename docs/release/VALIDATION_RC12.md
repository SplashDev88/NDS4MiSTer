# RC12 validation scope

This release packages the tested cumulative Ecclesia FMV Beta2 from source e185470c306fee61f4b6aea3c655eeb821c3210f. The renderer, FPGA, movie registry and generated hooks are retained byte-for-byte. The host is rebuilt for the rc12 version label. ELF section comparison must show identical executable sections and only the release string/linker build ID changing. Supervisor changes are its matching renderer hash pin and release text; its behavior matches the installed beta. The public launcher uses Scripts/.NDS_Standalone.

## Existing runtime qualification

- USA Ecclesia bounded gameplay, full opening/replay and movie skip; save selection, in-game suspend resume, combat and cold loading of an actual saved game. In-game suspend is a game feature, not a core save state.
- EU/JP/KR each have a 4,454-frame software comparison matching screen, state, RAM, PCM and saves with gameplay optimizations on/off. Controlled native combat improves approximately 34 to 55 completed paired-screen updates/s; this is not unique animation FPS.
- Regional movie comparisons cover all 1,038 source frames in order. Native captures match 998 transitions each, median approximately 67 ms and p95 approximately 69 ms. No decoder errors, detected audio dropouts or progressive drift in these openings. EU resampled audio begins about 5.19 ms earlier; raw mixer samples match after a constant alignment.
- Ni no Kuni Japanese/English v1.0 first-story comparisons retain the original image sequence. Japanese hardware exercised all 15 story clips, with 13,815 decodes including a partial opening and zero errors. The S07 clear transition differs by one displayed frame; natural later-game triggers remain unqualified.
- The subsequent English v1.0 CIFS hardware test with the same cumulative Beta2 passed the complete opening, first story movie, Morton Street movement/tutorial and NPC dialogue: 3,215 decodes, zero errors, clean exit, previous save/settings preserved. The recording was fully decoded after export; soundtrack present and timestamps monotonic.
- Earlier RC11 Portrait, menu and regression qualifications remain applicable to their pinned components. See retained reports with their original scopes.

## Release packaging

The release recipe verifies the input beta hash, retained component hashes, version-only host differences, generated movie hooks, all frozen FPGA inputs, source archives, licenses and full ZIP checksums. It rejects ROMs, saves, personal settings, private paths, secrets and unsafe archive members. Offline preflight/recovery, loader and ARM host tests are recorded separately. Extraction validates the packaged launcher and upgrade preservation.

Hardware results above belong to the tested beta; package validation alone does not establish a new full playthrough. Any final package launch checks are reported separately beside the ZIP.

## Retained limitations

Static FPGA setup/recovery timing is unresolved. No full-game 60 fps, every-scene correctness or long-duration stability claim is made. The NSMB goal-pole background glitch and LCD Grid 2 layout-dependent dimming/banding remain. See release notes and the optional RetroTINK recipe.

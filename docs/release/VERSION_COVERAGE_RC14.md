# NDS4MiSTer rc.14 version coverage

| Game / identity | Included optimization | Evidence |
| --- | --- | --- |
| Platinum USA CPUE rev1 | Existing terrain gate | Previously accepted |
| Platinum USA CPUE rev0, Germany CPUD rev0, France CPUF rev0 | Terrain gate | Reference, native scene/performance, Save/reset/cold checks completed |
| Platinum Italy CPUI rev0 | Terrain gate | Static identity/bytes and software reference reviewed; remaining gameplay checks skipped by user |
| Platinum Spain CPUS rev0, Japan CPUJ rev0, Korea CPUK rev0 | Terrain gate | Static identity/bytes checked; gameplay validation skipped by user |
| HeartGold and SoulSilver USA + Germany/France/Italy/Spain/Japan/Korea rev0 | Existing starter and terrain optimizations | Beta6 bounded qualification retained |
| FFT A2 USA A6FE rev0 | Accepted renderer optimization | Prior USA qualification retained |
| FFT A2 Europe A6FP rev0, Japan A6FJ rev0 | Same renderer profile enabled for exact headers | Regional evidence in the separate source download: docs/game-optimization/ffta2-regional-raster-profiles.json |

The four Platinum ports with skipped gameplay checks are included explicitly under the user's request, not labeled tested or performance-qualified. No measured gain is assigned to them. All guest patch identity and original-byte guards remain active.

Unknown ROM revisions/identities fall back. Europe-labelled Platinum CPUE rev10 and HeartGold IPKE rev10 remain excluded because revision provenance is unresolved. No other unavailable revision is claimed supported. ROM identity coverage does not establish a full playthrough or every language/menu path.

Accepted guest-code experiments that failed performance/behavior gates are not revived. FFT's accepted optimization is a renderer profile, not a newly enabled guest patch. Save states, wireless multiplayer, DSi mode and PAL output remain unsupported.

The Touch fix applies to the standalone host across games. Existing rc12 FMV and gameplay coverage is retained; see the movie catalog and prior qualification records in the separate source download.

## Mario Kart DS and DV1 Y/C (RC14)


RC14 retains Regional Beta4's selection, which includes the existing USA Course Beta3 optimization and ports its 31 selected course resources to these exact retail identities. All are revision 0. The remaining racing course, GBA Sky Garden, retains its original resource.

| Region | Code | Revision | Header SHA-1 (352 bytes) |
|---|---|---:|---|
| USA | AMCE | 0 | `a804fde97be47f0d7ac06bbf966d342b07daecbb` |
| Japan | AMCJ | 0 | `073dde38d9ba154b313aeb276d005ba850dfac0d` |
| Korea | AMCK | 0 | `ecdc35f52af5ed5ec0c842cf997c62ad661e71ba` |
| Europe | AMCP | 0 | `fbd2e9fc21b78262aa9641d35d33ce2c55402f45` |

The manifests additionally require the complete ROM SHA-256, ARM9 and section hashes, expected instructions, dependency data and course hashes. An unknown identity or any guard failure retains the original cartridge stream. Demos AM3P/A39J/A39E and other unverified revisions are not admitted. The owned library contained no additional retail revisions; this is not a claim that every possible release has been inventoried.

All 31 stored course resources match the USA originals byte for byte. Europe uses the same file IDs; Japan and Korea use remapped IDs resolved by filesystem names and then verified by hashes. This reuses the USA geometry proofs and course selection. The full USA 32-track timing campaign was not repeated in each region.

Regional testing covers arithmetic/ABI, guarded loader rejection, normal eight-racer Grand Prix, Yoshi Falls movement/restart/save reopen, and native Figure-8 Time Trials. See the regional report in the separate source download for results and limits. Multiplayer, every mission/battle mode, long sessions and new-record save writes are unqualified. Save states remain unsupported.

DV1 Y/C requires CRT target, a compatible DAC/active adapter and the appropriate svideo INI setup. It uses the successful Y/C Beta2 FPGA implementation. Scaler target stays RGB. The tester report does not establish every DAC/CRT combination, PAL 50 Hz, or arbitrary CRT rotation support.

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

## DV1 Y/C (RC14)

DV1 Y/C requires CRT target, a compatible DAC/active adapter and the appropriate svideo INI setup. It uses the successful Y/C Beta2 FPGA implementation. Scaler target stays RGB. The tester report does not establish every DAC/CRT combination, PAL 50 Hz, or arbitrary CRT rotation support.

# Mario Kart DS regional beta coverage

Regional Beta4 includes the existing USA Course Beta3 optimization and ports its 31 selected course resources to these exact retail identities. All are revision 0. The remaining racing course, GBA Sky Garden, retains its original resource.

| Region | Code | Revision | Header SHA-1 (352 bytes) |
|---|---|---:|---|
| USA | AMCE | 0 | `a804fde97be47f0d7ac06bbf966d342b07daecbb` |
| Japan | AMCJ | 0 | `073dde38d9ba154b313aeb276d005ba850dfac0d` |
| Korea | AMCK | 0 | `ecdc35f52af5ed5ec0c842cf997c62ad661e71ba` |
| Europe | AMCP | 0 | `fbd2e9fc21b78262aa9641d35d33ce2c55402f45` |

The manifests additionally require the complete ROM SHA-256, ARM9 and section hashes, expected instructions, dependency data and course hashes. An unknown identity or any guard failure retains the original cartridge stream. Demos AM3P/A39J/A39E and other unverified revisions are not admitted. The owned library contained no additional retail revisions; this is not a claim that every possible release has been inventoried.

All 31 stored course resources match the USA originals byte for byte. Europe uses the same file IDs; Japan and Korea use remapped IDs resolved by filesystem names and then verified by hashes. This reuses the USA geometry proofs and course selection. The full USA 32-track timing campaign was not repeated in each region.

Regional testing covers arithmetic/ABI, guarded loader rejection, normal eight-racer Grand Prix, Yoshi Falls movement/restart/save reopen, and native Figure-8 Time Trials. See [MARIO_KART_REGIONAL_REPORT.md](MARIO_KART_REGIONAL_REPORT.md) for results and limits. Multiplayer, every mission/battle mode, long sessions and new-record save writes are unqualified. Save states remain unsupported.

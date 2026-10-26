# RC12 game-version coverage

| Game | Version | RC12 scope |
| --- | --- | --- |
| Order of Ecclesia | USA YR9E, Europe YR9P, Japan YR9J, Korea YR9K; all revision 0 | Faster gameplay and accelerated opening movie |
| Ni no Kuni | Japanese B2KJ revision 0 | Story movie video fix; all 15 story clips exercised through the real player in an opening-scene playlist |
| Ni no Kuni | English translation v1.0, B2KJ revision 0 | Same fix; all-clip software coverage, physical intro/first-story/gameplay test |
| Portrait of Ruin | USA ACBE0, Europe ACBP0, Japan ACBJ0 and ACBJ1 | Retained RC11 movie acceleration; gameplay performance qualification remains bounded USA revision 0 |

Ecclesia's four regional entries cover the project's current retail catalog. Unknown revisions, translations and modified dumps are not implicitly qualified. Movie preparation verifies the full ROM SHA-256 and relevant code/assets. Unrecognized movie versions retain the original movie path when the ROM otherwise fits the supported cartridge layout. The gameplay selector uses guarded cartridge headers, rather than a full-ROM proof.

The runtime retains all 21 registered automatic movie profiles. The precise identity registry, including older supported games, is `fmv/profiles.json` inside the hidden kit. Its hashes identify user-supplied files; the release contains no games or movie assets.

Ecclesia movies are natively 14.985 fps; Ni no Kuni story clips are natively 12 fps. These are not 60 fps conversions. Later gameplay and every natural story trigger remain outside full qualification.

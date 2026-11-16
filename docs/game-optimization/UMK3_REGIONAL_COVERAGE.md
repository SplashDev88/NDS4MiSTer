# Ultimate Mortal Kombat regional performance coverage

The retained texture range hash reuse, sprite raster paths, 8-bit palette
pre-expansion, and rectangle horizontal texture lookup now share one retail
identity selector. These are renderer/cache optimizations, with no guest ROM
addresses or query timing changes.

| Retail cartridge | Game code | Header revision | CRC32 of first 0x160 bytes |
| --- | --- | --- | --- |
| USA (En,Fr,De,Es,It) | YUTE | 0 | 6c631035 |
| Europe (En,Fr,De,Es,It) | YUTP | 0 | 1b8dde13 |

These are all UMK retail entries in the catalog checked on 2026-11-16; it lists
no separate revision. A different revision/header must be verified before it
is added. Region suffixes alone do not enable the policies.

Each of the four optimization tests exercises both identities and rejects
unidentified cartridges, mismatched codes, uncatalogued revisions, and altered
header fingerprints. The existing render-equivalence and session-reset tests
remain in place.

The measured USA combat results remain scene-specific. Regional coverage does
not imply a new FPS gain or a measured European FPS result.

Local catalog, ROM verification, build and hardware evidence:
`evidence/umk3-regions-20261116` in the project workspace.

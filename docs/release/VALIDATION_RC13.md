# RC13 validation and scope

RC13 is staged locally from the accepted SoulSilver Beta2 cumulative runtime at source c24fddcc9cc2299babfce1cdfcf3ecd6f34bcab7, descended from rc12 source 9a661c8b66615afd711cad294a57f07c1d1d5309. No publication is authorized by this record.

## Components and release checks

- FPGA SHA-256: 876ec97a6044191515a0fea910eb1359417a466fdd0a23e31e0cca2a069a08fa; unchanged. All 1,978 frozen build inputs are checked by the packager. Static timing is not closed.
- Renderer SHA-256: 8da111f3b9ad9ea1d55b12f9b76be8687d37a50a4d1bde7482b2e98a76c4c313; unchanged accepted FFTA2 Beta2 binary, source 70e35668b43a8da4f544324fbe13a42d2fee0ceb.
- Host SHA-256: 7126bc4b5356d4aa33830baab47e3ff70047e6c2a414d825fc803c6e0ea23515. ELF comparison against the accepted beta proves identical executable code; only the release label and build ID differ. Both C++ host reader/protocol tests passed in the pinned compiler container.
- Guest catalog SHA-256: f92998bc27562fbe33c46ed27d50680f88ef1022e97b324dd6d411188883d1ee. Exact accepted entries and selection are preserved. The unused trial manifest is omitted from the install tree.
- Supervisor differs from the accepted beta only in release version text. The launcher selects the same catalog at the normal standalone kit path.

The packager verifies both complete checksum inventories, component/supervisor pins, nested source safety, frozen FPGA inputs and an upgrade overlay that preserves save/settings sentinels. RC13_PACKAGE_VALIDATION.json and RC13_EXTRACTED_VALIDATION.json accompany the ZIP. RC13_STREAM_VALIDATION.json checks the actual ZIP worker's virtual images against nine previously qualified game/FMV/control images and verifies original ROM hashes remain unchanged. These external receipts describe post-package checks without altering the immutable ZIP.

## Retained bounded measurements

| Game / scene | Comparison | Result | Interpretation |
| --- | --- | --- | --- |
| FFTA2 opening idle / movement / Fire window | Beta2 versus Beta1 | approximately +3.7% / +3.1% / +2.4% | Completed buffer updates; separate series, not a combined rc12 gain |
| Platinum outdoor route | terrain patch versus matched control | +13.16% | Two matched trials per mode; not whole-game FPS |
| HeartGold plaza | terrain patch versus original matched control | +3.07% | Bounded terrain workload |
| SoulSilver plaza | terrain patch versus matched control | 18.812 → 20.0285 updates/s (+6.47%) | Matched noon route; indoor ceiling unchanged |
| SoulSilver starter idle | Beta2 versus Beta1 | 14.231 → 43.944 updates/s (+208.79%) | Two 30-second windows in one fresh session per arm; no confidence interval |

SoulSilver Beta2 was tested using its actual packaged launcher: 210 installed files and 4,798 protected files were checked, with starter choice, ordinary Save, soft-reset Continue, cold Continue/party and lab exit. Reference starter tests matched screen/save outputs, with timing/RAM/audio differences retained. This does not establish full battle or late-game equivalence. The exact rc13 ZIP has not been launched on the MiSTer.

Platinum uses the explicitly accepted perceptual/functional budget. Its outdoor reference includes six top-screen differences plus RAM/audio differences. A later fixed-input battle replay produced different HP and battle progression. It remains unresolved whether that difference is wholly attributable to altered input/RNG phase; it is documented, not represented as battle equivalence. HeartGold/SoulSilver likewise retain non-bit-exact timing/state/audio differences under the accepted budget.

No unaccepted guest FFTA2, Animal Crossing or Phantom candidate is activated. Phantom's final dispatch experiment matched 7,200 reference screen pairs but yielded only +0.28% native stationary throughput and no walking benefit, so it was parked. Full research and raw recordings remain in local evidence rather than the public install archive.

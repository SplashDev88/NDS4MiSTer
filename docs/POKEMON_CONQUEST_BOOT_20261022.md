# Pokémon Conquest startup diagnosis

Status: boot fix confirmed on hardware with the original, unmodified revision-1
ROM. The private beta reaches the title, accepts new-game controller/touch
input, and enters the opening battle presentation. Save/reload, extended play,
and revision-0 validation on the fixed image remain pending. This is not a
public release qualification.

## Failure and cause

Both USA/Australia revisions (VPYT, revisions 0 and 1) remain on two white
screens with the unchanged Ni no Kuni Beta2 runtime. Start/A do not advance
startup. The exact revision-1 ROM reaches its title in the vendored melonDS
interpreter in DS mode. A reference-initialized 256 KiB flash save does not
resolve the hardware failure. This game does not require NAND saving.

The game tests cartridge mirroring during startup. On a 256 MiB cartridge,
a B7 read at `0x10001000` must first wrap to `0x1000`, then follow the protected
low-area rule to `0x8000`. The core applied the protected-area rule before the
DDR bridge masked the image-bank bits. It therefore read raw ROM offset
`0x1000` instead. The same error affects the test's `0x10001200`, `0x10001400`
and `0x10001600` requests.

A passive FPGA probe located ARM9 in a fatal-exit loop. Further private probes
stopped the game immediately after its cartridge tests, before failure cleanup
could erase the results. Of twenty captured checksum words, sixteen exactly
matched the reference. The four mirrored low-area results were `BD7BC39F`
instead of `C710F98E`. Applying the game's checksum algorithm to the supplied
ROM confirms that these are respectively the raw zero-filled padding and the
protected redirect target. These checksums are from the game's algorithm,
not the usual zlib CRC convention.

In a separate reference-emulator control, delaying address masking until after
the low-area check and disabling the DSi-area restriction reproduces both
white screens and the fatal-exit CPU state. All twenty checksum words from
this faulty reference control exactly match the captured hardware results.
Disabling the DSi-area restriction
alone still reaches the title, as does making reads linear rather than wrapping
within a 4 KiB page. The absent DSi cartridge-ID flag alone also does not cause
this boot failure.

## Fix

Pass the island's existing 128/256/512 MiB image-bank mask through the console
wrapper to `nds_card`. Apply it when accepting a B7 command in main-data mode,
before the protected low-address redirect. Keep the existing DDR mask.

This deliberately retains the current product bank-size policy; it does not
add per-ROM capacity selection for smaller images. It does not change raw/KEY1
commands, cartridge pacing, prefetch depth, CPU clocks, rendering, or the host
binary. The mask comes from download flags that are stable before CPU execution
and throughout the cartridge session. Passive CPU probes are absent from the
fixed build.

## Validation so far

- The large-ROM/card and loader suite passes all 42 configurations, including
  both cartridge bus owners, prefetch depths 1/4/7, and memory delays 0/3/11.
  Added cases check mirrored protected and ordinary reads for the existing
  128/256/512 MiB banks and preserve distinct high-half reads on 512 MiB media.
- Removing the new mask from a private control build makes the new regression
  fail: expected request `00008000`, actual request `10001000`.
- Back-to-back card-transfer and NAND-card suites pass.
- The original ROMs, installed programs, configuration and saves are protected
  by hash checks. Tests use separate aliases and saves. Diagnostic ROM copies
  and RAM captures remain private and are not release contents.

## Fixed-image hardware check

The complete Quartus build passed on October 22, 2026. The fixed RBF SHA-256 is
`4e83635200fd64441e0e5055eb707f652e2cb3ea4cdd76807e8706c4b99a5e26`.
The exact product-source fix is commit
`5924000f9d422fc624fdc0aecad424eab5ca9325`, built with the same three enabled
graphics-retirement/status experiments as the preceding private beta. Host and
renderer hashes are unchanged. Diagnostic CPU probes are absent.

With an isolated fresh save and the unmodified VPYT revision-1 ROM, the fixed
image passed the formerly fatal startup checks, displayed the publisher screens
and opening movie, reached the title, and accepted controller and touch input
through character selection and naming. The story advanced into the first
battle presentation. Coherent native-frame captures show zero transport faults,
and an independent RetroTINK capture confirms the title on the physical output.
The user reported that it "seems to work great"; automated inputs were then
paused to avoid interfering with their testing.

The flash-save file initializes and changes, but persistence of a player-created
save across exit/relaunch has not yet been verified. The earlier revision-0
failure is confirmed; the fixed image has not yet been tested with that revision.
No whole-game green compatibility rating follows from these checks.

Static timing closure remains unresolved: the final report still has negative
slack. Successful compilation must not be described as timing closure. The
separate Ni no Kuni speed report's unresolved Mario Kart moving-segment result
also remains unresolved; this cartridge fix is not a new speed qualification.

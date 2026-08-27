# On-demand cart reads stall or lose gameplay assets

## Status

Backlog. User-reported during play testing. Heni identified excessive cart
access latency as the suspected common cause; confirm it with transaction
timing before changing the implementation.

## Symptoms

- New Super Mario Bros.: Fire Mario performs the throw animation, but the
  fireball does not appear.
- Kirby: inhaling can lock up when the game fetches ability data from the
  cartridge.

Both cases appear to request gameplay data from the cartridge on demand. The
working hypothesis is that the core's cart response takes longer than the game
allows, rather than either asset being a rendering-only defect.

## First diagnostic gate

For each reproduction, capture the cart command, address, requested length,
start cycle, first-response cycle, completion cycle, wait-state state, and CPU
PC/DMA state. Compare the same request with the melonDS oracle and identify the
first timing or data divergence. Also record whether the request eventually
completes, returns incorrect data, or remains stalled.

## Acceptance

- Fire Mario reliably produces a visible, functional fireball for repeated
  throws in NSMB.
- Kirby can repeatedly inhale and obtain ability data without locking up.
- Cart-read data and completion timing stay within the DS-visible contract,
  without regressing boot, level loading, or sustained streaming.

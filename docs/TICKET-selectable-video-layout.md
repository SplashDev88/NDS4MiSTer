# User-selectable integer video layout

## Status and order

Backlog. Implement only after hybrid 3D and sound are stable and their final
Quartus fit is known. Side by side remains the default because it is the
currently proven `cfeeda58` video path.

This is feasible without a second framebuffer or scaler. The current
`nds_nitro_fb_ddr3` already has the 512x36-bit four-bank line buffer required
to hold both screen lines for side-by-side scanout. Stacked scanout can reuse
the same RAM, DDR framebuffer, pixel unpacker, fractional pixel enable, and
MiSTer scaler.

## User-visible modes

| Menu value | Native source | Order | Scaling contract |
| --- | --- | --- | --- |
| `Side by side` | 512x192 | screen A left, screen B right | largest exact integer multiple, nearest-neighbour |
| `Stacked` | 256x384 (2:3) | screen A top, screen B bottom | largest exact integer multiple, nearest-neighbour |

Stacked must not be implemented as an aspect-ratio-only 2:3 request. The
earlier aspect-only presentation showed tearing. Both modes must request an
explicit pixel rectangle with bit 12 of `VIDEO_ARX`/`VIDEO_ARY` set, and the
MiSTer scaler must center that rectangle.

For standard outputs, required examples are:

| HDMI active area | Side by side | Centered rectangle | Stacked | Centered rectangle |
| --- | ---: | ---: | ---: | ---: |
| 1280x720 | 1024x384 (2x) | x=128, y=168 | 256x384 (1x) | x=512, y=168 |
| 1920x1080 | 1536x576 (3x) | x=192, y=252 | 512x768 (2x) | x=704, y=156 |

Do not silently fall back to fractional/aspect-only scaling when a target
cannot fit one native pixel multiple. The acceptance target is standard
720p-and-larger HDMI; a smaller unsupported target may remain black rather
than violating the integer-scaling contract.

## MiSTer menu ABI

Keep the historical/future sound bit at `status[5]` and allocate the next
single bit to layout:

```systemverilog
"O[6],Screen layout,Side by side,Stacked;"
wire layout_requested = status[6]; // 0 = side by side, 1 = stacked
```

Place the option after the sound option in `CONF_STR`. `status[6]=0` preserves
the proven default. Re-audit the final post-sound status map before merging;
sound and layout must never share a bit.

## Lowest-resource implementation

Use one `nds_nitro_video_scanout`, not two complete scanouts followed by a
mux. A frame-latched `layout_active` selects timing constants, line-buffer
address mapping, and the existing prefetch schedule:

- side by side: active 512x192, total 1066x263, line-buffer address
  `{row_parity, hcount[8], hcount[7:1]}`; request screen A and B for the next
  row at the two existing half-line points;
- stacked: active 256x384, total 533x526, line-buffer address
  `{row_parity, vcount >= 192, hcount[7:1]}`; reuse the proven stacked
  two-lines-ahead schedule, mapping output rows 0..191 to A and 192..383 to B.

Both rasters contain exactly 280358 total dots per frame. Retain the same
`PIXEL_STEP`, frame cadence, RGB unpacker, and minimum 31.8 us spacing between
prefetch toggles. Do not run both prefetch schedules concurrently: the
existing toggle crossing has one pending slot.

The 3D result is already merged into engine A before this framebuffer, so the
layout selector must remain downstream of 2D/3D composition. Sound, console
timing, input, DDR framebuffer writes, and HPS 3D session state are not part of
the switch.

## Atomic switch and reset contract

`layout_requested` may change at any pixel, but it only updates a pending bit.
The active layout and its explicit `VIDEO_ARX`/`VIDEO_ARY` rectangle change
together after the last pixel of the current complete raster.

At that boundary:

1. finish the old frame entirely in the old geometry;
2. latch the latest pending layout and restart only the scanout counters and
   new-layout prefetch schedule at (0,0);
3. preserve the framebuffer RAM, line-buffer RAM, and monotonic `pf_tgl` CDC
   state; do not pulse core, CPU, sound, or H3D reset;
4. output one complete black priming frame in the new raster while issuing all
   normal new-layout prefetches;
5. unblank only at the next new-layout frame boundary.

A request that changes again during the priming frame is coalesced to the
latest value and remains black through another priming frame if needed. This
allows a brief intentional black/resync interval but forbids a frame containing
both layouts, stale screen-bank addressing, or a partial scaled rectangle.

On cold/core reset, sample the saved menu setting before the first visible
frame and use the same priming rule. A reset must not force a persisted Stacked
selection to appear briefly as visible side-by-side video.

## Expected resource delta

The target delta against the final sound-plus-3D baseline is:

- zero additional M10K/MLAB blocks and zero DSPs;
- no duplicate framebuffer, scanout, scaler, or 3D return plane;
- only timing/address muxes, compares, and a few control registers: expected
  tens of ALMs, with a hard review target below 100 ALMs.

Record the exact Quartus fit delta. If synthesis adds a second line store or
materially duplicates the scanout cone, refactor to the single-path design
before accepting the feature.

## Acceptance

1. Extend `tb_nds_nitro_video_scanout` to prove both active geometries, the
   identical 280358-dot cadence, exactly 384 line prefetches per frame, screen
   order, line/bank addresses, and minimum toggle spacing.
2. Toggle the request at every interesting raster position. The trace must be
   one complete old-layout frame, one black new-layout priming frame, then one
   complete new-layout frame, with no mixed-layout frame or CDC request loss.
3. Use a one-pixel checkerboard/coordinate pattern at 720p and 1080p. Captures
   must show the exact centered rectangles above, integer pixel replication,
   nearest-neighbour edges, no interpolated columns/rows, and no tearing.
4. Switch both directions repeatedly during Kirby and a 3D game. CPUs, input,
   sound, the HPS 3D session, and frame cadence must continue without reset or
   fault; only the specified priming frame may be black.
5. Run at least ten minutes in each layout and repeat the existing side-by-side
   video/controls regression. Stacked must show A above B with neither screen
   stretched, cropped, duplicated, or reordered.
6. Quartus must pass timing and preserve the post-sound/post-3D resource
   budget; the fit report must confirm the zero-RAM/zero-DSP delta target.

## Feasibility gate

There is no known architectural blocker. The old stacked timing is already in
history (`2f18b26f`), and the current side-by-side line buffer is a superset of
what it needs. The only remaining gate is measured fitter headroom after sound
and hybrid 3D, which is why this item stays behind those two milestones.

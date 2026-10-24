# Native DV1 menu proportions

The legacy native menu chooses its horizontal pixel size from the number of
transport clocks in an active line. That grid differs from the DS pixel grid.
On a stacked DV1 picture, a font column can occupy one transport clock while
a game pixel occupies three, and menu rows can be doubled independently.
External rotation makes the resulting distorted lettering especially obvious.

The DV1 correction uses the scanout pixel enable to address the existing menu
bitmap. One font pixel occupies one game pixel in each direction. The complete
256-column menu fits a 256-pixel source without clipping its first or last
columns. Normal menus retain16 rows; loading messages retain8 rows. Native
video and its menu rotate together on the external scaler.

The correction is enabled only when HDMI uses native Direct Video and analog
uses either its independent raster or the HDMI scaler. It is disabled for
ordinary HDMI, scaled VGA and the legacy shared analog raster. Independent
analog keeps the existing menu implementation even during DV1 operation.
Bitmap storage, the write queue and RGB/sync latency remain unchanged.

The optional fourth response to system command0x46 is0x4e50, with bit0 set
while this raster is active. The host requires the existing0x4456 signature,
the0x5350 split-output capability and the exact0x4e51 active response before
removing the DV1 high-resolution OSD flag. The new menu can be decimated like
the game image, so opening it no longer asks the receiver to change sampling.
Older FPGA images retain their original metadata behavior. Two matching
geometry and raster-mode observations are required before updating metadata.

## Validation

`python3 tools/test_dv1_osd.py` compares the new DV1 output with an independent
pixel oracle, including varying background pixels and all sync signals.
It also compares the non-DV1 and simultaneous analog outputs against the
released pre-fix implementation. Coverage includes320x240,256x192,256x392,
256x414 and536x198, pixel repetitions3/6/10,8/16 rows, hidden menus and
transitions back to the legacy raster. All18,054,528 checked samples per
output passed, including both edge columns.

The shared-bitmap/write-queue regression, loading-window rotation tests,
actual host display-menu and DV-target tests, dual-output host/RTL trace,
and DV1 metadata tests cover the unchanged paths and protocol fallback.
The older split-output host test still has a stale hard-coded menu-row
assertion; the same assertion fails on the unchanged release source.

FPGA routing and physical capture validation are pending. The experimental
FPGA build starts from the exact frozen rc10 FPGA inputs and overlays only
the menu raster, OSD integration, capability response and source-file list.
The release notes and README are unchanged.

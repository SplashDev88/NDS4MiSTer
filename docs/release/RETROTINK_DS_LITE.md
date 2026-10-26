# Optional DS Lite-style RetroTINK 4K setup

This manual recipe reproduces the tested Tate appearance. It is a visual approximation, not a calibrated Nintendo DS Lite panel or an importable profile. The release does not change your RetroTINK or saved core display settings.

In the core, select **Top/Bottom** and **Video Rotation: 90 CW**. Rotate the physical display as appropriate. Leave RetroTINK rotation **Off**.

On the tested RetroTINK 4K firmware 1.99.5:

| Setting | Value |
| --- | --- |
| Output | 1920×1080p60 |
| Aspect | 1:1 square pixels |
| Scaling | Auto Fill Integer; verify 4×4 native game pixels |
| Crop | Zero on all sides |
| LCD effect | LCD Mono 2 / LCD Grid 2 |
| LCD subpixel / vertical strength | 0 / 0 |
| Linear light | On |
| Normalize energy | Off |
| Mask, smoothing, horizontal blur, HDR | Off |
| RGB range | Full; match the display |
| Colorimetry | Auto Rec.709 |
| Sync | A. Buffer 60.0 Hz |
| Input factor / lift / gain | 1.0 / 0.0 / 1.0 |
| Output factor | 1.0 |
| Transfer function | sRGB 0.055 |
| Custom color matrix | Off |
| Saturation | 0.0 |

The measured rotated composite was 392×256 game pixels, mapped to 1568×1024 output pixels. Save this under a separate profile name such as `ds-lite-tate-1080p`. Use full-pixel/no-overscan display mode. The tested recipe was saved on the device; persistence after a profile reload/power cycle was not separately qualified.

Use a separate profile for other layouts. With this LCD effect, rotated left/right and some single-screen layouts can become very dark, and native analog output can show banding. Turning the LCD effect Off restores visibility in the tested controls. Do not assume the Tate profile is suitable for every output or rotation.

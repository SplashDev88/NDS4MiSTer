# Private right-stick touch range beta

Controllers with limited diagonal travel can reach the touchscreen edges but
miss its corners. The root menu’s **Right Stick Range** setting adds 100%,
125%, 150%, 175% and 200% choices. Start at 150% and select the lowest value that reaches all
four corners. Higher values reach the edges earlier, reducing fine positioning
travel. The 100% default is unchanged.

Run **Scripts → NDS_Touch_Range_Beta**, load a game and open the core menu.
Select **Right Stick Range** directly below **Display options**. Enter/the menu
select button cycles values; keyboard +/- also works. Close the menu to apply. Choose
**System → Save settings** to retain the choice after relaunch.

The setting applies to all controllers using this kit. Mouse input, touch
rotation, touch-press bindings and controller mapping files retain their
behavior. **Reset settings** restores 100%. Missing or invalid `NDS_stick.cfg`
files also default to 100%. Display options and saved mappings keep their
existing formats.

This is a separate private launcher based on Automatic FMV RC1. Its renderer,
FPGA image, movie preparation and 1 GHz clock are unchanged. It adds small
integer coordinate scaling only when handling right-stick input or restoring
input after the menu closes. No new rendering work is introduced. Existing
public and FMV RC1 installations are retained.

## Validation

Beta2 removes the Controls submenu. Five focused host test programs were rerun
for the root-menu adjustment: touch range, touch rotation, general host, display
menu and split output. The range math and settings format are unchanged; the
native touch measurements below were collected on Beta1.

Nine host test programs pass: touch range, touch rotation, motion input, general
host behavior, display menu, split output, Direct Video target, screen peek and
board buttons. The touch tests verify all 65,536 default coordinate pairs,
monotonic/clamped output, driver axis ranges, neutral/dead-zone behavior,
rotated corner reach, mouse/button isolation and save/reset behavior. Existing
menu expectations were updated for the direct Right Stick Range entry.

A native diagnostic ROM was tested on MiSTer using a temporary virtual
controller through the ordinary Linux input, host, FPGA and DS touchscreen
paths. It reads the DS touch ADC and draws the result; read-only framebuffer
captures independently verify the reported coordinates.

- With each diagonal axis limited to about 70% travel, 100% produces X=38/218
  and Y=28/163, missing the corners.
- Selecting 150% through the menu reaches all four exact corners: X=0/255,
  Y=0/191. Center remains X=128, Y=96.
- Saving 150%, exiting and relaunching retains that behavior. All four corners
  and center pass again after relaunch.

The physical controller from the report has not been tested. These results
verify the adjustment and the limited-travel case; its owner should choose the
smallest percentage that reaches every corner. This feature did not receive a
new full gameplay/FMV benchmark sweep. Automatic FMV RC1's prior measurements
remain baseline evidence, not new measurements of this host.

## Files and rollback

The private ZIP contains a separate launcher and hidden support folder. Extract
to the SD card root, including hidden files. No games, BIOS/firmware dumps,
saves or user settings are included. Existing settings in this kit are kept
when updating. Launch the earlier script to return to the earlier build; game
saves use the normal shared NDS save folder.

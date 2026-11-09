NDS4MiSTer RC15 AA Beta1

Extract the ZIP at the root of the MiSTer SD card. Run Scripts > NDS_RC15_Beta1.
This installs beside RC14. Run your usual NDS4MiSTer launcher to return to RC14.
Both launchers use your normal NDS saves. The beta has separate display settings.

Open the core menu, choose Display options, then 3D Anti-aliasing: On/Off.
The change takes effect while the game is running. On is the default and honors
the game's own AA enable bit. Off reduces edge smoothing on 3D geometry.
To keep the choice after exiting, return to the main menu, press Right for
System, and choose Save settings. Reset settings restores AA On.

This beta retains the published RC14 FPGA, clocks, loader, game patches, sound
and display routing. It adds the AA control and matching host/renderer support.
Fog, shadows and edge marking retain their normal behavior. Experimental cache
and Mario Kart patches are not included.

Prior AA-off tests improved completed screen updates in some scenes; they did
not establish faster game clocks. The effect varies by game and scene. Please
compare On and Off in NSMB, Dawn of Sorrow and Mario Kart, including visual
quality. This is a private beta, not a published release. Existing RC14 FPGA
timing and compatibility limitations remain. Hardware qualification is recorded
separately from this reproducible package.

# Install and update NDS4MiSTer

1. Exit NDS with **System → Reboot** before updating.
2. Extract the full ZIP to the SD card root, including hidden files. Merge folders and replace package files.
3. Run **Scripts → NDS**. The installed version appears in the core menu.

The launcher is always `Scripts/NDS.sh`. Runtime files, settings, controller mappings and the clock are under `Scripts/.NDS/`. The ZIP contains no saved preferences. On first launch, missing settings are copied from `.NDS_RC15`, then `.NDS_Standalone`; existing `.NDS` files take priority. Originals remain intact. Recognized old public launchers are backed up under `.NDS/legacy-launchers/` and removed from the Scripts menu. Custom launchers and private betas are left alone.

Back up `saves/NDS/` and `Scripts/.NDS/NDS_rtc.cfg`. Choose **System → Save settings** after changing preferences. See the project README for controls, video setup and compatibility.

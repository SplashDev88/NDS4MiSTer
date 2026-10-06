# Source acknowledgments

MiSTer Main (GPLv3): https://github.com/MiSTer-devel/Main_MiSTer at 5fb9bd102024ac16a92291f291318d5846dcaae2. The font is copied from charrom.cpp; GPIO SPI, OSD and file I/O protocol behavior is adapted from fpga_io.cpp, spi.cpp, user_io.cpp and osd.cpp. File-picker layout, progress messages and scrolling behavior in menu_presentation.h and its reference tests are adapted from menu.cpp's PrintDirectory, ProgressMessage and set_text, plus osd.cpp's ScrollText. OSD lineage credits Dennis van Weeren (2005–2007), Jakub Bednarski (2008–2009), and the Minimig/MiSTer contributors. System layout, scrolling and dimmed-row rendering follow menu.cpp MENU_COMMON1/MenuWrite and osd.cpp; Reset-settings and Recent Files layouts/shortcuts follow menu.cpp and input.cpp; recent_files.h interoperates with recent.cpp's fixed record format. Existing attribution has been retained where copied.

DreamSTer https://github.com/skmp/DreamSTer at f31c15856760460abd8c41356d3ca98468ee4346 informed the process takeover/restart design. No DreamSTer code is copied. Thanks to Corn for the suggestion and skmp for the reference.

The experimental DV1 packet layout, video measurement protocol and ADV7513 SPD
update sequence in direct_video.h follow MiSTer Main video.cpp at
6cda9cc546c4b32e256a19931128b82586253812 (GPLv3). The standalone host retains
Main's selected transmitter bus, color conversion and audio configuration.

The built-in BIOS initialization and host restore arrays come from the pinned
melonDS FreeBIOS data, licensed BSD-2-Clause, copyright 2013 Gilead Kutnick.
Retain the full notice in `third_party/melonDS/freebios/drastic_bios_readme.txt`
with redistributed assets. These BIOS arrays contain no user profile.

Generated SPI firmware and `builtin_firmware_profile.h` derive from the pinned
synthetic melonDS firmware under GPL-3.0-or-later, copyright 2016–2026 melonDS team.
The project applies its MiSTer nickname and virtual-touch defaults locally,
without modifying vendored melonDS defaults or embedding console dumps. The
writable firmware store retains the contribution credit to InsaneFriend
(GitHub: saneFriend). Keep generator source and its pinned provenance with
redistributed generated assets.

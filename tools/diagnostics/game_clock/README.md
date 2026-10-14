# RTC diagnostic

Original ARM7 GPIO reader and ARM9 bitmap display, with no game assets,
cartridge-save commands or firmware-flash writes. Build with `bash build-rom.sh`.
The default is read-only. Date/time are BCD; counters are hexadecimal.

**A** writes 2024-02-28 23:59:58, Wednesday, to test leap-day rollover.
**B** writes 2099-12-31 23:59:58, Thursday, to test century rollover.
These actions change the DS clock and are persisted by an RTC-enabled host.
Use an isolated test kit. Back up that kit's `NDS_rtc.cfg` before testing and
restore it (or remove the newly created file) with the host stopped afterward.
Then cold-launch to seed the normal clock. Never change the MiSTer system time.

The diagnostic does not test RTC alarm interrupts.

# Linux 6.18.38 compatibility beta

Based on accepted v0.9.0-rc.2. Run **Scripts → NDS Linux Test** (the file is
`NDS_Linux_Test.sh`). The private support directory is `Scripts/.NDS_Linux_Test`.
The existing release installation remains intact. The menu still displays
rc.2 because its executable, the renderer and the FPGA binary are unchanged.

The port rebuilds the restricted write-combining driver for 6.18.38-MiSTer
and adopts that kernel's loadable CPU-frequency driver and explicit boost
interface. NDS runs at the same 1 GHz target; it does not select 1.2 GHz.
System → Reboot returns to normal MiSTer and restores the prior CPU policy.
ROMs, BIOS files, saved personal firmware and cartridge saves keep their
existing locations. No Nintendo files are part of the test package.

The previous 5.15 module is retained for that kernel. Its runtime path is
covered by offline tests; no kernel downgrade was used during this port.
Only the user's 6.18.38-MiSTer board has been tested for the new binary.

## Validation

- 34 offline launcher, recovery, module-selection and clock tests pass.
- Normal, unforced module insertion and unload pass.
- Allowed 3 MiB mappings pass; control memory and out-of-range mappings fail.
- Start selects 1 GHz; exit restores 800 MHz and boost Off on the test board.
- The kernel's frequency statistics report no time at 1.2 GHz.
- Identical Device → WC → Device pixel-publication runs verify every pixel:
  full-frame mean 8.53 / 1.63 / 8.66 ms. Sparse updates 1.53 / 1.04 / 1.55 ms.
  This measures publication only, not gameplay FPS or a gain over rc.2 on
  its old kernel. It confirms WC remains effective on the new kernel.
- NSMB reached its title menu, Castlevania played its opening video, and
  512 MiB Pokémon White 2 reached its intro. Each 20-second telemetry
  recording had zero FPGA/HPS fault samples and advancing frames. Screenshots
  were inspected. Three graceful exits restored normal MiSTer, unloaded WC
  and restored 800 MHz / boost Off; relaunch also passed with the CPU driver
  initially unloaded. Game checks are recorded in the private hardware report.
  Remote startup/telemetry tests do not establish subjective smoothness,
  audio quality or complete game compatibility.

## Source references

The clock behavior was checked against the [MiSTer driver](https://github.com/MiSTer-devel/Linux-Kernel_MiSTer/blob/6a581bac47c32dfd2525f9874fd263cf08058610/drivers/cpufreq/socfpga-cpufreq.c)
and [Linux CPU-frequency boost implementation](https://github.com/MiSTer-devel/Linux-Kernel_MiSTer/blob/6a581bac47c32dfd2525f9874fd263cf08058610/drivers/cpufreq/cpufreq.c).
Exact kernel source, compiler and config identities are in
`kernel/nds_mem_wc/BUILD_PROVENANCE-6.18.38.json`.

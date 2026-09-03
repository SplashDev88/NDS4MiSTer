#pragma once

namespace nds4mister::h3d {
struct Header;
}

namespace nds4mister::crash {

// Installs a minimal, async-signal-safe fatal-signal handler. The output path
// can be overridden with NDS4MISTER_CRASH_DUMP_PATH; otherwise each process
// writes /media/fat/nds_crash_<pid>.txt.
bool install_arm_crash_handler();

// SIGUSR1 is the public/manual FPGA capture request. The signal handler only
// sets a flag; the normal monitor thread performs all I/O and optional hold.
bool consume_manual_fpga_snapshot_request();

// SIGUSR2 requests a behavior-neutral video-pipeline snapshot. As with the
// FPGA snapshot, the signal handler only sets a flag; the service performs
// the comparatively expensive buffer copies and file I/O from normal code.
bool consume_manual_video_snapshot_request();

// Makes the live transport state available to the handler after /dev/mem has
// been mapped. Pass nullptr before the mapping is released.
void set_arm_crash_shared_header(volatile h3d::Header* header);

} // namespace nds4mister::crash

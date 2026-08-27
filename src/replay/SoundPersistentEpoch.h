#pragma once

#include <cstdint>
#include <string>

namespace nds4mister {

// Allocate a nonzero, monotonically increasing sound-session epoch from a
// persistent file.  The updated value is made durable before it is returned,
// so a responder crash may skip an epoch but cannot intentionally reuse one.
//
// A malformed, truncated-after-use, or exhausted record fails closed.  The
// caller owns the path and must preserve it across FPGA/responder restarts.
std::uint32_t allocate_persistent_sound_epoch(const std::string& path);

} // namespace nds4mister

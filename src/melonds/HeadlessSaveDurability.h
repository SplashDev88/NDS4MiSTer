#pragma once

#include <cerrno>

namespace nds4mister {

// Some FAT/exFAT implementations accept an atomic rename after the file has
// been synced but do not implement fsync on a directory descriptor.  Those
// errors lower the power-loss durability guarantee, but retrying the complete
// save forever cannot make the unsupported directory operation succeed.
inline bool headlessSaveDirectorySyncUnsupported(int error) noexcept
{
    return error == EINVAL || error == EROFS
#ifdef ENOTSUP
        || error == ENOTSUP
#endif
#ifdef EOPNOTSUPP
        || error == EOPNOTSUPP
#endif
        ;
}

} // namespace nds4mister

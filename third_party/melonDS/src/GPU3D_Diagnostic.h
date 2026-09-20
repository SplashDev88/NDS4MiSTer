#ifndef GPU3D_DIAGNOSTIC_H
#define GPU3D_DIAGNOSTIC_H

#include <algorithm>
#include <cstdio>
#include <string_view>
#include <sys/resource.h>

namespace melonDS
{
// Private diagnostics share the launcher's stdout/stderr file-size limit.
// Respect it for each artifact instead of raising it or catching SIGXFSZ.
inline bool WriteBounded3DDiagnostic(const char* path, std::string_view text)
{
    size_t limit = 60 * 1024;
    rlimit resource {};
    if (getrlimit(RLIMIT_FSIZE, &resource) != 0) return false;
    if (resource.rlim_cur != RLIM_INFINITY)
        limit = std::min(limit, static_cast<size_t>(resource.rlim_cur));
    constexpr std::string_view marker = "TRUNCATED_BY_DIAGNOSTIC_LIMIT\n";
    if (limit < marker.size()) return false;
    const bool truncated = text.size() > limit;
    if (truncated)
    {
        text = text.substr(0, limit - marker.size());
        const auto newline = text.rfind('\n');
        text = newline == std::string_view::npos ? std::string_view{} :
            text.substr(0, newline + 1);
    }
    FILE* file = std::fopen(path, "wb");
    if (!file) return false;
    bool ok = std::fwrite(text.data(), 1, text.size(), file) == text.size();
    if (ok && truncated)
        ok = std::fwrite(marker.data(), 1, marker.size(), file) == marker.size();
    return std::fclose(file) == 0 && ok;
}
}
#endif

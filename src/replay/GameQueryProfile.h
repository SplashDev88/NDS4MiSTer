// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace nds4mister::replay {

// Private standalone experiment, tracked in GitHub issue #41. This is a
// session-start choice, never a live toggle of partially tracked matrix state.
using GameQueryHeader = std::array<std::uint8_t, 0x160>;
struct GameQueryIdentity {
    std::array<std::uint8_t, 4> code {};
    std::uint8_t revision = 0;
    std::uint32_t header_crc32 = 0;
};
enum class GameQueryProfile { Fast, CastlevaniaDosUsRevision0 };

inline std::uint32_t game_query_crc32(const std::uint8_t* data, std::size_t size)
{
    std::uint32_t crc = 0xffffffffu;
    for (std::size_t i = 0; i < size; ++i) {
        crc ^= data[i];
        for (unsigned bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
    }
    return ~crc;
}

inline GameQueryIdentity game_query_identity(const GameQueryHeader& header)
{
    return {{{header[12], header[13], header[14], header[15]}}, header[30],
            game_query_crc32(header.data(), header.size())};
}

inline GameQueryProfile select_game_query_profile(const GameQueryIdentity& id)
{
    // Exact header fingerprint of the tested USA cartridge, not its filename
    // or title prefix. Other regions, revisions and headers retain fast replies.
    if (id.code == std::array<std::uint8_t, 4>{{'A','C','V','E'}} &&
        id.revision == 0 && id.header_crc32 == 0xc51a7d99u)
        return GameQueryProfile::CastlevaniaDosUsRevision0;
    return GameQueryProfile::Fast;
}

inline unsigned game_query_prefix_mode(GameQueryProfile profile)
{
    return profile == GameQueryProfile::CastlevaniaDosUsRevision0 ? 0u : 2u;
}

inline const char* game_query_profile_name(GameQueryProfile profile)
{
    return profile == GameQueryProfile::CastlevaniaDosUsRevision0 ?
        "castlevania-dos-us-r0-ordered" : "default-fast";
}

struct GameQuerySelection {
    GameQueryProfile profile = GameQueryProfile::Fast;
    GameQueryIdentity identity {};
    bool identified = false;
};

// Fingerprints of the qualified virtual cartridge headers, after the loader
// has verified the full original ROM and assembled its guarded movie hooks.
// This only enables the receiver; it does not select or patch a guest player.
inline bool automatic_movie_receiver_profile(const GameQuerySelection& selected)
{
    if (!selected.identified) return false;
    constexpr GameQueryIdentity movies[] = {
#include "replay/AutomaticMovieProfiles.inc"





    };
    for (const auto& movie : movies)
        if (selected.identity.code == movie.code &&
            selected.identity.revision == movie.revision &&
            selected.identity.header_crc32 == movie.header_crc32)
            return true;
    return false;
}
// The measured sprite-raster shortcut is selected independently of query
// reply policy. Unknown/revised headers retain the established raster path.
inline bool castlevania_integral_texture_profile(const GameQuerySelection& selected)
{
    return selected.identified &&
        select_game_query_profile(selected.identity) ==
            GameQueryProfile::CastlevaniaDosUsRevision0;
}

inline bool nsmb_recovery_profile(const GameQuerySelection& selected)
{
    return selected.identified &&
        selected.identity.code == std::array<std::uint8_t, 4>{{'A','2','D','E'}} &&
        selected.identity.revision == 0 && selected.identity.header_crc32 == 0x01ebee25u;
}

// Exact Portrait identity selects its qualified raster and replay policy.
// Other cartridges keep their independent automatic policy.
inline bool portrait_sprite_raster_profile(const GameQuerySelection& selected)
{
    return selected.identified &&
        selected.identity.code == std::array<std::uint8_t, 4>{{'A','C','B','E'}} &&
        selected.identity.revision == 0 && ((selected.identity.header_crc32 == 0xa9935ea4u) | (selected.identity.header_crc32 == 0x2b8de1e5u));
}

// Independent Ecclesia raster experiment. Keep its established query policy
// while measuring the exact rectangle/sprite path on this verified cartridge.
inline bool ecclesia_sprite_raster_profile(const GameQuerySelection& selected)
{
    return selected.identified &&
        selected.identity.code == std::array<std::uint8_t, 4>{{'Y','R','9','E'}} &&
        selected.identity.revision == 0 && selected.identity.header_crc32 == 0x89d2e308u;
}

// No remembered selection: every reset/reload starts from the fast default.
// A short/failed read or changing header cannot inherit an earlier game's mode.
template<class ReadHeader>
GameQuerySelection read_game_query_profile(ReadHeader&& read)
{
    GameQueryHeader first {}, second {};
    if (!read(first) || !read(second) || first != second) return {};
    const auto id = game_query_identity(first);
    return {select_game_query_profile(id), id, true};
}
}

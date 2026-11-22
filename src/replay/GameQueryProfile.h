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

inline constexpr GameQueryIdentity BowserRectangleCartridges[] = {
    {{{'C','L','J','E'}}, 0, 0xfbfb7d89u},
};

inline constexpr GameQueryIdentity RadiantHistoriaDrawCartridges[] = {
    {{{'B','R','J','E'}}, 0, 0xf523834du},
};

inline constexpr GameQueryIdentity PinballTableCartridges[] = {
    {{{'A','P','2','E'}}, 0, 0xb04a7abfu},
    {{{'A','P','2','P'}}, 0, 0x5963dd25u},
    {{{'A','P','2','J'}}, 0, 0xd08f11c4u},
};

inline constexpr GameQueryIdentity GoldenSunCartridges[] = {
    {{{'B','O','5','E'}}, 0, 0xda061ea1u},
    {{{'B','O','5','P'}}, 0, 0x70878a14u},
    {{{'B','O','5','J'}}, 0, 0x61c3ac55u},
};

inline constexpr GameQueryIdentity FinalFantasyIIICartridges[] = {
    {{{'A','F','F','E'}}, 0, 0x70de0241u},
    {{{'A','F','F','P'}}, 0, 0xcd3e0d01u},
    {{{'A','F','F','J'}}, 0, 0xffea23e9u},
};

template<std::size_t N>
inline bool matches_game_cartridge(const GameQuerySelection& selected,
                                   const GameQueryIdentity (&cartridges)[N])
{
    if (!selected.identified) return false;
    for (const auto& id : cartridges) {
        if (id.code == selected.identity.code && id.revision == selected.identity.revision &&
            id.header_crc32 == selected.identity.header_crc32) return true;
    }
    return false;
}

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

// Regional Dawn cartridges opt into the exact rectangle/gray raster paths
// independently of the USA query, VRAM replay and integral-texture policies.
// Only these locally verified retail headers are admitted; demos and unknown
// revisions retain the general renderer.
inline bool dawn_regional_raster_only_profile(const GameQuerySelection& selected)
{
    if (!selected.identified) return false;
    static constexpr GameQueryIdentity identities[] = {
        {{{'A','C','V','P'}}, 0, 0x6396d24cu},
        {{{'A','C','V','J'}}, 1, 0x65777634u},
    };
    for (const auto& identity : identities)
        if (selected.identity.code == identity.code &&
            selected.identity.revision == identity.revision &&
            selected.identity.header_crc32 == identity.header_crc32) return true;
    return false;
}

// Exact lighting-result reuse is independent of the cartridge-specific
// query, raster and VRAM policies. Admit the three verified retail headers;
// unknown revisions, altered headers and the kiosk demo keep the old path.
inline bool dawn_lighting_result_reuse_profile(const GameQuerySelection& selected)
{
    return castlevania_integral_texture_profile(selected) ||
        dawn_regional_raster_only_profile(selected);
}

// Opaque3D seeding was measured on Dawn. Admit only the verified retail
// USA, Europe and Japan-revision1 identities; no cartridge-address patch.
inline bool dawn_opaque_3d_seed_profile(const GameQuerySelection& selected)
{
    return castlevania_integral_texture_profile(selected) ||
        dawn_regional_raster_only_profile(selected);
}

// Bounded approximate interpolation was measured on this owned Mario Kart
// cartridge. Other games and unqualified revisions keep exact factors.
inline bool mkds_approximate_factors_profile(const GameQuerySelection& selected)
{
    return selected.identified &&
        selected.identity.code == std::array<std::uint8_t, 4>{{'A','M','C','E'}} &&
        selected.identity.revision == 0 && selected.identity.header_crc32 == 0x388c990cu;
}

// The three catalogued retail GTA cartridges, all revision zero. Renderer
// policies use exact header identities independently of guest-query timing.
// Unknown revisions and altered headers retain their existing paths.
inline bool gta_retail_render_profile(const GameQuerySelection& selected)
{
    if (!selected.identified) return false;
    constexpr GameQueryIdentity identities[] = {
        {{{'Y','G','X','E'}}, 0, 0x1be14a3eu}, // USA
        {{{'Y','G','X','P'}}, 0, 0x05635a2bu}, // Europe
        {{{'Y','G','X','J'}}, 0, 0x63c7d103u}, // Japan
    };
    for (const auto& identity : identities)
        if (selected.identity.code == identity.code &&
            selected.identity.revision == identity.revision &&
            selected.identity.header_crc32 == identity.header_crc32) return true;
    return false;
}

// Existing bounded perspective shortcut and exact neutral-white shader.
// AA and span eligibility checks remain in the renderer, with exact fallback.
inline bool gta_approximate_factors_profile(const GameQuerySelection& selected)
{
    return gta_retail_render_profile(selected);
}

// Exact compressed-palette dependency bounds remain independently selectable.
inline bool gta_compressed_palette_range_profile(const GameQuerySelection& selected)
{
    return gta_retail_render_profile(selected);
}

// Exact full-texture opacity metadata remains independently selectable.
inline bool gta_texture_opacity_profile(const GameQuerySelection& selected)
{
    return gta_retail_render_profile(selected);
}

// Composition-only row reuse is qualified on these Resident Evil cartridges.
// It compares the current completed 3D row and every 2D input, without the
// legacy cache's future-row lookahead. Other cartridges keep their old path.
inline bool resident_evil_paired_a_profile(const GameQuerySelection& selected)
{
    if (!selected.identified) return false;
    constexpr GameQueryIdentity identities[] = {
        {{{'A','B','H','E'}}, 0, 0xc7e5cdf1u}, // USA
        {{{'A','B','H','P'}}, 0, 0x34b87b43u}, // Europe
        {{{'A','B','H','J'}}, 0, 0x244cb079u}, // Japan (Biohazard)
    };
    for (const auto& identity : identities)
        if (selected.identity.code == identity.code &&
            selected.identity.revision == identity.revision &&
            selected.identity.header_crc32 == identity.header_crc32) return true;
    return false;
}

// Resident Evil's room backgrounds contain flat textured quads. Qualify the
// existing exact rectangle raster and horizontal sampling paths separately
// from geometry, guest-query and approximate-interpolation policies.
inline bool resident_evil_background_profile(const GameQuerySelection& selected)
{
    return resident_evil_paired_a_profile(selected);
}

inline bool paired_a_cache_enabled(bool qualified, const char* requested)
{
    if (requested && requested[0] == '0' && requested[1] == '\0') return false;
    if (requested && requested[0] == '1' && requested[1] == '\0') return true;
    return qualified;
}

// USA and Europe are the two catalogued retail UMK cartridges, both revision
// zero. Share their exact renderer/cache policies, independently of query or
// guest-code patches. Unknown or altered headers retain the general path.
inline bool umk3_retail_render_profile(const GameQuerySelection& selected)
{
    if (!selected.identified) return false;
    static constexpr GameQueryIdentity identities[] = {
        {{{'Y','U','T','E'}}, 0, 0x6c631035u},
        {{{'Y','U','T','P'}}, 0, 0x1b8dde13u},
    };
    for (const auto& identity : identities)
        if (selected.identity.code == identity.code &&
            selected.identity.revision == identity.revision &&
            selected.identity.header_crc32 == identity.header_crc32) return true;
    return false;
}

// Exact source hashes can be shared within one flattened VRAM update.
inline bool umk3_texture_range_hash_profile(const GameQuerySelection& selected)
{
    return umk3_retail_render_profile(selected);
}

// Private qualification of the existing exact sprite raster paths. Keep it
// separate from geometry/query and changed-byte VRAM replay policies.
inline bool umk3_sprite_raster_profile(const GameQuerySelection& selected)
{
    return umk3_retail_render_profile(selected);
}

inline bool umk3_rectangle_x_profile(const GameQuerySelection& selected)
{
    return umk3_retail_render_profile(selected);
}

inline bool umk3_palette_decode_profile(const GameQuerySelection& selected)
{
    return umk3_retail_render_profile(selected);
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

// Exact retail and prepared Ecclesia identities share the qualified raster and
// replay policy. Unknown revisions and changed headers retain the default path.
inline bool ecclesia_sprite_raster_profile(const GameQuerySelection& selected)
{
    if (!selected.identified) return false;
    static constexpr GameQueryIdentity qualified[] = {
        {{{'Y','R','9','E'}}, 0, 0x89d2e308u},
        {{{'Y','R','9','E'}}, 0, 0x483c0674u},
        {{{'Y','R','9','P'}}, 0, 0x937e153fu},
        {{{'Y','R','9','P'}}, 0, 0xa1ec237au},
        {{{'Y','R','9','J'}}, 0, 0x6e9bc11du},
        {{{'Y','R','9','J'}}, 0, 0x2858119fu},
        {{{'Y','R','9','K'}}, 0, 0xc52083bcu},
        {{{'Y','R','9','K'}}, 0, 0x445983c3u},
    };
    for (const auto& identity : qualified)
        if (selected.identity.code == identity.code &&
            selected.identity.revision == identity.revision &&
            selected.identity.header_crc32 == identity.header_crc32) return true;
    return false;
}

// FFTA2's existing raster specialization is independent of the Castlevania
// replay/VRAM and query policies. Match each owned retail revision/header;
// unknown identities retain the established renderer path.
inline bool ffta2_raster_only_profile(const GameQuerySelection& selected)
{
    if (!selected.identified) return false;
    static constexpr GameQueryIdentity identities[] = {
        {{{'A','6','F','E'}}, 0, 0x8c766dbbu},
        {{{'A','6','F','P'}}, 0, 0x7a72b5f0u},
        {{{'A','6','F','J'}}, 0, 0xc724dea9u},
    };
    for (const auto& identity : identities)
        if (selected.identity.code == identity.code &&
            selected.identity.revision == identity.revision &&
            selected.identity.header_crc32 == identity.header_crc32) return true;
    return false;
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

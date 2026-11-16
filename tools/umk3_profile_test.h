// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "replay/GameQueryProfile.h"

// Independent expected identities from the retail ROM header audit. Exercise
// every retained policy so a later addition cannot accidentally stay USA-only.
inline void verify_umk3_regions(bool (*profile)(const nds4mister::replay::GameQuerySelection&))
{
    using namespace nds4mister::replay;
    const GameQuerySelection retail[] = {
        {GameQueryProfile::Fast, {{{'Y','U','T','E'}}, 0, 0x6c631035u}, true},
        {GameQueryProfile::Fast, {{{'Y','U','T','P'}}, 0, 0x1b8dde13u}, true},
    };
    for (const auto& good : retail) {
        require(profile(good), "retail UMK region rejected");
        require(select_game_query_profile(good.identity) == GameQueryProfile::Fast,
                "UMK render profile changed query policy");
        auto bad = good;
        bad.identified = false;
        require(!profile(bad), "unidentified UMK admitted");
        for (unsigned revision = 1; revision < 256; ++revision) {
            bad = good; bad.identity.revision = revision;
            require(!profile(bad), "uncatalogued UMK revision admitted");
        }
        for (unsigned byte = 0; byte < 4; ++byte)
            for (unsigned value = 0; value < 256; ++value) {
                if (value == good.identity.code[byte]) continue;
                bad = good; bad.identity.code[byte] = value;
                require(!profile(bad), "wrong game code/header pair admitted");
            }
        for (unsigned bit = 0; bit < 32; ++bit) {
            bad = good; bad.identity.header_crc32 ^= std::uint32_t(1) << bit;
            require(!profile(bad), "altered UMK header admitted");
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
#include "replay/GameQueryProfile.h"
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>

using namespace nds4mister::replay;
static void check(bool ok, const char* message)
{
    if (!ok) { std::cerr << message << '\n'; std::exit(1); }
}

static GameQueryHeader load_header(const char* path)
{
    GameQueryHeader header {};
    std::ifstream input(path, std::ios::binary);
    input.read(reinterpret_cast<char*>(header.data()), header.size());
    check(input.gcount() == static_cast<std::streamsize>(header.size()), "short fixture");
    return header;
}

int main(int argc, char** argv)
{
    const std::uint8_t crc_example[] = {'1','2','3','4','5','6','7','8','9'};
    check(game_query_crc32(crc_example, sizeof(crc_example)) == 0xcbf43926u, "CRC32 vector");
    const GameQueryIdentity known {{{'A','C','V','E'}}, 0, 0xc51a7d99u};
    const GameQueryIdentity portrait {{{'A','C','B','E'}}, 0, 0xa9935ea4u};
    check(portrait_sprite_raster_profile({GameQueryProfile::Fast, portrait, true}),
          "Portrait exact raster identity");
    check(select_game_query_profile(portrait) == GameQueryProfile::Fast &&
          !castlevania_integral_texture_profile({GameQueryProfile::Fast, portrait, true}),
          "Portrait must not inherit Dawn query or runtime policy");
    check(!portrait_sprite_raster_profile({GameQueryProfile::Fast, portrait, false}) &&
          !portrait_sprite_raster_profile({GameQueryProfile::Fast, known, true}),
          "unidentified and other cartridges keep their existing raster policy");
    for (unsigned bit = 0; bit < 32; ++bit) {
        auto changed = portrait; changed.header_crc32 ^= 1u << bit;
        check(!portrait_sprite_raster_profile({GameQueryProfile::Fast, changed, true}),
              "changed Portrait header must use fallback");
    }
    for (unsigned byte = 0; byte < 4; ++byte) {
        auto changed = portrait; changed.code[byte] ^= 1;
        check(!portrait_sprite_raster_profile({GameQueryProfile::Fast, changed, true}),
              "changed Portrait code must use fallback");
    }
    auto revised_portrait = portrait; ++revised_portrait.revision;
    check(!portrait_sprite_raster_profile({GameQueryProfile::Fast, revised_portrait, true}),
          "untested Portrait revision must use fallback");
    check(game_query_prefix_mode(select_game_query_profile(known)) == 0, "known identity");
    check(castlevania_integral_texture_profile({GameQueryProfile::Fast, known, true}),
          "Castlevania raster choice is independent of query mode");
    check(!castlevania_integral_texture_profile({GameQueryProfile::CastlevaniaDosUsRevision0, known, false}),
          "unidentified raster choice defaults off");
    for (unsigned i = 0; i < 4; ++i) {
        auto other = known; other.code[i] ^= 1;
        check(select_game_query_profile(other) == GameQueryProfile::Fast, "code mismatch");
        check(!castlevania_integral_texture_profile({GameQueryProfile::CastlevaniaDosUsRevision0, other, true}),
              "code mismatch must not inherit Castlevania raster choice");
    }
    auto other = known; ++other.revision;
    check(select_game_query_profile(other) == GameQueryProfile::Fast, "revision mismatch");
    check(!castlevania_integral_texture_profile({GameQueryProfile::Fast, other, true}), "raster revision mismatch");
    other = known; other.header_crc32 ^= 1;
    check(select_game_query_profile(other) == GameQueryProfile::Fast, "header mismatch");
    check(!castlevania_integral_texture_profile({GameQueryProfile::Fast, other, true}), "raster header mismatch");
    check(read_game_query_profile([](GameQueryHeader&) { return false; }).profile ==
          GameQueryProfile::Fast, "read failure default");
    unsigned calls = 0;
    auto raced = read_game_query_profile([&](GameQueryHeader& h) { h[0] = ++calls; return true; });
    check(!raced.identified && raced.profile == GameQueryProfile::Fast, "changing header default");
    check(!castlevania_integral_texture_profile(raced), "changing header disables raster shortcut");
    calls = 0;
    auto short_second = read_game_query_profile([&](GameQueryHeader&) { return ++calls == 1; });
    check(!short_second.identified && short_second.profile == GameQueryProfile::Fast, "second read failure");
    check(!castlevania_integral_texture_profile(short_second), "failed second read disables raster shortcut");
    check(!automatic_movie_receiver_profile(raced) &&
          !automatic_movie_receiver_profile(short_second), "unstable identity disables movie receiver");
    check(!automatic_movie_receiver_profile({GameQueryProfile::Fast, known, true}),
          "Castlevania guest-only optimization does not enable movie receiver");
    const GameQueryIdentity movies[] = {
        {{{'B','2','K','J'}}, 0, 0x56588d29u},
        {{{'B','2','K','J'}}, 0, 0xf2d6c66fu},
        {{{'Y','Q','U','E'}}, 0, 0x93bba687u},
        {{{'B','M','T','E'}}, 0, 0xae6c8af6u},
        {{{'A','X','F','E'}}, 0, 0x4fa8f939u},
        {{{'Y','W','S','E'}}, 0, 0x28886fdau},
        {{{'Y','Q','U','P'}}, 0, 0x61413913u},
        {{{'Y','Q','U','J'}}, 0, 0x8e64c114u},
        {{{'A','X','F','P'}}, 0, 0xeaf70a5fu},
        {{{'A','X','F','J'}}, 0, 0x743ad9b4u},
        {{{'C','S','N','P'}}, 0, 0x00d6c211u},
        {{{'C','5','R','J'}}, 0, 0xabea3452u},
        {{{'B','M','T','J'}}, 0, 0xef046fccu},
    };
    for (const auto& movie : movies) {
        check(automatic_movie_receiver_profile({GameQueryProfile::Fast, movie, true}),
              "qualified virtual header enables receiver");
        check(!automatic_movie_receiver_profile({GameQueryProfile::Fast, movie, false}),
              "missing header does not inherit movie receiver");
        auto changed = movie; ++changed.revision;
        check(!automatic_movie_receiver_profile({GameQueryProfile::Fast, changed, true}),
              "other revision disables movie receiver");
        changed = movie; changed.header_crc32 ^= 1;
        check(!automatic_movie_receiver_profile({GameQueryProfile::Fast, changed, true}),
              "other header disables movie receiver");
        for (unsigned byte = 0; byte < 4; ++byte) {
            changed = movie; changed.code[byte] ^= 1;
            check(!automatic_movie_receiver_profile({GameQueryProfile::Fast, changed, true}),
                  "other game disables movie receiver");
        }
    }
    std::cout << "MOVIE_RECEIVER_PROFILE_PASS qualified_headers=13 unknown_off=1 reset_default_off=1\n";

    // Optional private fixtures stay outside the source tree and release.
    if (argc == 3) {
        const auto cast = load_header(argv[1]);
        const auto nsmb = load_header(argv[2]);
        const GameQueryHeader unknown {};
        for (const auto* header : {&cast, &nsmb, &unknown, &cast, &cast, &nsmb}) {
            auto selected = read_game_query_profile([&](GameQueryHeader& out) { out = *header; return true; });
            check(selected.identified, "stable header read");
            check(game_query_prefix_mode(selected.profile) == (header == &cast ? 0u : 2u), "reload/reset choice");
            check(castlevania_integral_texture_profile(selected) == (header == &cast), "reload/reset raster choice");
        }
        for (std::size_t byte = 0; byte < cast.size(); ++byte) {
            auto changed = cast; changed[byte] ^= 1;
            check(select_game_query_profile(game_query_identity(changed)) == GameQueryProfile::Fast,
                  "modified header must default fast");
        }
        calls = 0;
        auto switched = read_game_query_profile([&](GameQueryHeader& out) { out = ++calls == 1 ? cast : nsmb; return true; });
        check(!switched.identified && switched.profile == GameQueryProfile::Fast, "ROM changed during identification");
        std::cout << "GAME_QUERY_PROFILE_FIXTURES_PASS reload_reset_sequence=6 changed_bytes=352 cast=ordered nsmb=fast\n";
    } else check(argc == 1, "usage: test [castlevania-header nsmb-header]");
    std::cout << "GAME_QUERY_PROFILE_PASS exact_identity=1 unknown_fast=1 read_fail_fast=1 torn_fast=1\n";
}

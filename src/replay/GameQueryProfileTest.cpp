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
    const GameQueryIdentity kart {{{'A','M','C','E'}}, 0, 0x388c990cu};
    check(mkds_approximate_factors_profile({GameQueryProfile::Fast,kart,true}), "tested Kart factors on");
    check(!mkds_approximate_factors_profile({GameQueryProfile::Fast,kart,false}), "unidentified Kart factors off");
    check(!mkds_approximate_factors_profile({GameQueryProfile::Fast,known,true}), "Dawn factors off");
    for(unsigned bit=0;bit<32;++bit) {
        auto changed=kart;changed.header_crc32^=1u<<bit;
        check(!mkds_approximate_factors_profile({GameQueryProfile::Fast,changed,true}), "changed Kart CRC off");
    }
    for(unsigned byte=0;byte<4;++byte)for(unsigned value=0;value<256;++value) {
        if(value==kart.code[byte])continue;
        auto changed=kart;changed.code[byte]=value;
        check(!mkds_approximate_factors_profile({GameQueryProfile::Fast,changed,true}), "changed Kart code off");
    }
    for(unsigned revision=1;revision<256;++revision) {
        auto changed=kart;changed.revision=revision;
        check(!mkds_approximate_factors_profile({GameQueryProfile::Fast,changed,true}), "unqualified Kart revision off");
    }
    std::cout << "MKDS_APPROX_PROFILE_PASS retail_profiles=1 mutations=1307 unidentified_off=1 other_games_off=1\n";
    const GameQueryIdentity resident_evil {{{'A','B','H','E'}}, 0, 0xc7e5cdf1u};
    check(resident_evil_paired_a_profile({GameQueryProfile::Fast,resident_evil,true}), "Resident Evil paired A on");
    check(!resident_evil_paired_a_profile({GameQueryProfile::Fast,resident_evil,false}), "unidentified Resident Evil off");
    check(!resident_evil_paired_a_profile({GameQueryProfile::Fast,known,true}) &&
          !resident_evil_paired_a_profile({GameQueryProfile::Fast,kart,true}), "other game paired A off");
    for(unsigned bit=0;bit<32;++bit) {
        auto changed=resident_evil;changed.header_crc32^=1u<<bit;
        check(!resident_evil_paired_a_profile({GameQueryProfile::Fast,changed,true}), "changed Resident Evil CRC off");
    }
    for(unsigned byte=0;byte<4;++byte)for(unsigned value=0;value<256;++value) {
        if(value==resident_evil.code[byte])continue;
        auto changed=resident_evil;changed.code[byte]=value;
        check(!resident_evil_paired_a_profile({GameQueryProfile::Fast,changed,true}), "changed Resident Evil code off");
    }
    for(unsigned revision=1;revision<256;++revision) {
        auto changed=resident_evil;changed.revision=revision;
        check(!resident_evil_paired_a_profile({GameQueryProfile::Fast,changed,true}), "unqualified Resident Evil revision off");
    }
    for(bool qualified : {false,true}) {
        check(paired_a_cache_enabled(qualified,nullptr)==qualified &&
              paired_a_cache_enabled(qualified,"auto")==qualified &&
              paired_a_cache_enabled(qualified,"invalid")==qualified &&
              paired_a_cache_enabled(qualified,"")==qualified, "paired A default selection");
        check(!paired_a_cache_enabled(qualified,"0") && paired_a_cache_enabled(qualified,"1"), "paired A explicit overrides");
    }
    std::cout << "RE_PAIRED_A_PROFILE_PASS retail_profiles=1 mutations=1307 unidentified_off=1 other_games_off=1 overrides=1\n";
    const GameQueryIdentity lighting_regions[] = {
        known,
        {{{'A','C','V','P'}}, 0, 0x6396d24cu},
        {{{'A','C','V','J'}}, 1, 0x65777634u},
    };
    for(const auto& id:lighting_regions) {
        check(dawn_lighting_result_reuse_profile({GameQueryProfile::Fast,id,true}), "Dawn lighting exact retail identity on");
        check(!dawn_lighting_result_reuse_profile({GameQueryProfile::CastlevaniaDosUsRevision0,id,false}), "Dawn lighting unidentified off");
        for(unsigned bit=0;bit<32;++bit) {
            auto changed=id;changed.header_crc32^=1u<<bit;
            check(!dawn_lighting_result_reuse_profile({GameQueryProfile::CastlevaniaDosUsRevision0,changed,true}), "Dawn lighting changed CRC off");
        }
        for(unsigned byte=0;byte<4;++byte)for(unsigned value=0;value<256;++value) {
            if(value==id.code[byte])continue;
            auto changed=id;changed.code[byte]=value;
            check(!dawn_lighting_result_reuse_profile({GameQueryProfile::CastlevaniaDosUsRevision0,changed,true}), "Dawn lighting changed code off");
        }
        for(unsigned rev=0;rev<256;++rev) {
            if(rev==id.revision)continue;
            auto changed=id;changed.revision=rev;
            check(!dawn_lighting_result_reuse_profile({GameQueryProfile::CastlevaniaDosUsRevision0,changed,true}), "Dawn lighting changed revision off");
        }
    }
    check(!dawn_lighting_result_reuse_profile({GameQueryProfile::Fast,{{{'A','5','9','E'}},0,0xa228cd45u},true}), "Dawn kiosk demo excluded");
    std::cout << "DAWN_LIGHTING_REUSE_PROFILE_PASS retail_profiles=3 mutations=3921 unidentified_off=1 demo_off=1\n";
    for(const auto& id:lighting_regions) {
        check(dawn_opaque_3d_seed_profile({GameQueryProfile::Fast,id,true}), "Dawn opaque seed exact retail identity on");
        check(!dawn_opaque_3d_seed_profile({GameQueryProfile::CastlevaniaDosUsRevision0,id,false}), "Dawn opaque seed unidentified off");
        for(unsigned bit=0;bit<32;++bit) {
            auto changed=id;changed.header_crc32^=1u<<bit;
            check(!dawn_opaque_3d_seed_profile({GameQueryProfile::CastlevaniaDosUsRevision0,changed,true}), "Dawn opaque seed changed CRC off");
        }
        for(unsigned byte=0;byte<4;++byte)for(unsigned value=0;value<256;++value) {
            if(value==id.code[byte])continue;
            auto changed=id;changed.code[byte]=value;
            check(!dawn_opaque_3d_seed_profile({GameQueryProfile::CastlevaniaDosUsRevision0,changed,true}), "Dawn opaque seed changed code off");
        }
        for(unsigned rev=0;rev<256;++rev) {
            if(rev==id.revision)continue;
            auto changed=id;changed.revision=rev;
            check(!dawn_opaque_3d_seed_profile({GameQueryProfile::CastlevaniaDosUsRevision0,changed,true}), "Dawn opaque seed changed revision off");
        }
    }
    check(!dawn_opaque_3d_seed_profile({GameQueryProfile::Fast,{{{'A','5','9','E'}},0,0xa228cd45u},true}), "Dawn kiosk demo excluded");
    std::cout << "DAWN_OPAQUE_SEED_PROFILE_PASS retail_profiles=3 mutations=3921 unidentified_off=1 demo_off=1\n";
    const GameQueryIdentity portrait {{{'A','C','B','E'}}, 0, 0xa9935ea4u};
    const GameQueryIdentity dawn_regions[] = {
        {{{'A','C','V','P'}}, 0, 0x6396d24cu},
        {{{'A','C','V','J'}}, 1, 0x65777634u},
    };
    for (const auto& identity : dawn_regions) {
        const GameQuerySelection selected {select_game_query_profile(identity), identity, true};
        check(dawn_regional_raster_only_profile(selected), "regional Dawn raster enabled");
        check(game_query_prefix_mode(selected.profile) == 2 &&
              !castlevania_integral_texture_profile(selected) &&
              !portrait_sprite_raster_profile(selected) &&
              !ecclesia_sprite_raster_profile(selected) &&
              !ffta2_raster_only_profile(selected) &&
              !automatic_movie_receiver_profile(selected),
              "regional Dawn must retain independent query, replay and movie policies");
        check(!dawn_regional_raster_only_profile({selected.profile, identity, false}),
              "Dawn raster requires identified header");
        for (unsigned bit = 0; bit < 32; ++bit) {
            auto changed = identity; changed.header_crc32 ^= 1u << bit;
            check(!dawn_regional_raster_only_profile({selected.profile, changed, true}),
                  "modified Dawn fingerprint falls back");
        }
        for (unsigned byte = 0; byte < 4; ++byte)
            for (unsigned value = 0; value < 256; ++value) {
                if (value == identity.code[byte]) continue;
                auto changed = identity; changed.code[byte] = value;
                check(!dawn_regional_raster_only_profile({selected.profile, changed, true}),
                      "wrong Dawn code/fingerprint falls back");
            }
        for (unsigned revision = 0; revision < 256; ++revision) {
            if (revision == identity.revision) continue;
            auto changed = identity; changed.revision = revision;
            check(!dawn_regional_raster_only_profile({selected.profile, changed, true}),
                  "unknown Dawn revision falls back");
        }
    }
    const GameQueryIdentity demo {{{'A','5','9','E'}}, 0, 0xa228cd45u};
    for (const auto& identity : {known, portrait, demo})
        check(!dawn_regional_raster_only_profile({GameQueryProfile::Fast, identity, true}),
              "USA Dawn, unrelated games and kiosk demo retain existing policy");
    std::cout << "DAWN_REGIONAL_RASTER_PROFILE_PASS regions=2 mutations=2614 other_policies_unchanged=1\n";
    const GameQueryIdentity ffta2_regions[] = {
        {{{'A','6','F','E'}}, 0, 0x8c766dbbu},
        {{{'A','6','F','P'}}, 0, 0x7a72b5f0u},
        {{{'A','6','F','J'}}, 0, 0xc724dea9u},
    };
    for (const auto& ffta2 : ffta2_regions) {
        check(ffta2_raster_only_profile({GameQueryProfile::Fast, ffta2, true}),
              "exact FFTA2 retail identity enables its raster choice");
        check(game_query_prefix_mode(select_game_query_profile(ffta2)) == 2 &&
              !castlevania_integral_texture_profile({GameQueryProfile::Fast, ffta2, true}) &&
              !portrait_sprite_raster_profile({GameQueryProfile::Fast, ffta2, true}) &&
              !ecclesia_sprite_raster_profile({GameQueryProfile::Fast, ffta2, true}) &&
              !automatic_movie_receiver_profile({GameQueryProfile::Fast, ffta2, true}),
              "FFTA2 retains fast queries and independent service/movie policies");
        check(!ffta2_raster_only_profile({GameQueryProfile::Fast, ffta2, false}),
              "unidentified FFTA2 header retains existing raster choice");
        for (unsigned bit = 0; bit < 32; ++bit) {
            auto changed = ffta2; changed.header_crc32 ^= 1u << bit;
            check(!ffta2_raster_only_profile({GameQueryProfile::Fast, changed, true}),
                  "changed FFTA2 header falls back");
        }
        for (unsigned byte = 0; byte < 4; ++byte) {
            for (unsigned value = 0; value < 256; ++value) {
                if (value == ffta2.code[byte]) continue;
                auto changed = ffta2; changed.code[byte] = value;
                check(!ffta2_raster_only_profile({GameQueryProfile::Fast, changed, true}),
                      "wrong code/header combination falls back");
            }
        }
        for (unsigned revision = 1; revision < 256; ++revision) {
            auto changed = ffta2; changed.revision = revision;
            check(!ffta2_raster_only_profile({GameQueryProfile::Fast, changed, true}),
                  "unknown FFTA2 revision falls back");
        }
    }
    check(!ffta2_raster_only_profile({GameQueryProfile::Fast, known, true}) &&
          !ffta2_raster_only_profile({GameQueryProfile::Fast, portrait, true}),
          "other games retain their raster choices");
    std::cout << "FFTA2_RASTER_ONLY_PROFILE_PASS regions=3 unknown_off=1 query_fast=1\n";
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
    const GameQueryIdentity ecclesia[] = {
        {{{'Y','R','9','E'}}, 0, 0x89d2e308u}, {{{'Y','R','9','E'}}, 0, 0x483c0674u},
        {{{'Y','R','9','P'}}, 0, 0x937e153fu}, {{{'Y','R','9','P'}}, 0, 0xa1ec237au},
        {{{'Y','R','9','J'}}, 0, 0x6e9bc11du}, {{{'Y','R','9','J'}}, 0, 0x2858119fu},
        {{{'Y','R','9','K'}}, 0, 0xc52083bcu}, {{{'Y','R','9','K'}}, 0, 0x445983c3u},
    };
    for (unsigned i = 0; i < 8; ++i) {
        const auto& identity = ecclesia[i];
        check(ecclesia_sprite_raster_profile({GameQueryProfile::Fast, identity, true}),
              "every qualified Ecclesia retail/prepared image enables gameplay policy");
        check(automatic_movie_receiver_profile({GameQueryProfile::Fast, identity, true}) == bool(i & 1),
              "only prepared Ecclesia images enable the movie receiver");
        check(!ecclesia_sprite_raster_profile({GameQueryProfile::Fast, identity, false}) &&
              !automatic_movie_receiver_profile({GameQueryProfile::Fast, identity, false}),
              "Ecclesia requires a stable identified header");
        check(game_query_prefix_mode(select_game_query_profile(identity)) == 2 &&
              !portrait_sprite_raster_profile({GameQueryProfile::Fast, identity, true}),
              "Ecclesia retains its independent query policy");
        for (unsigned bit = 0; bit < 32; ++bit) {
            auto changed = identity; changed.header_crc32 ^= 1u << bit;
            check(!ecclesia_sprite_raster_profile({GameQueryProfile::Fast, changed, true}) &&
                  !automatic_movie_receiver_profile({GameQueryProfile::Fast, changed, true}),
                  "changed Ecclesia header must use fallback");
        }
        for (unsigned byte = 0; byte < 4; ++byte) {
            auto changed = identity; changed.code[byte] ^= 1;
            check(!ecclesia_sprite_raster_profile({GameQueryProfile::Fast, changed, true}) &&
                  !automatic_movie_receiver_profile({GameQueryProfile::Fast, changed, true}),
                  "changed Ecclesia code must use fallback");
        }
        for (unsigned revision = 1; revision < 256; ++revision) {
            auto changed = identity; changed.revision = revision;
            check(!ecclesia_sprite_raster_profile({GameQueryProfile::Fast, changed, true}) &&
                  !automatic_movie_receiver_profile({GameQueryProfile::Fast, changed, true}),
                  "untested Ecclesia revision must use fallback");
        }
    }
    check(!ecclesia_sprite_raster_profile({GameQueryProfile::Fast, portrait, true}),
          "other games must not inherit Ecclesia gameplay policy");
    std::cout << "ECCLESIA_REGIONS_PASS regions=4 retail_and_prepared_headers=8 unknown_off=1\n";
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
    check(!ffta2_raster_only_profile(raced), "changing header disables FFTA2 raster choice");
    check(!dawn_regional_raster_only_profile(raced), "changing header disables Dawn regional raster");
    check(!mkds_approximate_factors_profile(raced), "changing header disables approximate factors");
    calls = 0;
    auto short_second = read_game_query_profile([&](GameQueryHeader&) { return ++calls == 1; });
    check(!short_second.identified && short_second.profile == GameQueryProfile::Fast, "second read failure");
    check(!castlevania_integral_texture_profile(short_second), "failed second read disables raster shortcut");
    check(!ffta2_raster_only_profile(short_second), "failed second read disables FFTA2 raster choice");
    check(!dawn_regional_raster_only_profile(short_second), "failed second read disables Dawn regional raster");
    check(!mkds_approximate_factors_profile(short_second), "failed second read disables approximate factors");
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
        {{{'A','C','B','E'}}, 0, 0x2b8de1e5u},
        {{{'A','C','B','P'}}, 0, 0x6a6a7703u},
        {{{'A','C','B','J'}}, 0, 0xc16c5c05u},
        {{{'A','C','B','J'}}, 1, 0x903e2dbeu},
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
    check(portrait_sprite_raster_profile({GameQueryProfile::Fast, movies[13], true}),
          "prepared Portrait USA retains its qualified gameplay policy");
    for (unsigned i = 14; i < 17; ++i)
        check(!portrait_sprite_raster_profile({GameQueryProfile::Fast, movies[i], true}),
              "regional movie support does not broaden gameplay policy");
    std::cout << "MOVIE_RECEIVER_PROFILE_PASS qualified_headers=17 unknown_off=1 reset_default_off=1\n";

    // Optional private fixtures stay outside the source tree and release.
    if (argc == 3 || argc == 5 || argc == 6) {
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
        if (argc >= 5) {
            const auto europe = load_header(argv[3]), japan = load_header(argv[4]);
            for (const auto* header : {&europe, &japan, &cast, &nsmb, &europe, &unknown, &japan}) {
                const auto selected = read_game_query_profile([&](GameQueryHeader& out) { out = *header; return true; });
                check(dawn_lighting_result_reuse_profile(selected) == (header == &cast || header == &europe || header == &japan),
                      "real Dawn lighting selection across reloads");
                check(dawn_opaque_3d_seed_profile(selected) == (header == &cast || header == &europe || header == &japan),
                      "real Dawn opaque seed selection across reloads");
                check(dawn_regional_raster_only_profile(selected) == (header == &europe || header == &japan),
                      "real Dawn headers select regional raster across reloads");
                check(game_query_prefix_mode(selected.profile) == (header == &cast ? 0u : 2u),
                      "regional raster must not change real-header query policy");
            }
            for (const auto* header : {&europe, &japan})
                for (std::size_t byte = 0; byte < header->size(); ++byte) {
                    auto changed = *header; changed[byte] ^= 1;
                    const auto selected = read_game_query_profile([&](GameQueryHeader& out) { out = changed; return true; });
                    check(!dawn_regional_raster_only_profile(selected), "changed real Dawn header falls back");
                    check(!dawn_lighting_result_reuse_profile(selected), "changed Dawn header lighting falls back");
                }
            calls = 0;
            auto changed = read_game_query_profile([&](GameQueryHeader& out) { out = ++calls == 1 ? europe : japan; return true; });
            check(!changed.identified && !dawn_regional_raster_only_profile(changed) && !dawn_lighting_result_reuse_profile(changed),
                  "regional ROM switch during identification falls back");
            std::cout << "DAWN_REGIONAL_HEADER_FIXTURES_PASS reloads=7 changed_bytes=704 torn_read=1\n";
        }
        if (argc == 6) {
            const auto mkds=load_header(argv[5]);
            for(const auto* header : {&mkds,&nsmb,&cast,&unknown,&mkds,&nsmb}) {
                const auto selected=read_game_query_profile([&](GameQueryHeader& out){out=*header;return true;});
                check(mkds_approximate_factors_profile(selected)==(header==&mkds), "real Kart header reload/reset choice");
            }
            for(std::size_t byte=0;byte<mkds.size();++byte) {
                auto changed=mkds;changed[byte]^=1;
                const auto selected=read_game_query_profile([&](GameQueryHeader& out){out=changed;return true;});
                check(!mkds_approximate_factors_profile(selected), "changed real Kart header falls back");
            }
            calls=0;
            const auto torn=read_game_query_profile([&](GameQueryHeader& out){out=++calls==1?mkds:nsmb;return true;});
            check(!mkds_approximate_factors_profile(torn), "torn Kart header falls back");
            std::cout << "MKDS_APPROX_HEADER_FIXTURES_PASS reloads=6 changed_bytes=352 torn_read=1\n";
        }
    } else check(argc == 1, "usage: test [castlevania-header nsmb-header [dawn-europe-header dawn-japan-header [mkds-header]]]");
    std::cout << "GAME_QUERY_PROFILE_PASS exact_identity=1 unknown_fast=1 read_fail_fast=1 torn_fast=1\n";
}

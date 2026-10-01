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
    check(game_query_prefix_mode(select_game_query_profile(known)) == 0, "known identity");
    for (unsigned i = 0; i < 4; ++i) {
        auto other = known; other.code[i] ^= 1;
        check(select_game_query_profile(other) == GameQueryProfile::Fast, "code mismatch");
    }
    auto other = known; ++other.revision;
    check(select_game_query_profile(other) == GameQueryProfile::Fast, "revision mismatch");
    other = known; other.header_crc32 ^= 1;
    check(select_game_query_profile(other) == GameQueryProfile::Fast, "header mismatch");
    check(read_game_query_profile([](GameQueryHeader&) { return false; }).profile ==
          GameQueryProfile::Fast, "read failure default");
    unsigned calls = 0;
    auto raced = read_game_query_profile([&](GameQueryHeader& h) { h[0] = ++calls; return true; });
    check(!raced.identified && raced.profile == GameQueryProfile::Fast, "changing header default");
    calls = 0;
    auto short_second = read_game_query_profile([&](GameQueryHeader&) { return ++calls == 1; });
    check(!short_second.identified && short_second.profile == GameQueryProfile::Fast, "second read failure");

    // Optional private fixtures stay outside the source tree and release.
    if (argc == 3) {
        const auto cast = load_header(argv[1]);
        const auto nsmb = load_header(argv[2]);
        const GameQueryHeader unknown {};
        for (const auto* header : {&cast, &nsmb, &unknown, &cast, &cast, &nsmb}) {
            auto selected = read_game_query_profile([&](GameQueryHeader& out) { out = *header; return true; });
            check(selected.identified, "stable header read");
            check(game_query_prefix_mode(selected.profile) == (header == &cast ? 0u : 2u), "reload/reset choice");
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

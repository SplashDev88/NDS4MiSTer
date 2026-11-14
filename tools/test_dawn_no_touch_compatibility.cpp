// SPDX-License-Identifier: GPL-3.0-or-later
#include <algorithm>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <vector>
#include "replay/GameQueryProfile.h"
#include "standalone_host/fmv_castlevania.h"

using namespace nds4mister::replay;
static void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
static std::vector<uint8_t> read(const char* name) {
    std::ifstream file(name, std::ios::binary);
    require(bool(file), "ROM fixture cannot be read");
    std::vector<uint8_t> bytes{std::istreambuf_iterator<char>(file), {}};
    require(bytes.size() == 67108864, "expected untrimmed 64 MiB fixture");
    return bytes;
}
static GameQuerySelection selection(const std::vector<uint8_t>& bytes) {
    return read_game_query_profile([&](GameQueryHeader& header) {
        std::copy_n(bytes.begin(), header.size(), header.begin());
        return true;
    });
}
int main(int argc, char** argv) try {
    require(argc == 3, "usage: test retail.nds no-touch.nds (verify manifest SHA256 first)");
    const auto retail = read(argv[1]), hack = read(argv[2]);
    require(retail != hack, "hack must be a distinct fixture");
    require(std::equal(retail.begin(), retail.begin()+512, hack.begin()), "header differs");
    for (const auto* bytes : {&retail, &hack}) {
        const auto s = selection(*bytes);
        require(s.identified && s.identity.header_crc32 == 0xc51a7d99u, "Dawn identity");
        require(s.profile == GameQueryProfile::CastlevaniaDosUsRevision0 &&
                game_query_prefix_mode(s.profile) == 0, "ordered query policy");
        require(castlevania_integral_texture_profile(s), "integral raster/VRAM/sprite-reuse policy");
        require(dawn_lighting_result_reuse_profile(s), "lighting reuse policy");
        require(dawn_opaque_3d_seed_profile(s), "opaque 3D seed policy");
        require(!dawn_regional_raster_only_profile(s), "USA must retain its USA policy");
        require(!mkds_approximate_factors_profile(s) && !ffta2_raster_only_profile(s),
                "unrelated game shortcuts must stay off");
    }
    auto patchedRetail = retail, patchedHack = hack;
    require(nds_fmv::apply(patchedRetail.data(), patchedRetail.size(), patchedRetail.size()), "retail movie acceleration");
    require(nds_fmv::apply(patchedHack.data(), patchedHack.size(), patchedHack.size()), "No Touch movie acceleration");
    size_t hackBytes = 0, acceleratedBytes = 0;
    for (size_t i=0; i<hack.size(); ++i) {
        if (retail[i] != hack[i]) {
            ++hackBytes;
            require(patchedHack[i] == hack[i] && patchedRetail[i] == retail[i],
                    "movie patch changed hack behavior");
        } else {
            require(patchedHack[i] == patchedRetail[i], "acceleration differs outside hack");
            acceleratedBytes += patchedHack[i] != hack[i];
        }
    }
    require(hackBytes == 105 && acceleratedBytes > 0, "unexpected fixture differences");
    const auto alreadyPatched = patchedHack;
    require(!nds_fmv::apply(patchedHack.data(), patchedHack.size(), patchedHack.size()) &&
            patchedHack == alreadyPatched, "second patch must reject atomically");
    for (size_t offset : {size_t(0x100), nds_fmv::profiles[0].offsets[0],
                          nds_fmv::profiles[0].offsets[1], nds_fmv::profiles[0].offsets[2]}) {
        auto altered = hack; altered[offset] ^= 1;
        const auto before = altered;
        require(!nds_fmv::apply(altered.data(), altered.size(), altered.size()) &&
                altered == before, "unknown movie code/header must reject atomically");
    }
    auto changedHeader = hack; changedHeader[0x100] ^= 1;
    const auto unknown = selection(changedHeader);
    require(unknown.profile == GameQueryProfile::Fast &&
            !castlevania_integral_texture_profile(unknown) &&
            !dawn_lighting_result_reuse_profile(unknown) &&
            !dawn_opaque_3d_seed_profile(unknown), "unknown header must not inherit Dawn");
    std::cout << "DAWN_NO_TOUCH_COMPATIBILITY_PASS hack_bytes=" << hackBytes
              << " accelerated_bytes=" << acceleratedBytes
              << " dawn_policies=identical movie_patch=compatible hack_bytes_preserved=1\n";
} catch (const std::exception& e) {
    std::cerr << e.what() << '\n'; return 1;
}

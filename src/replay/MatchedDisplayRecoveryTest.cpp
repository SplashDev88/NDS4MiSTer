// SPDX-License-Identifier: GPL-3.0-or-later
#include "replay/MatchedDisplayAdmission.h"
#include "replay/GameQueryProfile.h"
#include <cstdlib>
#include <iostream>

static void check(bool ok, const char* message)
{
    if (!ok) { std::cerr << message << '\n'; std::exit(1); }
}
int main()
{
    using namespace nds4mister::replay;
    MatchedDisplayRecovery p;
    for (unsigned frame = 0; frame < 6000; ++frame)
        check(p.can_draw(true), "healthy operation capped");
    for (unsigned episode = 0; episode < 100; ++episode) {
        for (unsigned n = 0; n < 20; ++n)
            check(!p.can_draw(false), "unsafe backlog admitted");
        for (unsigned frame = 0; frame < 12; ++frame)
            check(p.can_draw(true) == !(frame & 1), "recovery cadence");
        for (unsigned frame = 0; frame < 100; ++frame)
            check(p.can_draw(true), "full rate did not recover");
    }
    p.can_draw(false); p.can_draw(true); p.reset();
    for (unsigned n = 0; n < 100; ++n)
        check(p.can_draw(true), "reset inherited skips");
    GameQuerySelection nsmb {GameQueryProfile::Fast, {{{'A','2','D','E'}}, 0, 0x01ebee25u}, true};
    check(nsmb_recovery_profile(nsmb), "tested NSMB not selected");
    auto other = nsmb; other.identified = false;
    check(!nsmb_recovery_profile(other), "failed identity selected");
    other = nsmb; ++other.identity.revision;
    check(!nsmb_recovery_profile(other), "unknown revision selected");
    other = nsmb; ++other.identity.header_crc32;
    check(!nsmb_recovery_profile(other), "unknown header selected");
    other = nsmb; other.identity.code[0] = 'B';
    check(!nsmb_recovery_profile(other), "other game selected");
    check(!nsmb_recovery_profile({}), "default selected");
    std::cout << "MATCHED_RECOVERY_PASS uncapped_healthy=6000 overload_episodes=100 recovery_frames=12 reset=1 exact_nsmb=1\n";
}

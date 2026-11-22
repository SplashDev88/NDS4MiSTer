// SPDX-License-Identifier: GPL-3.0-or-later
#include "GoldenSunHud.h"

using Hud = nds4mister::replay::GoldenSunHud;

static void transfer(Hud& hud, unsigned marker, unsigned seed, unsigned frame)
{
    hud.write(Hud::Marker, marker, frame);
    const unsigned page = marker == Hud::Full ? 0 : marker - Hud::Full - 1;
    const unsigned words = marker == Hud::Full ? Hud::Words : Hud::PageWords;
    for (unsigned i = 0; i < words; ++i)
        hud.write(Hud::Base + 4 * i, seed + page * Hud::PageWords + i, frame);
}

static bool matches(const Hud& hud, unsigned seed, unsigned frame)
{
    if (!hud.ready || hud.last_frame != frame) return false;
    for (unsigned i = 0; i < Hud::Words; ++i)
        if (hud.images[hud.active][i] != seed + i) return false;
    return true;
}

int main()
{
    Hud hud;
    // A late joiner must wait for a whole image or its first complete page cycle.
    for (unsigned page = 2; page < Hud::Pages; ++page)
        transfer(hud, Hud::Full + page + 1, 100, page);
    if (hud.ready) return 1;
    for (unsigned page = 0; page < Hud::Pages; ++page) {
        transfer(hud, Hud::Full + page + 1, 200, page);
        if (page + 1 < Hud::Pages && hud.ready) return 2;
    }
    if (!matches(hud, 200, 5)) return 3;

    // Missing pages or words must never expose a partially updated bitmap.
    transfer(hud, Hud::Full + 1, 300, 6);
    transfer(hud, Hud::Full + 3, 300, 7);
    hud.write(Hud::Marker, Hud::Full + 1, 8);
    hud.write(Hud::Base + 4, 0, 8);
    for (unsigned page = 1; page < Hud::Pages; ++page)
        transfer(hud, Hud::Full + page + 1, 300, 9 + page);
    if (!matches(hud, 200, 5)) return 4;

    // A changed image preempts any refresh. Legacy senders use the same marker.
    transfer(hud, Hud::Full + 1, 400, 16);
    transfer(hud, Hud::Full, 500, 17);
    if (!matches(hud, 500, 17)) return 5;
    for (unsigned page = 0; page < Hud::Pages; ++page) {
        transfer(hud, Hud::Full + page + 1, 600, 18 + page);
        if (page + 1 < Hud::Pages && !matches(hud, 500, 17)) return 6;
    }
    return matches(hud, 600, 23) ? 0 : 7;
}

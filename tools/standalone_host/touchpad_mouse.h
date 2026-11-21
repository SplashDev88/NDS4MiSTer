// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <array>
#include <cstdint>
#include <linux/input.h>
#include <utility>

namespace nds_touchpad {
// Linux's Sony driver supplies ABS_X/Y for the primary contact alongside MT
// slots. Use that pointer emulation once per report, never both coordinate
// streams. Only one-finger motion moves the mouse; no gestures or tap-to-click.
struct Mouse {
    bool enabled = false, dropped = false;
    bool touching = false, single = false, baseline = false;
    int x = 0, y = 0, previous_x = 0, previous_y = 0;
    int remainder_x = 0, remainder_y = 0;

    static bool supported(const input_id &id, unsigned long properties,
                          const std::array<input_absinfo, ABS_CNT> &axes) {
        return id.vendor == 0x054c &&
            (properties & (1ul << INPUT_PROP_POINTER)) &&
            (properties & (1ul << INPUT_PROP_BUTTONPAD)) &&
            !(properties & (1ul << INPUT_PROP_DIRECT)) &&
            axes[ABS_X].maximum > axes[ABS_X].minimum &&
            axes[ABS_Y].maximum > axes[ABS_Y].minimum &&
            axes[ABS_MT_POSITION_X].maximum > axes[ABS_MT_POSITION_X].minimum &&
            axes[ABS_MT_POSITION_Y].maximum > axes[ABS_MT_POSITION_Y].minimum;
    }
    void rebase() {
        baseline = false;
        remainder_x = remainder_y = 0;
    }
    void key(unsigned code, bool down) {
        if (code == BTN_TOUCH) {
            if (touching != down) rebase();
            touching = down;
        } else if (code == BTN_TOOL_FINGER) {
            if (single != down) rebase();
            single = down;
        }
    }
    void absolute(unsigned code, int value) {
        if (code == ABS_X) x = value;
        else if (code == ABS_Y) y = value;
        // Finger handover can keep BTN_TOUCH asserted. Do not turn the new
        // contact's position into a jump, including a second finger lifting.
        else if (code == ABS_MT_TRACKING_ID) rebase();
    }
    std::pair<int, int> report(bool gameplay) {
        if (!gameplay || !touching || !single) {
            rebase();
            return {0, 0};
        }
        int dx = 0, dy = 0;
        if (baseline) {
            // Six sensor units per DS mouse pixel. Retain fractions so slow
            // movement is not lost at the controller's high report rate.
            const auto total_x = int64_t(x) - previous_x + remainder_x;
            const auto total_y = int64_t(y) - previous_y + remainder_y;
            dx = int(total_x / 6); dy = int(total_y / 6);
            remainder_x = int(total_x % 6); remainder_y = int(total_y % 6);
        }
        previous_x = x; previous_y = y; baseline = true;
        return {dx, dy};
    }
};
}

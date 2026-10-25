# SPDX-License-Identifier: GPL-3.0-or-later
"""Negotiated work progress for the stock filename-and-bar loading dialog.

These are weighted completed-work units, not a time estimate. No timer advances
the bar. Completion remains the host's job, after validated cartridge release.
"""
import os
import struct


class LoadProgress:
    def __init__(self, emit):
        self.emit = emit
        self.enabled = os.environ.get('NDS_ROM_LOAD_PROGRESS') == '1'
        self.value = -1
        self.base = 0
        self.update(0, 0, 1, 1)

    def update(self, start, end, done=1, total=1):
        if not self.enabled:
            return
        if not (0 <= start <= end <= 9900 and 0 <= done <= total and total > 0):
            raise ValueError('invalid loading work range')
        value = start + (end-start)*done//total
        value = self.base + (9900-self.base)*value//9900
        # Recovery and fallback may redo completed work; never reverse the bar.
        value = max(self.value, value)
        if value != self.value:
            self.value = value
            self.emit(struct.pack('<Qii', value, 0, 13))

    def recovery(self):
        self.base = max(0, self.value)

# SPDX-License-Identifier: GPL-3.0-only
"""Per-game hook eligibility, independent of any patch or trap mechanism.

The caller supplies a live-memory reader for runtime hooks. A source-section
reader can authorize main-loaded shims only; it cannot assert ITCM autoload.
No state is cached across games/resets and no hook is installed by this module.
"""
import hashlib
import zlib


def select_profile(registry, header, arm9):
    if registry.get('version') != 1 or len(header) < 32:
        return None
    key = (bytes(header[12:16]), header[30], zlib.crc32(arm9))
    matches = [p for p in registry.get('profiles', [])
               if (p['game_code'].encode('ascii'), p['revision'],
                   int(p['arm9_crc32'], 16)) == key]
    return matches[0] if len(matches) == 1 else None


def verify_target(hook, read_memory, *, autoload_complete=False):
    address = int(hook['address']) & ~1  # Thumb entry tag is not an address bit.
    length = int(hook['guard_bytes'])
    if not 8 <= length <= 16:
        return False, 'invalid guard length'
    # All physical aliases of the ITCM in the DS low 32 MiB aperture must wait.
    # Initial boot code hooks in main RAM use main_loaded explicitly.
    if address < 0x02000000 and not autoload_complete:
        return False, 'ITCM autoload not verified'
    if hook.get('phase') not in ('main_loaded', 'autoload_complete'):
        return False, 'unknown hook phase'
    if hook['phase'] == 'autoload_complete' and not autoload_complete:
        return False, 'autoload not verified'
    try:
        data = read_memory(address, length)
    except (OSError, ValueError, IndexError):
        return False, 'target memory unavailable'
    if len(data) != length or hashlib.sha256(data).hexdigest() != hook['guard_sha256']:
        return False, 'target code differs'
    return True, 'verified'

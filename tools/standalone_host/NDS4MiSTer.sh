#!/bin/sh
# NDS4MiSTer v0.9.0-rc.3 standalone launcher. SPDX-License-Identifier: GPL-3.0-only
# This install stays separate from existing NDS cores, helpers and settings.
set -u
kit=/media/fat/Scripts/.NDS_Standalone
fail()
{
    printf '\nNDS4MiSTer: %s\n' "$1" >&2
    if [ -t 0 ]; then
        printf 'Press Enter to return to MiSTer.\n'
        read -r answer || :
    fi
    exit 1
}
command -v python3 >/dev/null 2>&1 || fail 'Python 3.8 or newer is required. No files or settings were changed.'
python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' || fail 'Python 3.8 or newer is required. No files or settings were changed.'
[ -f "$kit/supervisor.py" ] || fail 'Support files are missing. Extract the whole release ZIP to the SD card root, including hidden files.'
python3 "$kit/supervisor.py" || fail 'Launch failed. See the message above; session logs are in /tmp/nds-standalone.'

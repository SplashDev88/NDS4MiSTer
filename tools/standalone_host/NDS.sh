#!/bin/sh
# NDS4MiSTer; the installed version is shown in the core menu.
export NDS_GUEST_PATCH_MANIFEST=/media/fat/Scripts/.NDS/fmv/guest_catalog.json
export NDS_GUEST_PATCH_SHA256=e42565df6091f24f31d5ccaad858c345e297ad698166d260f2b562fc3710288d
export NDS_GUEST_PATCH_IDS=@catalog
export NDS_GUEST_PATCH_FALLBACK_FMV=1
exec python3 /media/fat/Scripts/.NDS/auto_movies.py "$@"

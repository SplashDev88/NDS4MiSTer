#!/bin/sh
# NDS4MiSTer; the installed version is shown in the core menu.
export NDS_GUEST_PATCH_MANIFEST=/media/fat/Scripts/.NDS/fmv/guest_catalog.json
export NDS_GUEST_PATCH_SHA256=9477c6913e689f75c52e93dd23101597373cae720380d30071d7db872631a088
export NDS_GUEST_PATCH_IDS=@catalog
export NDS_GUEST_PATCH_FALLBACK_FMV=1
exec python3 /media/fat/Scripts/.NDS/auto_movies.py "$@"

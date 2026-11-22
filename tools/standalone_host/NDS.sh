#!/bin/sh
# NDS4MiSTer; the installed version is shown in the core menu.
export NDS_GUEST_PATCH_MANIFEST=/media/fat/Scripts/.NDS/fmv/guest_catalog.json
export NDS_GUEST_PATCH_SHA256=6272282606b0c7c91521e94831ea9986bb4f80a38e9f01dbd7c4856c095db170
export NDS_GUEST_PATCH_IDS=@catalog
export NDS_GUEST_PATCH_FALLBACK_FMV=1
exec python3 /media/fat/Scripts/.NDS/auto_movies.py "$@"

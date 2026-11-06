#!/bin/sh
# NDS4MiSTer v0.9.0-rc.14 standalone launcher
export NDS_GUEST_PATCH_MANIFEST=/media/fat/Scripts/.NDS_Standalone/fmv/guest_catalog.json
export NDS_GUEST_PATCH_SHA256=43062a4782cbc16f55843f9e09babdf2fe00488f43c6f2308ff308210e117598
export NDS_GUEST_PATCH_IDS=@catalog
export NDS_GUEST_PATCH_FALLBACK_FMV=1
export NDS_GX_ASSET_CACHE=1
exec python3 /media/fat/Scripts/.NDS_Standalone/auto_movies.py "$@"

#!/bin/sh
# NDS4MiSTer v0.9.0-rc.13 standalone launcher
export NDS_GUEST_PATCH_MANIFEST=/media/fat/Scripts/.NDS_Standalone/fmv/guest_catalog.json
export NDS_GUEST_PATCH_SHA256=f25d282ac2af1f102865179041937fc50ee3f11c0c5970a9830a49383bd4cfd0
export NDS_GUEST_PATCH_IDS=@catalog
export NDS_GUEST_PATCH_FALLBACK_FMV=1
exec python3 /media/fat/Scripts/.NDS_Standalone/auto_movies.py "$@"

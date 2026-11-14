#!/bin/sh
# NDS4MiSTer RC15; graphics quality is selected in Display options.
export NDS_GUEST_PATCH_MANIFEST=/media/fat/Scripts/.NDS_RC15/fmv/guest_catalog.json
export NDS_GUEST_PATCH_SHA256=f25d282ac2af1f102865179041937fc50ee3f11c0c5970a9830a49383bd4cfd0
export NDS_GUEST_PATCH_IDS=@catalog
export NDS_GUEST_PATCH_FALLBACK_FMV=1
exec python3 /media/fat/Scripts/.NDS_RC15/auto_movies.py "$@"

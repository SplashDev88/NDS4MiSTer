#!/bin/sh
# NDS4MiSTer; the installed version is shown in the core menu.
export NDS_GUEST_PATCH_MANIFEST=/media/fat/Scripts/.NDS/fmv/guest_catalog.json
export NDS_GUEST_PATCH_SHA256=a1a147d1169a9ef67b72beae986c7053bdefdfa4b7498ced9c76dbf39cefefbe
export NDS_GUEST_PATCH_IDS=@catalog
export NDS_GUEST_PATCH_FALLBACK_FMV=1
exec python3 /media/fat/Scripts/.NDS/auto_movies.py "$@"

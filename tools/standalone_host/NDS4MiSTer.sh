#!/bin/sh
# NDS4MiSTer v0.9.0-rc.13
export NDS_GUEST_PATCH_MANIFEST=/media/fat/Scripts/.NDS_Standalone/fmv/guest_catalog.json
export NDS_GUEST_PATCH_SHA256=f92998bc27562fbe33c46ed27d50680f88ef1022e97b324dd6d411188883d1ee
export NDS_GUEST_PATCH_IDS=@catalog
export NDS_GUEST_PATCH_FALLBACK_FMV=1
exec python3 /media/fat/Scripts/.NDS_Standalone/auto_movies.py "$@"

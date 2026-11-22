#!/bin/sh
# NDS4MiSTer; the installed version is shown in the core menu.
export NDS_GUEST_PATCH_MANIFEST=/media/fat/Scripts/.NDS/fmv/guest_catalog.json
export NDS_GUEST_PATCH_SHA256=ed13ebc6fbe6d924e9168271b68d839df547776be5e0217fd59e7a18b2f2e814
export NDS_GUEST_PATCH_IDS=@catalog
export NDS_GUEST_PATCH_FALLBACK_FMV=1
exec python3 /media/fat/Scripts/.NDS/auto_movies.py "$@"

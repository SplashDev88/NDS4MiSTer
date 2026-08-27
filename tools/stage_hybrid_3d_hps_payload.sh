#!/usr/bin/env bash
# Build an offline /media/fat-shaped H3D service payload.  This never contacts
# or writes a MiSTer; the operator deploys the completed directory separately.
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
source_service=${1:-}
output_root=${2:-}
if [[ -z "$source_service" || -z "$output_root" || $# -ne 2 ]]; then
    echo "usage: $0 ARMHF_SERVICE NEW_OUTPUT_DIRECTORY" >&2
    exit 2
fi

if [[ -L "$source_service" || ! -f "$source_service" || \
      ! -x "$source_service" ]]; then
    echo "FAIL: service must be an executable, non-symlink regular file" >&2
    exit 1
fi
if ! file "$source_service" | grep -Eq \
    'ELF 32-bit LSB executable, ARM.*statically linked'; then
    echo "FAIL: service is not a static 32-bit ARM executable" >&2
    exit 1
fi
if [[ -e "$output_root" || -L "$output_root" ]]; then
    echo "FAIL: output directory already exists: $output_root" >&2
    exit 1
fi

output_parent=$(dirname "$output_root")
if [[ ! -d "$output_parent" ]]; then
    echo "FAIL: output parent does not exist: $output_parent" >&2
    exit 1
fi
temporary=$(mktemp -d "$output_parent/.h3d-hps-stage.XXXXXX")
cleanup() {
    rm -rf "$temporary"
}
trap cleanup EXIT INT TERM HUP

mkdir "$temporary/Scripts"
cp "$source_service" "$temporary/nds_hybrid_3d_service"
chmod 755 "$temporary/nds_hybrid_3d_service"
cp "$repo_dir/tools/nds_hybrid_3d_service_ctl.sh" \
    "$temporary/Scripts/NDS4MiSTer_H3D.sh"
chmod 755 "$temporary/Scripts/NDS4MiSTer_H3D.sh"

(
    cd "$temporary"
    service_sha=$(sha256sum nds_hybrid_3d_service)
    printf '%s\n' "$service_sha" >nds_hybrid_3d_service.sha256
    sha256sum \
        nds_hybrid_3d_service \
        nds_hybrid_3d_service.sha256 \
        Scripts/NDS4MiSTer_H3D.sh >SHA256SUMS
    sha256sum -c SHA256SUMS >/dev/null
)

mv "$temporary" "$output_root"
trap - EXIT INT TERM HUP
sha=$(sed -n '1s/ .*//p' \
    "$output_root/nds_hybrid_3d_service.sha256")
echo "H3D HPS payload staged: $output_root"
echo "service_sha256=$sha"

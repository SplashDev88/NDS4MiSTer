#!/usr/bin/env bash
# Build an offline /media/fat-shaped H3D service payload.  This never contacts
# or writes a MiSTer; the operator deploys the completed directory separately.
set -euo pipefail

repo_dir=$(cd "$(dirname "$0")/.." && pwd)
source_service=${1:-}
output_root=${2:-}
source_wc_module=${3:-}
if [[ -z "$source_service" || -z "$output_root" || $# -lt 2 || $# -gt 3 ]]; then
    echo "usage: $0 ARMHF_SERVICE NEW_OUTPUT_DIRECTORY [NDS_MEM_WC_KO]" >&2
    exit 2
fi
if [[ -n "$source_wc_module" ]]; then
    if [[ -L "$source_wc_module" || ! -f "$source_wc_module" ]]; then
        echo "FAIL: WC module must be a non-symlink regular file" >&2
        exit 1
    fi
    if ! file "$source_wc_module" | grep -Eq \
        'ELF 32-bit LSB relocatable, ARM'; then
        echo "FAIL: WC module is not a 32-bit ARM kernel module" >&2
        exit 1
    fi
    if ! strings "$source_wc_module" | grep -Fqx \
        'vermagic=5.15.1-MiSTer SMP mod_unload ARMv7 p2v8 '; then
        echo "FAIL: WC module vermagic does not match MiSTer 5.15.1" >&2
        exit 1
    fi
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

mkdir -p "$temporary/Scripts/NDS_Support"
cp "$source_service" \
    "$temporary/Scripts/NDS_Support/nds_hybrid_3d_service"
chmod 755 "$temporary/Scripts/NDS_Support/nds_hybrid_3d_service"
if [[ -n "$source_wc_module" ]]; then
    cp "$source_wc_module" "$temporary/Scripts/NDS_Support/nds_mem_wc.ko"
    chmod 644 "$temporary/Scripts/NDS_Support/nds_mem_wc.ko"
fi
cp "$repo_dir/tools/nds_hybrid_3d_service_ctl.sh" \
    "$temporary/Scripts/NDS_Kickstart.sh"
chmod 755 "$temporary/Scripts/NDS_Kickstart.sh"

(
    cd "$temporary/Scripts/NDS_Support"
    service_sha=$(sha256sum nds_hybrid_3d_service)
    printf '%s\n' "$service_sha" >nds_hybrid_3d_service.sha256
    if [[ -f nds_mem_wc.ko ]]; then
        module_sha=$(sha256sum nds_mem_wc.ko)
        printf '%s\n' "$module_sha" >nds_mem_wc.ko.sha256
    fi
)
(
    cd "$temporary"
    payload_files=(
        Scripts/NDS_Kickstart.sh
        Scripts/NDS_Support/nds_hybrid_3d_service
        Scripts/NDS_Support/nds_hybrid_3d_service.sha256
    )
    if [[ -f Scripts/NDS_Support/nds_mem_wc.ko ]]; then
        payload_files+=(
            Scripts/NDS_Support/nds_mem_wc.ko
            Scripts/NDS_Support/nds_mem_wc.ko.sha256
        )
    fi
    sha256sum "${payload_files[@]}" >SHA256SUMS
    sha256sum -c SHA256SUMS >/dev/null
)

mv "$temporary" "$output_root"
trap - EXIT INT TERM HUP
sha=$(sed -n '1s/ .*//p' \
    "$output_root/Scripts/NDS_Support/nds_hybrid_3d_service.sha256")
echo "H3D HPS payload staged: $output_root"
echo "service_sha256=$sha"

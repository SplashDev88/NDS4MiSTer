#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: $0 LOG_STEM [map|fit|asm|sta|fit-asm-sta|all]"
}

if (($# == 1)) && [[ $1 == -h || $1 == --help ]]; then
    usage
    exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage >&2
    exit 2
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
log_stem=$1
selection=${2:-all}
project_rel=${QUARTUS_PROJECT_DIR:-fpga/mister}
runtime_root=${QUARTUS_RUNTIME_ROOT:-$root/.tooling/quartus-17.0.2}
udev_compat=${QUARTUS_UDEV_COMPAT:-$root/.tooling/quartus_udev_compat.so}
case "$log_stem" in
    *[!A-Za-z0-9._-]*|'') echo "invalid log stem" >&2; exit 2 ;;
esac
case "$project_rel" in
    /*|*..*|*[!A-Za-z0-9_./-]*|'')
        echo "invalid QUARTUS_PROJECT_DIR" >&2
        exit 2
        ;;
esac
if [[ ! -d "$root/$project_rel" ]]; then
    echo "Quartus project directory does not exist: $root/$project_rel" >&2
    exit 2
fi
if [[ ! -x "$runtime_root/quartus/bin/quartus_map" ]]; then
    echo "Quartus runtime does not exist: $runtime_root" >&2
    exit 2
fi
if [[ ! -f "$udev_compat" ]]; then
    echo "Quartus libudev compatibility shim does not exist: $udev_compat" >&2
    exit 2
fi
case "$selection" in
    map|fit|asm|sta) stages=("$selection") ;;
    fit-asm-sta) stages=(fit asm sta) ;;
    all) stages=(map fit asm sta) ;;
    *) echo "invalid stage selection" >&2; exit 2 ;;
esac

mkdir -p "$root/.tooling/quartus-vm"
lock_dir="$root/.tooling/quartus-vm/.quartus-build.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "another Quartus build owns $lock_dir" >&2
    if [[ -f "$lock_dir/owner" ]]; then
        echo "owner: $(cat "$lock_dir/owner")" >&2
    fi
    exit 3
fi
printf 'pid=%s stem=%s started=%s\n' "$$" "$log_stem" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock_dir/owner"
trap 'rm -rf "$lock_dir"' EXIT INT TERM

log="$root/.tooling/quartus-vm/${log_stem}.log"
status="$root/.tooling/quartus-vm/${log_stem}.status"
: > "$log"
rm -f "$status"

code=0
for stage in "${stages[@]}"; do
    printf '[NDS-QUARTUS-DOCKER] %s BEGIN %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$stage" | tee -a "$log"
    set +e
    docker run --rm --platform linux/amd64 \
        -v "$root:/workspace" \
        -v "$runtime_root:/quartus-runtime:ro" \
        -v "$udev_compat:/usr/lib/x86_64-linux-gnu/libudev.so.1:ro" \
        -e LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libudev.so.1 \
        -w "/workspace/$project_rel" \
        --entrypoint "/quartus-runtime/quartus/bin/quartus_$stage" \
        nds4mister-quartus-runtime:17.0.2 NDS4MiSTer \
        2>&1 | tee -a "$log"
    code=${PIPESTATUS[0]}
    set -e
    printf '[NDS-QUARTUS-DOCKER] %s END %s rc=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$stage" "$code" | tee -a "$log"
    (( code == 0 )) || break
done
printf '%s\n' "$code" > "$status"
exit "$code"

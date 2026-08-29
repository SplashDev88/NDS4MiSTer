#!/bin/sh
# Resident H3D1 renderer supervisor for MiSTer's BusyBox userspace.
set -eu

umask 077

# Production paths are deliberately fixed.  The prefix exists only so the
# offline regression can exercise the exact script without touching /media or
# the host /tmp.  Deployed launchers must not set H3D_LIFECYCLE_TEST_ROOT.
test_root=${H3D_LIFECYCLE_TEST_ROOT:-}
if [ -n "$test_root" ]; then
    case "$test_root" in
        /*) ;;
        *) echo "H3D: test root must be absolute" >&2; exit 2 ;;
    esac
    if [ "$test_root" = / ]; then
        echo "H3D: refusing '/' as a test root" >&2
        exit 2
    fi
fi

support_dir=${test_root}/media/fat/Scripts/NDS_Support
service=${support_dir}/nds_hybrid_3d_service
manifest=${support_dir}/nds_hybrid_3d_service.sha256
wc_module=${support_dir}/nds_mem_wc.ko
wc_manifest=${support_dir}/nds_mem_wc.ko.sha256
pidfile=${test_root}/tmp/nds-hybrid-3d-service.pid
logfile=${test_root}/tmp/nds-hybrid-3d-service.log
logtmp=${test_root}/tmp/nds-hybrid-3d-service.log.trim
hps_clock_khz=1000000
default_hps_clock_khz=800000

start_stop_daemon=start-stop-daemon
sha256_program=sha256sum
if [ -n "$test_root" ]; then
    start_stop_daemon=${H3D_TEST_START_STOP_DAEMON:-$start_stop_daemon}
    sha256_program=${H3D_TEST_SHA256SUM:-$sha256_program}
fi

fail()
{
    echo "H3D: $*" >&2
    return 1
}

set_hps_clock()
{
    # The desktop regression has no MiSTer cpufreq tree. Production uses the
    # board's advertised 1 GHz boost point, which is the highest clock proven
    # stable by extended NSMB play testing on this unit.
    [ -z "$test_root" ] || return 0
    for cpu in 0 1; do
        clock_file=/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_max_freq
        [ -w "$clock_file" ] || {
            restore_hps_clock >/dev/null 2>&1 || true
            fail "CPU${cpu} clock control is unavailable"
            return 1
        }
        printf '%s\n' "$hps_clock_khz" >"$clock_file" || {
            restore_hps_clock >/dev/null 2>&1 || true
            fail "CPU${cpu} rejected the 1 GHz clock"
            return 1
        }
    done
    sleep 1
    for cpu in 0 1; do
        clock_root=/sys/devices/system/cpu/cpu${cpu}/cpufreq
        [ "$(cat "$clock_root/scaling_max_freq" 2>/dev/null || :)" = "$hps_clock_khz" ] &&
        [ "$(cat "$clock_root/scaling_cur_freq" 2>/dev/null || :)" = "$hps_clock_khz" ] || {
            restore_hps_clock >/dev/null 2>&1 || true
            fail "CPU${cpu} did not reach the requested 1 GHz clock"
            return 1
        }
    done
}

restore_hps_clock()
{
    [ -z "$test_root" ] || return 0
    restored=1
    for cpu in 0 1; do
        clock_file=/sys/devices/system/cpu/cpu${cpu}/cpufreq/scaling_max_freq
        printf '%s\n' "$default_hps_clock_khz" >"$clock_file" 2>/dev/null ||
            restored=0
    done
    [ "$restored" = 1 ]
}

reject_link()
{
    if [ -L "$1" ]; then
        fail "refusing symbolic link: $1"
    fi
}

preflight()
{
    reject_link "$service" || return 1
    reject_link "$manifest" || return 1
    [ -f "$service" ] && [ -x "$service" ] ||
        { fail "service is not an executable regular file: $service"; return 1; }
    [ -f "$manifest" ] ||
        { fail "missing hash manifest: $manifest"; return 1; }
    command -v "$sha256_program" >/dev/null 2>&1 ||
        { fail "sha256sum is unavailable"; return 1; }

    # Exactly one sha256sum-style record is accepted.  Pinning the basename as
    # well as the digest prevents a manifest for a different artifact from
    # accidentally authorizing the fixed executable path.
    set -f
    manifest_words=$(sed -n '1,$p' "$manifest")
    # Intentional word splitting; globbing is disabled above.
    set -- $manifest_words
    set +f
    [ "$#" -eq 2 ] ||
        { fail "hash manifest must contain exactly one record"; return 1; }
    expected=$1
    recorded_name=${2#\*}
    [ "${#expected}" -eq 64 ] ||
        { fail "hash manifest digest is not SHA-256"; return 1; }
    case "$expected" in
        *[!0-9a-f]*) fail "hash manifest digest must be lowercase hexadecimal"; return 1 ;;
    esac
    [ "$recorded_name" = nds_hybrid_3d_service ] ||
        { fail "hash manifest names the wrong executable"; return 1; }

    actual_line=$($sha256_program "$service") ||
        { fail "could not hash service executable"; return 1; }
    actual=${actual_line%% *}
    [ "$actual" = "$expected" ] ||
        { fail "service SHA-256 does not match manifest"; return 1; }

    # The WC module is optional so older kernels retain the known-good Device
    # mapping. If either module artifact is present, require the complete,
    # independently hashed pair before it can ever reach insmod.
    if [ -e "$wc_module" ] || [ -e "$wc_manifest" ] ||
       [ -L "$wc_module" ] || [ -L "$wc_manifest" ]; then
        reject_link "$wc_module" || return 1
        reject_link "$wc_manifest" || return 1
        [ -f "$wc_module" ] ||
            { fail "missing WC module: $wc_module"; return 1; }
        [ -f "$wc_manifest" ] ||
            { fail "missing WC module hash: $wc_manifest"; return 1; }
        set -f
        wc_manifest_words=$(sed -n '1,$p' "$wc_manifest")
        set -- $wc_manifest_words
        set +f
        [ "$#" -eq 2 ] ||
            { fail "WC module hash must contain exactly one record"; return 1; }
        wc_expected=$1
        wc_recorded_name=${2#\*}
        [ "${#wc_expected}" -eq 64 ] ||
            { fail "WC module digest is not SHA-256"; return 1; }
        case "$wc_expected" in
            *[!0-9a-f]*) fail "WC module digest must be lowercase hexadecimal"; return 1 ;;
        esac
        [ "$wc_recorded_name" = nds_mem_wc.ko ] ||
            { fail "WC manifest names the wrong module"; return 1; }
        wc_actual_line=$($sha256_program "$wc_module") ||
            { fail "could not hash WC module"; return 1; }
        wc_actual=${wc_actual_line%% *}
        [ "$wc_actual" = "$wc_expected" ] ||
            { fail "WC module SHA-256 does not match manifest"; return 1; }
    fi
}

load_wc_module()
{
    # The desktop lifecycle regression intentionally cannot modify its host
    # kernel. Production accepts an absent/incompatible module as a safe
    # performance fallback; service startup itself remains authoritative.
    [ -z "$test_root" ] || return 0
    [ -e /dev/nds_mem_wc ] && return 0
    [ -f "$wc_module" ] || return 0
    if ! insmod "$wc_module"; then
        echo "H3D: WC module unavailable for this kernel; using /dev/mem" >&2
        return 0
    fi
    [ -e /dev/nds_mem_wc ] || {
        rmmod nds_mem_wc >/dev/null 2>&1 || true
        echo "H3D: WC module created no device; using /dev/mem" >&2
        return 0
    }
}

unload_wc_module()
{
    [ -z "$test_root" ] || return 0
    rmmod nds_mem_wc >/dev/null 2>&1 || true
}

read_pid()
{
    reject_link "$pidfile" >/dev/null 2>&1 || return 1
    [ -f "$pidfile" ] || return 1
    pid=$(sed -n '1,$p' "$pidfile")
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$pid" -gt 1 ] 2>/dev/null || return 1
    printf '%s\n' "$pid"
}

status_raw()
{
    read_pid >/dev/null || return 1
    # BusyBox has no portable status action.  Stop test-mode performs the
    # exact pidfile+executable match but sends no signal and changes no file.
    "$start_stop_daemon" -K -t -q \
        -p "$pidfile" -x "$service" >/dev/null 2>&1
}

remove_stale_pidfile()
{
    if [ -L "$pidfile" ]; then
        fail "refusing symbolic-link pidfile: $pidfile"
        return 1
    fi
    rm -f "$pidfile"
}

prepare_log()
{
    reject_link "$logfile" || return 1
    reject_link "$logtmp" || return 1
    rm -f "$logtmp"
    : >"$logfile"
    chmod 600 "$logfile"
}

bound_stopped_log()
{
    [ -f "$logfile" ] || return 0
    reject_link "$logfile" || return 1
    bytes=$(wc -c <"$logfile")
    if [ "$bytes" -gt 65536 ]; then
        reject_link "$logtmp" || return 1
        tail -c 65536 "$logfile" >"$logtmp"
        chmod 600 "$logtmp"
        mv -f "$logtmp" "$logfile"
    fi
}

start_service()
{
    preflight || return 1
    set_hps_clock || return 1
    if status_raw; then
        pid=$(read_pid)
        echo "H3D: already running at 1 GHz (pid $pid)"
        return 0
    fi
    remove_stale_pidfile || return 1
    prepare_log || return 1
    load_wc_module || return 1

    # There are intentionally no arguments after '--': the resident renderer
    # has no ROM argument and therefore uses its compiled /dev/mem H3D window.
    # RLIMIT_FSIZE bounds inherited stdout/stderr even if a future error path
    # becomes noisy.  The service itself writes no steady-state log stream.
    if ! (
        ulimit -f 128 2>/dev/null || true
        # MiSTer's main loop is continuously runnable on CPU1. Give the
        # bounded H3D replay/render work precedence without killing MiSTer,
        # which preserves the normal menu, input, and core lifecycle.
        NDS4MISTER_DUAL_CORE_3D=1 \
        "$start_stop_daemon" -S -b -m -N -20 \
            -p "$pidfile" -x "$service" --
    ) >>"$logfile" 2>&1; then
        unload_wc_module
        restore_hps_clock >/dev/null 2>&1 || true
        fail "start-stop-daemon could not launch the service"
        return 1
    fi
    # BusyBox start-stop-daemon -b may return before the child has written its
    # pidfile and completed exec.  Poll the same exact pidfile/executable match
    # briefly; never launch a second copy while the first is settling.
    start_checks=0
    while [ "$start_checks" -lt 3 ]; do
        start_checks=$((start_checks + 1))
        status_raw && break
        [ "$start_checks" -ge 3 ] || sleep 1
    done
    if ! status_raw; then
        unload_wc_module
        restore_hps_clock >/dev/null 2>&1 || true
        fail "service did not remain running (see $logfile)"
        return 1
    fi
    pid=$(read_pid)
    echo "H3D: started at 1 GHz (pid $pid)"
}

stop_service()
{
    if ! status_raw; then
        remove_stale_pidfile || return 1
        bound_stopped_log || return 1
        unload_wc_module
        restore_hps_clock || {
            fail "could not restore the default 800 MHz clock"
            return 1
        }
        echo "H3D: stopped"
        return 0
    fi

    if ! "$start_stop_daemon" -K -o -R TERM/5/KILL/1 \
        -p "$pidfile" -x "$service" --remove-pidfile; then
        fail "start-stop-daemon could not stop the service"
        return 1
    fi
    if status_raw; then
        fail "service is still running after TERM/KILL retry"
        return 1
    fi
    remove_stale_pidfile || return 1
    bound_stopped_log || return 1
    unload_wc_module
    restore_hps_clock || {
        fail "could not restore the default 800 MHz clock"
        return 1
    }
    echo "H3D: stopped"
}

dump_service()
{
    if ! status_raw; then
        fail "service is not running"
        return 1
    fi
    pid=$(read_pid) || return 1
    if ! kill -USR1 "$pid"; then
        fail "could not request crash snapshot from pid $pid"
        return 1
    fi
    echo "H3D: crash snapshot requested; report will appear under /media/fat"
}

case "${1:-start}" in
    preflight)
        preflight
        echo "H3D: executable and SHA-256 preflight passed"
        ;;
    start)
        start_service
        ;;
    stop)
        stop_service
        ;;
    restart)
        stop_service
        start_service
        ;;
    status)
        if status_raw; then
            pid=$(read_pid)
            echo "H3D: running (pid $pid)"
        else
            echo "H3D: stopped"
            exit 3
        fi
        ;;
    dump)
        dump_service
        ;;
    *)
        echo "usage: $0 [preflight|start|stop|restart|status|dump]" >&2
        exit 2
        ;;
esac

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
mister_schedule_state=${test_root}/tmp/nds-h3d-mister-scheduling.state
mister_schedule_tmp=${test_root}/tmp/nds-h3d-mister-scheduling.state.tmp
mister_schedule_lock=${test_root}/tmp/nds-h3d-mister-scheduling.lock
mister_watch_lock=${test_root}/tmp/nds-h3d-mister-watch.lock
core_name_file=${test_root}/tmp/CORENAME
hps_clock_khz=1000000
default_hps_clock_khz=800000

start_stop_daemon=start-stop-daemon
sha256_program=sha256sum
taskset_program=taskset
pidof_program=pidof
proc_root=/proc
mister_watch_interval=1
mister_watch_limit=300
test_stop_lock_marker=
test_stop_lock_release=
if [ -n "$test_root" ]; then
    start_stop_daemon=${H3D_TEST_START_STOP_DAEMON:-$start_stop_daemon}
    sha256_program=${H3D_TEST_SHA256SUM:-$sha256_program}
    taskset_program=${H3D_TEST_TASKSET:-$taskset_program}
    pidof_program=${H3D_TEST_PIDOF:-$pidof_program}
    proc_root=${H3D_TEST_PROC_ROOT:-$proc_root}
    mister_watch_interval=${H3D_TEST_MISTER_WATCH_INTERVAL:-0.05}
    mister_watch_limit=${H3D_TEST_MISTER_WATCH_LIMIT:-40}
    test_stop_lock_marker=${H3D_TEST_STOP_LOCK_MARKER:-}
    test_stop_lock_release=${H3D_TEST_STOP_LOCK_RELEASE:-}
fi

fail()
{
    echo "H3D: $*" >&2
    return 1
}

read_mister_start_time()
{
    pid=$1
    stat_file=${proc_root}/${pid}/stat
    [ -r "$stat_file" ] || return 1
    # MiSTer's comm field contains no spaces. Field 22 distinguishes a
    # restarted frontend that happened to reuse the same numeric PID.
    stat_line=$(sed -n '1p' "$stat_file" 2>/dev/null) || return 1
    case "$stat_line" in
        "$pid (MiSTer) "*) ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$stat_line" | cut -d ' ' -f 22
}

read_process_start_time()
{
    pid=$1
    [ -r "${proc_root}/${pid}/stat" ] || return 1
    cut -d ' ' -f 22 "${proc_root}/${pid}/stat" 2>/dev/null
}

read_mister_affinity()
{
    "$taskset_program" -pc "$1" 2>/dev/null |
        sed -n 's/^.*affinity list: //p' | sed -n '1p'
}

single_mister_epoch()
{
    set -f
    mister_pids=$($pidof_program MiSTer 2>/dev/null || :)
    set -- $mister_pids
    set +f
    [ "$#" -eq 1 ] || return 1
    mister_pid=$1
    case "$mister_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$mister_pid" -gt 1 ] 2>/dev/null || return 1
    mister_start=$(read_mister_start_time "$mister_pid" || :)
    case "$mister_start" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s %s\n' "$mister_pid" "$mister_start"
}

write_mister_schedule_state()
{
    reject_link "$mister_schedule_state" || return 1
    reject_link "$mister_schedule_tmp" || return 1
    rm -f "$mister_schedule_tmp"
    printf '%s %s %s\n' "$1" "$2" "$3" >"$mister_schedule_tmp"
    chmod 600 "$mister_schedule_tmp" || return 1
    mv -f "$mister_schedule_tmp" "$mister_schedule_state" || return 1
}

read_mister_schedule_state()
{
    reject_link "$mister_schedule_state" >/dev/null 2>&1 || return 1
    [ -f "$mister_schedule_state" ] || return 1
    set -f
    state_words=$(sed -n '1,$p' "$mister_schedule_state")
    set -- $state_words
    set +f
    [ "$#" -eq 3 ] || return 1
    schedule_mister_pid=$1
    schedule_mister_start=$2
    schedule_affinity=$3
    case "$schedule_mister_pid:$schedule_mister_start" in
        ''|*[!0-9:]*) return 1 ;;
    esac
    case "$schedule_affinity" in
        0|1|0,1|0-1) ;;
        *) return 1 ;;
    esac
}

remove_mister_schedule_state()
{
    reject_link "$mister_schedule_state" >/dev/null 2>&1 || return 1
    reject_link "$mister_schedule_tmp" >/dev/null 2>&1 || return 1
    rm -f "$mister_schedule_state" "$mister_schedule_tmp"
}

restore_mister_frontend()
{
    [ -f "$mister_schedule_state" ] || return 0
    read_mister_schedule_state || return 1
    current_start=$(read_mister_start_time "$schedule_mister_pid" || :)
    if [ "$current_start" != "$schedule_mister_start" ]; then
        remove_mister_schedule_state
        return 0
    fi
    current_affinity=$(read_mister_affinity "$schedule_mister_pid" || :)
    if [ "$current_affinity" = "$schedule_affinity" ]; then
        remove_mister_schedule_state
        return 0
    fi
    [ "$(read_mister_start_time "$schedule_mister_pid" || :)" = \
      "$schedule_mister_start" ] || return 1
    "$taskset_program" -pc "$schedule_affinity" "$schedule_mister_pid" \
        >/dev/null 2>&1 || return 1
    [ "$(read_mister_start_time "$schedule_mister_pid" || :)" = \
      "$schedule_mister_start" ] &&
    [ "$(read_mister_affinity "$schedule_mister_pid" || :)" = \
      "$schedule_affinity" ] || return 1
    remove_mister_schedule_state
}

service_epoch_alive()
{
    [ "$(read_process_start_time "$1" || :)" = "$2" ]
}

nds_core_active()
{
    reject_link "$core_name_file" >/dev/null 2>&1 &&
    [ -f "$core_name_file" ] &&
    [ "$(cat "$core_name_file" 2>/dev/null || :)" = NDS ]
}

acquire_schedule_lock()
{
    reject_link "$mister_schedule_lock" >/dev/null 2>&1 || return 1
    lock_checks=0
    while ! mkdir "$mister_schedule_lock" 2>/dev/null; do
        lock_checks=$((lock_checks + 1))
        [ "$lock_checks" -lt 4 ] || return 1
        sleep "$mister_watch_interval"
    done
}

release_schedule_lock()
{
    rmdir "$mister_schedule_lock" 2>/dev/null
}

finish_mister_watch()
{
    trap - 0 HUP INT TERM
    if [ "${watch_schedule_locked:-0}" = 1 ]; then
        release_schedule_lock >/dev/null 2>&1 || true
    fi
    rmdir "$mister_watch_lock" 2>/dev/null || true
}

pin_mister_epoch()
{
    pin_service_pid=$1
    pin_service_start=$2
    pin_epoch=$3
    status_raw && [ "$(read_pid || :)" = "$pin_service_pid" ] &&
    service_epoch_alive "$pin_service_pid" "$pin_service_start" &&
    nds_core_active &&
    [ "$(single_mister_epoch || :)" = "$pin_epoch" ] || return 2
    set -- $pin_epoch
    pin_pid=$1
    pin_start=$2
    pin_affinity=$(read_mister_affinity "$pin_pid" || :)
    case "$pin_affinity" in 0|1|0,1|0-1) ;; *) return 2 ;; esac
    write_mister_schedule_state "$pin_pid" "$pin_start" "$pin_affinity" || return 1
    status_raw && [ "$(read_pid || :)" = "$pin_service_pid" ] &&
    service_epoch_alive "$pin_service_pid" "$pin_service_start" &&
    nds_core_active &&
    [ "$(single_mister_epoch || :)" = "$pin_epoch" ] || {
        remove_mister_schedule_state
        return 2
    }
    [ "$pin_affinity" = 0 ] ||
        "$taskset_program" -pc 0 "$pin_pid" >/dev/null 2>&1 || true
    after_start=$(read_mister_start_time "$pin_pid" || :)
    after_affinity=$(read_mister_affinity "$pin_pid" || :)
    if [ "$after_start" = "$pin_start" ] && [ "$after_affinity" = 0 ]; then
        return 0
    fi
    if [ "$after_start" != "$pin_start" ] ||
       [ "$after_affinity" = "$pin_affinity" ]; then
        remove_mister_schedule_state
        return 0
    fi
    restore_mister_frontend
}

mister_watch_loop()
{
    watch_service_pid=$1
    watch_service_start=$2
    baseline="$3 $4"
    case "$watch_service_pid:$watch_service_start:${3}:${4}" in
        ''|*[!0-9:]*) return 2 ;;
    esac
    watch_lock_checks=0
    while ! mkdir "$mister_watch_lock" 2>/dev/null; do
        watch_lock_checks=$((watch_lock_checks + 1))
        [ "$watch_lock_checks" -lt 3 ] || return 0
        sleep "$mister_watch_interval"
    done
    trap finish_mister_watch 0
    trap '' HUP
    trap 'exit 0' INT TERM
    watch_schedule_locked=0
    service_epoch_alive "$watch_service_pid" "$watch_service_start" || return 0
    candidate=
    watch_checks=0
    while [ "$watch_checks" -lt "$mister_watch_limit" ] &&
          service_epoch_alive "$watch_service_pid" "$watch_service_start"; do
        watch_checks=$((watch_checks + 1))
        epoch=$(single_mister_epoch || :)
        if [ -n "$epoch" ] && [ "$epoch" != "$baseline" ]; then
            if [ "$epoch" = "$candidate" ]; then
                acquire_schedule_lock || return 1
                watch_schedule_locked=1
                trap '' INT TERM
                pin_result=0
                pin_mister_epoch "$watch_service_pid" \
                    "$watch_service_start" "$epoch" || pin_result=$?
                release_schedule_lock || return 1
                watch_schedule_locked=0
                trap 'exit 0' INT TERM
                [ "$pin_result" -eq 2 ] || return "$pin_result"
                candidate=
            fi
            candidate=$epoch
        else
            candidate=
        fi
        sleep "$mister_watch_interval"
    done
}

start_mister_watch()
{
    command -v "$taskset_program" >/dev/null 2>&1 &&
    command -v "$pidof_program" >/dev/null 2>&1 || {
        echo "H3D: taskset/pidof unavailable; MiSTer affinity unchanged" >&2
        return 0
    }
    service_pid=$(read_pid) || return 1
    service_start=$(read_process_start_time "$service_pid" || :)
    case "$service_start" in ''|*[!0-9]*) return 1 ;; esac
    if [ -f "$mister_schedule_state" ]; then
        read_mister_schedule_state || return 1
        if [ "$(read_mister_start_time "$schedule_mister_pid" || :)" = \
             "$schedule_mister_start" ]; then
            return 0
        fi
        restore_mister_frontend || return 1
    fi
    baseline=$(single_mister_epoch || :)
    [ -n "$baseline" ] || {
        echo "H3D: expected one MiSTer frontend; affinity watcher not started" >&2
        return 0
    }
    set -- $baseline
    (trap '' HUP; exec "$0" __mister_watch \
        "$service_pid" "$service_start" "$1" "$2") \
        </dev/null >>"$logfile" 2>&1 &
    return 0
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
        start_mister_watch ||
            echo "H3D: MiSTer affinity watcher unavailable" >&2
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
        NDS4MISTER_ADAPTIVE_RASTER_SPLIT=1 \
        NDS4MISTER_RASTER_BAND_QUEUE=1 \
        NDS4MISTER_RASTER_X_PARTITION=1 \
        NDS4MISTER_DIRECT_PLANE_PUBLICATION=1 \
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
    start_mister_watch ||
        echo "H3D: MiSTer affinity watcher unavailable" >&2
    echo "H3D: started at 1 GHz (pid $pid)"
}

stop_service_mutation()
{
    if ! status_raw; then
        remove_stale_pidfile || return 1
        restore_mister_frontend || return 1
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
    restore_mister_frontend || return 1
}

finish_stop_schedule_lock()
{
    if [ "${stop_schedule_locked:-0}" = 1 ]; then
        stop_schedule_locked=0
        release_schedule_lock >/dev/null 2>&1 || true
    fi
}

stop_service()
{
    acquire_schedule_lock || {
        fail "could not serialize MiSTer affinity shutdown"
        return 1
    }
    stop_schedule_locked=1
    trap finish_stop_schedule_lock 0
    trap 'exit 1' HUP INT TERM
    if [ -n "$test_stop_lock_marker" ]; then
        : >"$test_stop_lock_marker"
        while [ ! -f "$test_stop_lock_release" ]; do
            sleep "$mister_watch_interval"
        done
    fi
    stop_result=0
    stop_service_mutation || stop_result=$?
    trap '' HUP INT TERM
    release_schedule_lock || return 1
    stop_schedule_locked=0
    trap - 0 HUP INT TERM
    [ "$stop_result" -eq 0 ] || return "$stop_result"
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
    __mister_watch)
        [ "$#" -eq 5 ] || exit 2
        mister_watch_loop "$2" "$3" "$4" "$5"
        ;;
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

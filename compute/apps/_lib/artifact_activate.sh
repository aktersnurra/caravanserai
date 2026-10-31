#!/bin/sh
# Activate an already verified/installed release/executable in a FreeBSD jail.
# Caller must hold the compute host infra lock. No legacy conversion or config rewriting.
# Explicit rollback uses this same operation with the previous identity/digest.
# MIGRATE is `migrate` to run `service SERVICE migrate` after the switch and
# before start, or `-`. The release already active but stopped is resumed:
# migrate, start, health. After a healthy start only the active and previous
# releases are kept. JAIL is the jexec target and APP names the in-jail
# paths; they differ only in a test jail.
# Usage: artifact_activate.sh JAIL IDENTITY SHA256 SERVICE RELEASE CHECK_URL MIGRATE APP
set -eu
jail=${1:?jail required}
identity=${2:?artifact identity required}
expected=${3:?archive SHA-256 required}
service_name=${4:?service required}
release_name=${5:?release name required}
check_url=${6:?health URL required}
migrate=${7:?migrate mode required}
app=${8:?app required}

fail() { echo "artifact activation: $*" >&2; exit 1; }
safe_component() {
    case "$1" in ''|.|..|*[!a-zA-Z0-9._-]*) return 1 ;; esac
    [ "${#1}" -le 128 ]
}
is_digest() {
    case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac
    [ "${#1}" -eq 64 ]
}
if ! safe_component "$jail" || ! safe_component "$app" || ! safe_component "$service_name" \
    || ! safe_component "$release_name"; then
    fail 'invalid jail, app, service or release name'
fi
if ! is_digest "$identity" || ! is_digest "$expected"; then fail 'invalid identity or digest'; fi
case "$migrate" in migrate|-) ;; *) fail 'invalid migrate mode' ;; esac
case "$check_url" in http://*) ;; *) fail 'health URL must use http' ;; esac
case "$check_url" in *[!a-zA-Z0-9./:_?=\&%+-]*) fail 'invalid health URL' ;; esac

jroot=${JAIL_ROOT:-/jails/$jail}
release_root="$jroot/opt/.infra-releases/$app"
target="$release_root/$identity"
active="$jroot/opt/$app"
previous="$release_root/.previous"
for dir in "$jroot" "$jroot/opt" "$jroot/opt/.infra-releases" "$release_root" "$target" "$target/bin"; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || fail 'missing or redirected release directory'
done
[ -f "$target/.infra-sha256" ] && [ ! -L "$target/.infra-sha256" ] \
    || fail 'missing installed archive digest'
[ "$(cat "$target/.infra-sha256")" = "$expected" ] || fail 'installed archive digest mismatch'
[ -f "$target/bin/$release_name" ] && [ ! -L "$target/bin/$release_name" ] \
    && [ -x "$target/bin/$release_name" ] || fail 'missing release launcher'

old_id=''
if [ -L "$active" ]; then
    old_link=$(readlink "$active")
    prefix=".infra-releases/$app/"
    case "$old_link" in "$prefix"*) old_id=${old_link#"$prefix"} ;; *) fail 'unmanaged active pointer' ;; esac
    is_digest "$old_id" || fail 'invalid active identity'
    [ -d "$release_root/$old_id" ] && [ ! -L "$release_root/$old_id" ] \
        || fail 'missing or redirected active release'
elif [ -e "$active" ]; then
    fail 'legacy active directory needs explicit conversion'
fi
if [ -L "$previous" ]; then
    previous_id=$(readlink "$previous")
    is_digest "$previous_id" || fail 'unmanaged previous pointer'
    [ -d "$release_root/$previous_id" ] && [ ! -L "$release_root/$previous_id" ] \
        || fail 'missing or redirected previous release'
elif [ -e "$previous" ]; then
    fail 'previous pointer is occupied'
fi

jexec_bin=${JEXEC_BIN:-jexec}
mv_bin=${MV_BIN:-mv}
sleep_bin=${SLEEP_BIN:-sleep}
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
check_health() {
    sh "$script_dir/artifact_check_health.sh" "$check_url" "$jail" "$service_name"
}
# FreeBSD service(8) interprets inherited JAIL. These are command-line inputs,
# not service environment. Never propagate extra-step context into service.
unset JAIL JAIL_IP JROOT APP
umask 022
# rc: the service's rc status says whether it runs. process: its rc status
# checks something else, so it is not asked, and a process named after the
# release decides when the old one has stopped.
service_status=${INFRA_ARTIFACT_SERVICE_STATUS:-rc}
case "$service_status" in rc|process) ;; *) fail 'invalid service status mode' ;; esac
if [ "$old_id" = "$identity" ]; then
    status=0
    if [ "$service_status" = rc ]; then
        "$jexec_bin" "$jail" service "$service_name" status >/dev/null 2>&1 || status=$?
    fi
    case "$status" in
        0) ;;
        1)
            # Active but stopped: an earlier activation of this release
            # stopped at migrate or start. Finish it the same way.
            if [ "$migrate" = migrate ]; then
                "$jexec_bin" "$jail" service "$service_name" migrate \
                    || fail "migrate failed; the service is stopped on $identity"
            fi
            "$jexec_bin" "$jail" service "$service_name" start || fail 'selected release start failed'
            check_health || fail 'selected release is unhealthy after start'
            echo "release resumed and healthy: $jail $identity"
            exit 0 ;;
        *) fail 'selected release status is unknown; pointer unchanged' ;;
    esac
    check_health || fail 'selected release is unhealthy; pointer unchanged'
    echo "release already active and healthy: $jail $identity"
    exit 0
fi
tmp=$(mktemp -d "$release_root/.switch.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
ln -s ".infra-releases/$app/$identity" "$tmp/current"
if [ -n "$old_id" ] && [ "$old_id" != "$identity" ]; then
    ln -s "$old_id" "$tmp/previous"
fi
# Stop using the OLD launcher before switching: rc stop sources external env
# and invokes /opt/<app>/bin/<release>. Do not hand stop to a new launcher.
if [ -n "$old_id" ]; then
    "$jexec_bin" "$jail" service "$service_name" stop || fail 'old service stop failed; pointer unchanged'
    # Release stop acknowledges before the VM necessarily exits. Keep the
    # lifecycle lock and old pointer while waiting; never force-kill it.
    remaining=10
    while :; do
        if "$jexec_bin" "$jail" service "$service_name" status >/dev/null 2>&1; then
            [ "$remaining" -gt 0 ] || fail 'old service is still running; pointer unchanged'
            "$sleep_bin" 1 || fail 'old service wait failed; pointer unchanged'
            remaining=$((remaining - 1))
        else
            [ "$?" -eq 1 ] || fail 'old service status is unknown; pointer unchanged'
            if [ "$service_status" = process ]; then
                processes=$("$jexec_bin" "$jail" ps -axo comm=) \
                    || fail 'old process status is unknown; pointer unchanged'
                [ -n "$processes" ] || fail 'old process status is empty; pointer unchanged'
                if printf '%s\n' "$processes" | awk -v name="$release_name" '$NF == name || substr($NF, length($NF) - length(name)) == "/" name { found=1 } END { exit !found }'; then
                    [ "$remaining" -gt 0 ] || fail 'old process is still running; pointer unchanged'
                    "$sleep_bin" 1 || fail 'old service wait failed; pointer unchanged'
                    remaining=$((remaining - 1))
                    continue
                fi
            fi
            break
        fi
    done
fi
if [ -L "$tmp/previous" ]; then
    "$mv_bin" -fh "$tmp/previous" "$previous" || fail 'could not retain previous pointer; active pointer unchanged'
fi
# FreeBSD -h refuses to follow a destination directory symlink. Plain POSIX mv
# would move the temporary pointer INSIDE the old release instead of replacing it.
"$mv_bin" -fh "$tmp/current" "$active" || fail 'active pointer switch failed'
# No automatic rollback past this point: a migration may have changed data
# that the previous release cannot read.
if [ "$migrate" = migrate ]; then
    "$jexec_bin" "$jail" service "$service_name" migrate \
        || fail "migrate failed; the service is stopped on $identity${old_id:+; previous release $old_id retained for explicit rollback}"
fi
"$jexec_bin" "$jail" service "$service_name" start \
    || fail 'new service start failed; previous release retained for explicit rollback'
check_health || fail 'new release health check failed; previous release retained for explicit rollback'
echo "release active and healthy: $jail $identity"
# Rollback reaches only the previous release, so older ones are dead weight.
# A failed removal is reported, never fatal: the activation already succeeded.
kept_previous=''
[ ! -L "$previous" ] || kept_previous=$(readlink "$previous")
for dir in "$release_root"/*; do
    id=${dir##*/}
    is_digest "$id" || continue
    if [ "$id" = "$identity" ] || [ "$id" = "$kept_previous" ]; then continue; fi
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    if rm -rf -- "$dir"; then
        echo "pruned release: $jail $id"
    else
        echo "artifact activation: could not prune $dir" >&2
    fi
done

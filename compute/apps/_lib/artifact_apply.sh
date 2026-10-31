#!/bin/sh
# Caller selected and reverified a trusted owned-store entry, holds the compute host
# lifecycle lock, and verified all transferred helper digests before execution.
# MODE JAIL IDENTITY SHA256 ARCHIVE RELEASE CHECK_URL ABI BINARY_ANCHOR MIGRATE APP
# MIGRATE (`migrate` | `-`) is passed to activation. APP names the in-jail
# paths and an executable's service; it differs from JAIL only in a test jail,
# which conversion refuses. A BINARY_ANCHOR that does not exist yet, in a jail
# whose /opt/APP is a managed pointer or absent, is created as the link to
# the active release; any other occupant is legacy.
set -eu
mode=${1:?mode required}
jail=${2:?jail required}
identity=${3:?identity required}
expected=${4:?archive digest required}
archive=${5:?archive required}
release=${6:?release required}
check_url=${7:?health URL required}
abi=${8:?target ABI required}
anchor=${9:?binary anchor required}
migrate=${10:?migrate mode required}
app=${11:?app required}
fail() { echo "artifact apply: $*" >&2; exit 1; }
[ "${SERAI_LOCK_HELD:-0}" = 1 ] || fail 'lifecycle lock required'
case "$mode" in upgrade|rollback|convert) ;; *) fail 'invalid operation' ;; esac
case "$migrate" in migrate|-) ;; *) fail 'invalid migrate mode' ;; esac
case "$jail:$app:$release" in *[!a-zA-Z0-9_:-]*) fail 'invalid workload, app or release' ;; esac
[ -n "$jail" ] && [ -n "$app" ] && [ -n "$release" ] || fail 'empty workload, app or release'
[ "$mode" != convert ] || [ "$app" = "$jail" ] || fail 'conversion is for live jails only'
[ "$mode" != convert ] || [ "$anchor" != - ] || fail 'conversion is for executables only'
case "$identity" in ''|*[!0-9a-f]*) fail 'invalid identity' ;; esac
[ "${#identity}" -eq 64 ] || fail 'invalid identity length'
unset JAIL JAIL_IP JROOT APP
jexec_bin=${JEXEC_BIN:-jexec}
jroot=${JAIL_ROOT:-/jails/$jail}
[ -d "$jroot" ] && [ ! -L "$jroot" ] || fail 'missing or redirected jail root'
actual_abi=$("$jexec_bin" "$jail" pkg config abi) || fail 'target ABI probe failed'
[ "$actual_abi" = "$abi" ] || fail 'artifact target ABI does not match the jail'
create_anchor=false
case "$anchor" in
    -) ;;
    /usr/local/bin/*)
        case "${anchor#/usr/local/bin/}" in ''|*[!a-zA-Z0-9_-]*) fail 'invalid executable anchor' ;; esac
        if [ "$mode" = upgrade ] && [ ! -e "$jroot$anchor" ] && [ ! -L "$jroot$anchor" ] \
            && { [ -L "$jroot/opt/$app" ] || [ ! -e "$jroot/opt/$app" ]; }; then
            create_anchor=true
        elif [ "$mode" != convert ]; then
            [ -L "$jroot$anchor" ] && [ "$(readlink "$jroot$anchor")" = "/opt/$app/bin/$release" ] \
                || fail 'legacy executable needs explicit conversion'
        fi ;;
    *) fail 'invalid executable anchor' ;;
esac
if [ "$mode" = rollback ]; then
    previous=$jroot/opt/.infra-releases/$app/.previous
    [ -L "$previous" ] && [ "$(readlink "$previous")" = "$identity" ] \
        || fail 'requested identity is not the retained previous release'
fi
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
sh "$script_dir/artifact_install.sh" "$jail" "$identity" "$archive" "$expected" "$app"
if [ "$mode" = convert ]; then
    sh "$script_dir/artifact_convert_binary.sh" "$jail" "$identity" "$expected" "$release" "$check_url" "$anchor"
else
    service_name=$release
    [ "$anchor" = - ] || service_name=$app
    if [ "$create_anchor" = true ]; then
        # Dangling until the first activation creates /opt/APP.
        mkdir -p "$jroot/usr/local/bin"
        ln -s "/opt/$app/bin/$release" "$jroot$anchor" || fail 'could not create the executable anchor'
    fi
    sh "$script_dir/artifact_activate.sh" "$jail" "$identity" "$expected" "$service_name" "$release" "$check_url" "$migrate" "$app"
fi

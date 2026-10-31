#!/bin/sh
# Run as an unprivileged user inside a disposable FreeBSD build jail.
# Source has already been staged at SOURCE_DIR. The caller retrieves the
# archive from OUTPUT_DIR after this process exits, then destroys the jail.
# Usage: artifact_build_phoenix.sh SOURCE_DIR RELEASE_NAME OUTPUT_DIR ASSET_SCRIPT
set -eu

[ "$#" -eq 4 ] || exit 1

source_dir=${1:?source directory required}
release_name=${2:?release name required}
output_dir=${3:?output directory required}
asset_script=${4:?asset script required}
[ -f "$asset_script" ] && [ ! -L "$asset_script" ] || exit 1

case "$source_dir" in /*) ;; *) echo 'source path must be absolute' >&2; exit 1 ;; esac
case "$output_dir" in /*) ;; *) echo 'output path must be absolute' >&2; exit 1 ;; esac

case "$release_name" in
    ''|*[!a-z0-9_]*) echo 'invalid release name' >&2; exit 1 ;;
esac
[ -d "$source_dir" ] && [ ! -L "$source_dir" ] || {
    echo 'source must be a directory' >&2; exit 1
}
[ ! -e "$output_dir" ] && [ ! -L "$output_dir" ] || {
    echo 'artifact output already exists' >&2; exit 1
}

mix_bin=${MIX_BIN:-mix}
elixir_bin=${ELIXIR_BIN:-elixir}
sha256_bin=${SHA256_BIN:-sha256}
umask 077
# Fresh-cache native jail probes fail with parallel npm downloads but pass
# serially. Limit this client's connections, without changing host networking.
npm_config_maxsockets=1
# Disposable build jails have only IPv4. Prefer their usable address family
# in Node's registry client; do not change host or service networking.
NODE_OPTIONS=--dns-result-order=ipv4first
# Keep public registry request outcomes visible when a disposable jail is cleaned.
npm_config_loglevel=verbose
export npm_config_maxsockets NODE_OPTIONS npm_config_loglevel
# A production build throughout. Exported, not prefixed to each timed call:
# FreeBSD sh does not pass a function call's assignments on to its commands.
MIX_ENV=prod
export MIX_ENV
timing_operation=artifact.build
timing_root=$source_dir
# Durations cover one isolated invocation, never an accumulated category total.
# Native FreeBSD acceptance must separately verify /usr/bin/time's real clock.
timing_unavailable() {
    [ "${INFRA_PROGRESS_JSONL:-}" = 1 ] || return 0
    (printf '{"event":"infra.phase_timing_unavailable","operation":"%s","workload":null,"phase":"%s","parent":"remote-total","reason":"%s"}\n' "$timing_operation" "$1" "$2" >&2) || :
}
timing_skipped() {
    [ "${INFRA_PROGRESS_JSONL:-}" = 1 ] || return 0
    (printf '{"event":"infra.phase_duration","operation":"%s","workload":null,"phase":"%s","parent":"remote-total","status":"skipped","duration_seconds":null,"reason":"%s"}\n' "$timing_operation" "$1" "$2" >&2) || :
}
timed() (
    timing_phase=$1; shift
    if [ "${INFRA_PROGRESS_JSONL:-}" != 1 ]; then exec "$@"; fi
    if [ ! -x "${TIME_BIN:-/usr/bin/time}" ]; then
        timing_unavailable "$timing_phase" 'time executable unavailable'
        exec "$@"
    fi
    timing_scratch=$(mktemp -d "$timing_root/.phase-time.XXXXXXXX") || {
        timing_unavailable "$timing_phase" 'private timing scratch unavailable'
        exec "$@"
    }
    # Preflight diagnostic files without changing the child's inherited mask.
    (umask 077; : >"$timing_scratch/child" && : >"$timing_scratch/time") || {
        rm -rf "$timing_scratch" || :
        timing_unavailable "$timing_phase" 'private timing files unavailable'
        exec "$@"
    }
    timing_status=0
    # The child redirect is separate from time's stderr, including on failure.
    "${TIME_BIN:-/usr/bin/time}" -p sh -c 'err=$1; shift; exec "$@" 2>"$err"' sh "$timing_scratch/child" "$@" 2>"$timing_scratch/time" || timing_status=$?
    cat "$timing_scratch/child" >&2 2>/dev/null || :
    timing_real=$(LC_ALL=C awk '$1=="real" {n++; if(NF!=2 || $2!~/^(0|[1-9][0-9]*)([.][0-9]+)?$/) bad=1; v=$2} END {if(n!=1 || bad) exit 1; print v}' "$timing_scratch/time") || timing_real=
    # Keep time's own execution/signal errors, not its CPU/real summary.
    LC_ALL=C awk '!/^(real|user|sys)[[:space:]]+[0-9]+([.][0-9]+)?$/' "$timing_scratch/time" >&2 || :
    if [ -n "$timing_real" ]; then
        timing_state=completed
        [ "$timing_status" = 0 ] || timing_state=failed
        (printf '{"event":"infra.phase_duration","operation":"%s","workload":null,"phase":"%s","parent":"remote-total","status":"%s","duration_seconds":%s,"reason":null}\n' "$timing_operation" "$timing_phase" "$timing_state" "$timing_real" >&2) || :
    else
        timing_unavailable "$timing_phase" 'time real interval unavailable'
    fi
    rm -rf "$timing_scratch" || :
    exit "$timing_status"
)
cd "$source_dir"
timed asset-prepare "$elixir_bin" -r "$asset_script" -S "$mix_bin" infra.assets --prepare-only
timed tool-prepare "$mix_bin" local.hex --force --if-missing
timed tool-prepare "$mix_bin" local.rebar --force --if-missing
timed dependency-fetch "$mix_bin" deps.get --only prod
timed dependency-compile "$mix_bin" deps.compile
timed asset-build "$elixir_bin" -r "$asset_script" -S "$mix_bin" infra.assets
# mix release may compile too; this is not a compile-only interval.
timed release-archive sh -eu -c 'MIX_ENV=prod "$1" release
source_dir=$2 release_name=$3 output_dir=$4 sha256_bin=$5

release_dir="$source_dir/_build/prod/rel/$release_name"
[ -x "$release_dir/bin/$release_name" ] || {
    echo "Phoenix release $release_name was not produced" >&2; exit 1
}
# Runtime RELEASE_COOKIE is supplied by the operator external jail env.
# Never archive Mix generated generated authentication secret.
rm -f "$release_dir/releases/COOKIE"
mkdir -p "$output_dir"
archive="$output_dir/release.tar"
tmp="$output_dir/release.tar.tmp"
trap "rm -f \"\$tmp\"" EXIT HUP INT TERM
tar -cf "$tmp" -C "$release_dir" .
mv "$tmp" "$archive"
trap - EXIT HUP INT TERM
"$sha256_bin" -q "$archive" >"$output_dir/release.sha256"
' sh "$mix_bin" "$source_dir" "$release_name" "$output_dir" "$sha256_bin"

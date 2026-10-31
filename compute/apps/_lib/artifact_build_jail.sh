#!/bin/sh
# Host-side disposable Phoenix/OCaml/package/pinned-executable build jail.
# Called by a locked controller after declared input and IP/base verification.
set -eu
umask 077

refuse() { echo 'build jail: invalid or unsafe input' >&2; exit 1; }
# Exit status: 0 built; 3 failed or refused with nothing left behind;
# 1 teardown incomplete (inspect before unlocking); 130 interrupted.
attempted=0
created=0
ready=0
output_tmp=
torn_down=1
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    set +e
    if [ "$created" -eq 1 ]; then timing_unavailable jail-clone-teardown 'stateful ownership checks remain in the owning shell'; fi
    if [ "$attempted" -eq 1 ]; then
        if existing_after=$("$jls_bin" name); then
            if printf '%s\n' "$existing_after" | grep -Fxq "$jail_name"; then
                if ! "$jail_bin" -r "$jail_name" >/dev/null 2>&1; then
                    (echo 'build jail: removal failed; inspect the preserved build jail root' >&2) || :
                    result=1
                    torn_down=0
                    created=0
                fi
            fi
        else
            (echo 'build jail: cannot confirm removal; preserving build jail root' >&2) || :
            result=1
            torn_down=0
            created=0
        fi
    fi
    if [ "$created" -eq 1 ] && [ "$attempted" -eq 1 ]; then
        if existing_after=$("$jls_bin" name); then
            if printf '%s\n' "$existing_after" | grep -Fxq "$jail_name"; then
                (echo 'build jail: jail still present; preserving build jail root' >&2) || :
                result=1
                torn_down=0
                created=0
            fi
        else
            (echo 'build jail: cannot confirm removal; preserving build jail root' >&2) || :
            result=1
            torn_down=0
            created=0
        fi
    fi
    if [ "$created" -eq 1 ]; then
        can_remove=1
        if mounts=$("$mount_bin"); then
            if printf '%s\n' "$mounts" | grep -F " on $jroot/dev (" >/dev/null; then
                "$umount_bin" "$jroot/dev" || can_remove=0
            fi
            if mounts=$("$mount_bin"); then
                if printf '%s\n' "$mounts" | grep -F " on $jroot/" >/dev/null; then
                    can_remove=0
                fi
            else
                can_remove=0
            fi
        else
            can_remove=0
        fi
        if [ "$attempted" -eq 1 ]; then
            if addresses=$("$ifconfig_bin" lo1); then
                if printf '%s\n' "$addresses" | awk -v ip="$ip" '$1 == "inet" && $2 == ip { found = 1 } END { exit !found }'; then
                    "$ifconfig_bin" lo1 inet "$ip" -alias || can_remove=0
                fi
                if addresses=$("$ifconfig_bin" lo1); then
                    if printf '%s\n' "$addresses" | awk -v ip="$ip" '$1 == "inet" && $2 == ip { found = 1 } END { exit !found }'; then
                        can_remove=0
                    fi
                else
                    can_remove=0
                fi
            else
                can_remove=0
            fi
        fi
        if [ "$can_remove" -eq 1 ]; then
            "$chflags_bin" -R noschg,nouchg "$jroot" || can_remove=0
        fi
        if [ "$can_remove" -eq 1 ]; then
            rm -rf "$jroot" || can_remove=0
            [ ! -e "$jroot" ] && [ ! -L "$jroot" ] || can_remove=0
        fi
        if [ "$can_remove" -ne 1 ]; then
            (echo 'build jail: cleanup incomplete; inspect preserved root, mount and address' >&2) || :
            result=1
            torn_down=0
        fi
    fi
    if [ "$result" -eq 0 ] && [ "$ready" -eq 1 ]; then
        if [ -e "$output_dir" ] || [ -L "$output_dir" ]; then
            result=1
        else
            mv "$output_tmp" "$output_dir" || result=1
        fi
    fi
    if [ -n "$output_tmp" ] && [ -d "$output_tmp" ]; then rm -rf "$output_tmp"; fi
    # A failure after complete teardown leaves nothing behind: say so with 3,
    # so the controller can release its lock. An interrupt stays 130.
    if [ "$result" -ne 0 ] && [ "$result" -ne 130 ] && [ "$torn_down" -eq 1 ]; then result=3; fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
[ "${INFRA_LOCK_HELD:-}" = 1 ] || refuse
[ "$#" -ge 10 ] || refuse
jail_name=$1
ip=$2
base_archive=$3
base_sha256=$4
source_dir=$5
inventory=$6
inventory_sha256=$7
release_name=$8
output_dir=$9
shift 9
[ "$#" -gt 0 ] || refuse

case "$jail_name" in
    infra-build-*) ;;
    *) refuse ;;
esac
suffix=${jail_name#infra-build-}
case "$suffix" in ''|*[!a-z0-9_-]*) refuse ;; esac
[ "${#jail_name}" -le 128 ] || refuse
# infra checks the address is a host on the declared jail subnet; here it
# must at least be one IPv4 address in one spelling.
is_ipv4() {
    case "$1" in *[!0-9.]*|.*|*.|*..*) return 1 ;; esac
    old_ifs=$IFS
    IFS=.
    # shellcheck disable=SC2086 # split on the dots
    set -- $1
    IFS=$old_ifs
    [ "$#" -eq 4 ] || return 1
    for octet do
        case "$octet" in 0) ;; 0*) return 1 ;; esac
        [ "${#octet}" -le 3 ] && [ "$octet" -le 255 ] || return 1
    done
}
is_ipv4 "$ip" || refuse
ifconfig_bin=${IFCONFIG_BIN:-ifconfig}
addresses=$("$ifconfig_bin" lo1) || refuse
if printf '%s\n' "$addresses" | awk -v ip="$ip" '$1 == "inet" && $2 == ip { found = 1 } END { exit !found }'; then
    refuse
fi
kind=${INFRA_ARTIFACT_KIND:-phoenix}
case "$kind" in phoenix|ocaml|package|binary) ;; *) refuse ;; esac
if [ "$kind" = ocaml ]; then
    [ -d "${INFRA_OPAM_REPOSITORY:-}" ] && [ ! -L "$INFRA_OPAM_REPOSITORY" ] || refuse
    [ -f "${INFRA_OPAM_INVENTORY:-}" ] && [ ! -L "$INFRA_OPAM_INVENTORY" ] || refuse
    case "${INFRA_OPAM_INVENTORY_SHA256:-}" in ''|*[!0-9a-f]*) refuse ;; esac
    [ "${#INFRA_OPAM_INVENTORY_SHA256}" -eq 64 ] || refuse
    case "${INFRA_OCAML_COMPILER:-}" in ocaml-base-compiler.[0-9]*) ;; *) refuse ;; esac
    case "$INFRA_OCAML_COMPILER" in *[!a-zA-Z0-9_.+-]*) refuse ;; esac
    # Optional: the web bundle the controller built; the worker checks its files.
    if [ -n "${INFRA_WEB_BUNDLE:-}" ]; then
        [ -d "$INFRA_WEB_BUNDLE" ] && [ ! -L "$INFRA_WEB_BUNDLE" ] || refuse
    fi
elif [ -n "${INFRA_WEB_BUNDLE:-}" ]; then
    refuse
fi
case "$release_name" in ''|-*|*[!a-z0-9_-]*) refuse ;; esac
[ "${#release_name}" -le 128 ] || refuse
erlang_version=''
for package do
    case "$package" in ''|*[!a-zA-Z0-9._+-]*) refuse ;; esac
    case "$package" in erlang-runtime*)
        version=${package#erlang-runtime}
        case "$version" in ''|*[!0-9]*) refuse ;; esac
        [ -z "$erlang_version" ] || refuse
        erlang_version=$version ;;
    esac
done
case "$base_sha256" in *[!0-9a-f]* ) refuse ;; esac
[ "${#base_sha256}" -eq 64 ] || refuse
[ -f "$base_archive" ] && [ ! -L "$base_archive" ] || refuse
if [ "$kind" = phoenix ] || [ "$kind" = ocaml ]; then
    [ "$kind" != phoenix ] || [ -n "$erlang_version" ] || refuse
    case "$inventory_sha256" in *[!0-9a-f]* ) refuse ;; esac
    [ "${#inventory_sha256}" -eq 64 ] || refuse
    [ -d "$source_dir" ] && [ ! -L "$source_dir" ] || refuse
    [ -f "$inventory" ] && [ ! -L "$inventory" ] || refuse
else
    [ "$source_dir:$inventory:$inventory_sha256" = '-:-:-' ] || refuse
    if [ "$kind" = binary ]; then
        case "${INFRA_EXECUTABLE_SOURCE:-}" in https://?*) ;; *) refuse ;; esac
        case "${INFRA_EXECUTABLE_SOURCE:-}" in *[!a-zA-Z0-9/.:_+-]*) refuse ;; esac
        case "${INFRA_EXECUTABLE_SHA256:-}" in ''|*[!0-9a-f]*) refuse ;; esac
        [ "${#INFRA_EXECUTABLE_SHA256}" -eq 64 ] || refuse
    fi
fi
[ ! -e "$output_dir" ] && [ ! -L "$output_dir" ] || refuse
jails_dir=${JAILS_DIR:-/jails/.infra-build}
case "$jails_dir" in /*) ;; *) refuse ;; esac
[ -d "$jails_dir" ] && [ ! -L "$jails_dir" ] || refuse
stat_bin=${STAT_BIN:-stat}
jails_mode=$("$stat_bin" -f %p "$jails_dir") || refuse
case $jails_mode in ''|*[!0-7]*) refuse ;; esac
[ "${#jails_mode}" -le 6 ] || refuse
[ "$((0$jails_mode & 07777))" -eq "$((0700))" ] || refuse
jroot="$jails_dir/$jail_name"
[ ! -e "$jroot" ] && [ ! -L "$jroot" ] || refuse
jls_bin=${JLS_BIN:-jls}
existing_jails=$("$jls_bin" name) || refuse
if printf '%s\n' "$existing_jails" | grep -Fxq "$jail_name"; then refuse; fi
[ -d "$(dirname "$output_dir")" ] && [ ! -L "$(dirname "$output_dir")" ] || refuse
output_uid=$("$stat_bin" -f %u "$(dirname "$output_dir")") || refuse
case "$output_uid" in ''|*[!0-9]*) refuse ;; esac
chown_bin=${CHOWN_BIN:-chown}
sha256_bin=${SHA256_BIN:-sha256}
[ "$("$sha256_bin" -q "$base_archive")" = "$base_sha256" ] || refuse
if [ "$kind" = phoenix ] || [ "$kind" = ocaml ]; then
    [ "$("$sha256_bin" -q "$inventory")" = "$inventory_sha256" ] || refuse
fi
if [ "$kind" = ocaml ]; then
    [ "$("$sha256_bin" -q "$INFRA_OPAM_INVENTORY")" = "$INFRA_OPAM_INVENTORY_SHA256" ] || refuse
fi
jail_bin=${JAIL_BIN:-jail}
jexec_bin=${JEXEC_BIN:-jexec}
mount_bin=${MOUNT_BIN:-mount}
umount_bin=${UMOUNT_BIN:-umount}
chflags_bin=${CHFLAGS_BIN:-chflags}
script_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)

timing_operation=artifact.build
timing_root=$(dirname "$output_dir")
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
check_builder_root() {
    for path in bin/sh rescue/sh libexec/ld-elf.so.1; do
        if [ ! -f "$jroot/$path" ] || [ ! -x "$jroot/$path" ]; then
            echo "build jail: missing executable $path" >&2
            return 1
        fi
        mode=$("$stat_bin" -f %Lp "$jroot/$path") || return 1
        printf 'build jail: root %s mode=%s\n' "$path" "$mode"
    done
}

report_builder_jail() {
    echo "build jail: live $1"
    # Only query this disposable jail, never service jails or their files.
    "$jls_bin" -j "$jail_name" jid path || return 1
    diagnostic_mounts=$("$mount_bin") || return 1
    printf '%s\n' "$diagnostic_mounts" | awk -v root="$jroot" '
        $2 == "on" && ($3 == root || index($3, root "/") == 1) { print }
    '
}

probe_builder_shell() {
    report_builder_jail "$1" || return 1
    echo "build jail: checking shell $1"
    # Expanded by the static rescue shell inside the jail.
    # shellcheck disable=SC2016
    "$jexec_bin" "$jail_name" /rescue/sh -c '
        for path in /bin/sh /libexec/ld-elf.so.1; do
            if [ ! -x "$path" ]; then echo "build jail: missing executable $path" >&2; exit 1; fi
        done
        for path in /lib/libc.so.7 /lib/libedit.so.8; do
            if [ ! -r "$path" ]; then echo "build jail: missing library $path" >&2; exit 1; fi
        done
        /bin/sh -c "exit 0"
    ' || {
        probe_result=$?
        report_builder_jail shell-failed || :
        return "$probe_result"
    }
}

mkdir "$jroot" || refuse
created=1
timing_skipped image-verify-clone-mount 'cold build extracts a base'
timing_skipped receipt-material-checks 'cold build has no prepared receipt'
chmod 700 "$jroot"
timed base-extraction tar -xpf "$base_archive" -C "$jroot"
chmod 700 "$jroot"
mkdir -p "$jroot/etc" "$jroot/dev" "$jroot/work/source"
# The compute host's loopback resolver is not reachable from this disposable jail.
# This candidate-only builder uses the operator-approved public DNS address.
printf 'nameserver 1.1.1.1\n' >"$jroot/etc/resolv.conf"
chmod 644 "$jroot/etc/resolv.conf"
chmod 700 "$jroot/work" "$jroot/work/source"
if [ "$kind" = phoenix ] || [ "$kind" = ocaml ]; then
    cp -Rp "$source_dir/." "$jroot/work/source/"
    SHA256_BIN="$sha256_bin" STAT_BIN="$stat_bin" sh "$script_dir/artifact_verify_source.sh" \
        "$jroot/work/source" "$inventory" "$inventory_sha256"
    if [ "$kind" = phoenix ]; then
        cp "$script_dir/artifact_build_phoenix.sh" "$jroot/work/worker.sh"
        cp "$script_dir/artifact_build_assets.exs" "$jroot/work/build_assets.exs"
        chmod 644 "$jroot/work/build_assets.exs"
    else
        mkdir -m 700 "$jroot/work/repository"
        cp -Rp "$INFRA_OPAM_REPOSITORY/." "$jroot/work/repository/"
        SHA256_BIN="$sha256_bin" STAT_BIN="$stat_bin" sh "$script_dir/artifact_verify_source.sh" \
            "$jroot/work/repository" "$INFRA_OPAM_INVENTORY" "$INFRA_OPAM_INVENTORY_SHA256"
        if [ -n "${INFRA_WEB_BUNDLE:-}" ]; then
            mkdir -m 700 "$jroot/work/web"
            cp -Rp "$INFRA_WEB_BUNDLE/." "$jroot/work/web/"
        fi
        cp "$script_dir/artifact_build_ocaml.sh" "$jroot/work/worker.sh"
    fi
else
    cp "$script_dir/artifact_build_executable.sh" "$jroot/work/worker.sh"
fi
chmod 644 "$jroot/work/worker.sh"
attempted=1
"$jail_bin" -c "name=$jail_name" "path=$jroot" "ip4.addr=lo1|$ip/32" persist exec.clean mount.devfs
check_builder_root
probe_builder_shell before-packages
# Package-created public paths must remain searchable after dropping privileges.
# Limit the relaxed mask to bootstrap; private staging/provenance stays 0700/0600.
(umask 022; timed package-resolve-install "$jexec_bin" "$jail_name" pkg bootstrap -y)
# Keep archive provenance outside the worker-owned tree.
mkdir -p "$jroot/var/infra-build"
chmod 700 "$jroot/var/infra-build"
cp "$script_dir/artifact_resolve_packages.sh" "$jroot/var/infra-build/artifact_resolve_packages.sh"
timed package-resolve-install "$jexec_bin" "$jail_name" /rescue/sh /var/infra-build/artifact_resolve_packages.sh \
    /var/infra-build/packages /var/infra-build/dependencies "$@"
check_builder_root
probe_builder_shell after-packages
echo 'build jail: completed shell-probe'
echo 'build jail: starting abi'
target_abi=$("$jexec_bin" "$jail_name" pkg config abi) || refuse
if ! printf '%s\n' "$target_abi" | awk '
    /^FreeBSD:[0-9]+:[a-zA-Z0-9_-]+$/ { valid++ }
    END { exit !(NR == 1 && valid == 1) }
'; then refuse; fi
echo 'build jail: completed abi'
if [ "$kind" = phoenix ]; then
    echo 'build jail: starting runtime-links'
    # Expanded by the shell inside the jail, not by this host-side script.
    # shellcheck disable=SC2016
    "$jexec_bin" "$jail_name" /rescue/sh -c \
        'version=$1; for binary in /usr/local/lib/erlang"$version"/bin/*; do [ -f "$binary" ] || exit 1; ln -sf "$binary" /usr/local/bin/; done' sh "$erlang_version"
    echo 'build jail: completed runtime-links'
fi
echo 'build jail: starting builder-user'
"$jexec_bin" "$jail_name" /usr/sbin/pw useradd -n builder -d /work -s /bin/sh
echo 'build jail: completed builder-user'
# Dependency cache: one archive per app and key, where the key covers
# everything that decides the fetched and compiled dependencies. The builder
# makes and unpacks the archive inside the jail; the host only copies it.
cache_file=
if [ "$kind" = phoenix ] || [ "$kind" = ocaml ]; then
    cache_dir=${BUILD_CACHE_DIR:-/var/cache/infra-build}/$release_name
    if [ "$kind" = phoenix ]; then
        cache_inputs='mix.lock config/config.exs config/prod.exs assets/package-lock.json'
    else
        # opam installs the dependencies the project's opam files declare,
        # and dune-project may generate them.
        cache_inputs=dune-project
        for file in "$jroot"/work/source/*.opam "$jroot"/work/source/*.opam.locked; do
            [ -f "$file" ] && cache_inputs="$cache_inputs ${file##*/}"
        done
    fi
    {
        printf '%s-dependencies-v1\n%s\n' "$kind" "$target_abi"
        if [ "$kind" = ocaml ]; then
            printf 'compiler %s\nrepository %s\n' "$INFRA_OCAML_COMPILER" "$INFRA_OPAM_INVENTORY_SHA256"
        fi
        printf 'package %s\n' "$@"
        cat "$jroot/var/infra-build/dependencies"
        for file in $cache_inputs; do
            if [ -f "$jroot/work/source/$file" ]; then
                printf '%s %s\n' "$file" "$("$sha256_bin" -q "$jroot/work/source/$file")"
            else
                printf '%s absent\n' "$file"
            fi
        done
    } >"$jroot/var/infra-build/cache-key"
    cache_key=$("$sha256_bin" -q "$jroot/var/infra-build/cache-key")
    case "$cache_key" in ''|*[!0-9a-f]*) refuse ;; esac
    [ ! -L "${cache_dir%/*}" ] && [ ! -L "$cache_dir" ] || refuse
    mkdir -p "$cache_dir"
    chmod 700 "${cache_dir%/*}" "$cache_dir"
    cache_file=$cache_dir/$cache_key.tar
    if [ -f "$cache_file" ] && [ ! -L "$cache_file" ]; then
        cp "$cache_file" "$jroot/work/cache.tar"
    fi
fi
echo 'build jail: starting work-owner'
"$jexec_bin" "$jail_name" /usr/sbin/chown -R builder:builder /work
echo 'build jail: completed work-owner'
# The builder must traverse / inside the jail after dropping privileges.
# The host-side parent remains root-only (0700), protecting the private stage.
chmod 755 "$jroot"
if [ -f "$jroot/work/cache.tar" ]; then
    echo 'build jail: restoring dependency cache'
    timed dependency-cache-restore "$jexec_bin" -U builder "$jail_name" /rescue/sh -c \
        'cd /work && /usr/bin/tar -xf /work/cache.tar && rm /work/cache.tar'
fi
if [ "$kind" = ocaml ]; then
    # opam's depext detection must query pkg as this user, before compiler work.
    echo 'build jail: checking builder package access'
    "$jexec_bin" -U builder "$jail_name" /usr/local/sbin/pkg query -a '%n %v' >/dev/null
fi
echo 'build jail: starting worker'
# Keep the worker unprivileged; the rescue launcher execs the dynamic shell.
case "$kind" in
    phoenix) set -- /work/source "$release_name" /work/output /work/build_assets.exs ;;
    # An OCaml app's executable is bin/<app>.exe in its dune project; the
    # release name is the app's, also in a test jail.
    ocaml)
        set -- /work/source . "bin/$release_name.exe" "$release_name" /work/output "$INFRA_OCAML_COMPILER" /work/repository
        # Kept after the worker, so the dependency cache can save it.
        INFRA_OPAM_ROOT=/work/opam
        export INFRA_OPAM_ROOT
        if [ -n "${INFRA_WEB_BUNDLE:-}" ]; then set -- "$@" /work/web; fi ;;
    package)
        binary_sha256=$("$jexec_bin" "$jail_name" sha256 -q "/usr/local/bin/$release_name") || refuse
        set -- verified-file "/usr/local/bin/$release_name" "$binary_sha256" "$release_name" /work/output ;;
    binary) set -- download "$INFRA_EXECUTABLE_SOURCE" "$INFRA_EXECUTABLE_SHA256" "$release_name" /work/output ;;
esac
# shellcheck disable=SC2016
INFRA_PROGRESS_JSONL="${INFRA_PROGRESS_JSONL:-0}" "$jexec_bin" -U builder "$jail_name" /rescue/sh -c 'exec /bin/sh "$@"' sh /work/worker.sh "$@"
echo 'build jail: completed worker'
# Only after a successful build, and only once per key. A failed save costs
# the next build its speed, not its correctness, so it does not fail this one.
if [ -n "$cache_file" ] && [ ! -e "$cache_file" ]; then
    echo 'build jail: saving dependency cache'
    # Phoenix: the tool caches, fetched and compiled dependencies and the
    # build tools in _build. OCaml: the opam root, with the compiler and the
    # installed dependencies. Never the app's own compiled code.
    if [ "$kind" = ocaml ]; then
        cache_save='cd /work && /usr/bin/tar -cf /work/cache.tar opam'
    else
        # shellcheck disable=SC2016
        cache_save='
        cd /work
        set --
        for path in .mix .hex .npm source/deps; do [ -d "$path" ] && set -- "$@" "$path"; done
        for dep in source/deps/*; do
            lib=source/_build/prod/lib/${dep##*/}
            [ -d "$lib" ] && set -- "$@" "$lib"
        done
        for tool in source/_build/*; do
            [ "$tool" != source/_build/prod ] && [ -e "$tool" ] && set -- "$@" "$tool"
        done
        /usr/bin/tar -cf /work/cache.tar "$@"'
    fi
    if timed dependency-cache-save "$jexec_bin" -U builder "$jail_name" /rescue/sh -c "$cache_save" &&
        [ -f "$jroot/work/cache.tar" ] && [ ! -L "$jroot/work/cache.tar" ] &&
        cp "$jroot/work/cache.tar" "$cache_file.tmp" && mv "$cache_file.tmp" "$cache_file"; then
        for old in "$cache_dir"/*.tar; do [ "$old" = "$cache_file" ] || rm -f "$old"; done
    else
        rm -f "$cache_file.tmp"
        echo 'build jail: dependency cache not saved' >&2
    fi
fi
archive="$jroot/work/output/release.tar"
checksum="$jroot/work/output/release.sha256"
[ -f "$archive" ] && [ ! -L "$archive" ] && [ -f "$checksum" ] && [ ! -L "$checksum" ] || refuse
built_sha256=$(cat "$checksum")
case "$built_sha256" in *[!0-9a-f]*|'') refuse ;; esac
[ "${#built_sha256}" -eq 64 ] || refuse
[ "$("$sha256_bin" -q "$archive")" = "$built_sha256" ] || refuse
output_tmp=$(mktemp -d "${output_dir}.tmp.XXXXXXXX")
chmod 700 "$output_tmp"
cp "$archive" "$output_tmp/release.tar"
printf '%s\n' "$built_sha256" >"$output_tmp/release.sha256"
printf '%s\n' "$target_abi" >"$output_tmp/target-abi"
cp "$jroot/var/infra-build/dependencies" "$output_tmp/dependencies"
[ "$("$sha256_bin" -q "$output_tmp/release.tar")" = "$built_sha256" ] || refuse
# SSH retrieves this private output as the staging owner, not as doas root.
"$chown_bin" -R "$output_uid" "$output_tmp"
ready=1

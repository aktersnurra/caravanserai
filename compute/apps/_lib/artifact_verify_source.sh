#!/bin/sh
# Verify a transferred source tree against the locally generated inventory.
# The caller must compare INVENTORY_SHA256 with a trusted pre-transfer digest.
set -eu

refuse() { echo 'source inventory verification failed' >&2; exit 1; }
[ "$#" -eq 3 ] || refuse
root=$1
inventory=$2
expected_digest=$3
sha256_bin=${SHA256_BIN:-sha256}
stat_bin=${STAT_BIN:-stat}
case "${SHA256_KIND:-freebsd}" in freebsd|linux) ;; *) refuse ;; esac
case "${STAT_KIND:-freebsd}" in freebsd|linux) ;; *) refuse ;; esac
hash_file() {
    if [ "${SHA256_KIND:-freebsd}" = linux ]; then
        value=$("$sha256_bin" "$1") || return 1
        printf '%s\n' "${value%% *}"
    else "$sha256_bin" -q "$1"; fi
}
file_mode() (
    if [ "${STAT_KIND:-freebsd}" = linux ]; then
        raw=$("$stat_bin" -c %a "$1") || exit 1
    else
        raw=$("$stat_bin" -f %p "$1") || exit 1
    fi
    case $raw in ''|*[!0-7]*) exit 1 ;; esac
    [ "${#raw}" -le 6 ] || exit 1
    printf '%o\n' "$((0$raw & 07777))"
)
case "$expected_digest" in *[!0-9a-f]*|'') refuse ;; esac
[ "${#expected_digest}" -eq 64 ] || refuse
[ -d "$root" ] && [ ! -L "$root" ] || refuse
[ -f "$inventory" ] && [ ! -L "$inventory" ] || refuse
[ "$(hash_file "$inventory")" = "$expected_digest" ] || refuse
[ "$(file_mode "$root")" = 700 ] || refuse

temporary=$(mktemp -d "${TMPDIR:-/tmp}/infra-source.XXXXXXXX") || refuse
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
expected="$temporary/expected"
actual="$temporary/actual"
directories="$temporary/directories"
: >"$expected"
tab=$(printf '\t')
exec 3<"$inventory"
IFS= read -r header <&3 || refuse
case "$header" in "infra-source-v1${tab}"*) ;; *) refuse ;; esac
commit=${header#"infra-source-v1${tab}"}
case "$commit" in *[!0-9a-f]*|'') refuse ;; esac
[ "${#commit}" -eq 40 ] || [ "${#commit}" -eq 64 ] || refuse
previous=
while IFS= read -r line <&3; do
    case "$line" in *"$tab"*"$tab"*) ;; *) refuse ;; esac
    mode=${line%%"$tab"*}
    rest=${line#*"$tab"}
    digest=${rest%%"$tab"*}
    path=${rest#*"$tab"}
    case "$mode" in 600|700) ;; *) refuse ;; esac
    case "$digest" in *[!0-9a-f]*|'') refuse ;; esac
    [ "${#digest}" -eq 64 ] || refuse
    case "$path" in ''|/*|*[!a-zA-Z0-9._+~/-]*) refuse ;; esac
    case "/$path/" in *'//'*|*'/../'*|*'/./'*|*'/.env/'*|*'/.env.'*'/'*|*'/.env~'*'/'*) refuse ;; esac
    [ "$path" != "$previous" ] || refuse
    previous=$path
    file="$root/$path"
    [ -f "$file" ] && [ ! -L "$file" ] || refuse
    [ "$(file_mode "$file")" = "$mode" ] || refuse
    [ "$(hash_file "$file")" = "$digest" ] || refuse
    printf '%s\n' "$path" >>"$expected"
done
[ -s "$expected" ] || refuse
LC_ALL=C sort -c "$expected" >/dev/null 2>&1 || refuse
(
    cd "$root" || exit 1
    find . ! -type f ! -type d -print -quit >"$directories" || exit 1
    [ ! -s "$directories" ] || exit 1
    find . -type d -print >"$directories" || exit 1
    while IFS= read -r directory; do
        [ "$(file_mode "$directory")" = 700 ] || exit 1
    done <"$directories"
    find . -type f -print | sed 's|^./||' | LC_ALL=C sort >"$actual" || exit 1
) || refuse
cmp -s "$expected" "$actual" || refuse

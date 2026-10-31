#!/bin/sh
# Run as root in a disposable jail. Record actual archive bytes, not pkg's
# internal package checksum. Install only the fetched dependency closure.
# Usage: artifact_resolve_packages.sh NEW_CACHE NEW_INVENTORY PACKAGE...
set -eu
umask 077
fail() { printf 'package resolver: %s\n' "$1" >&2; exit 1; }
[ "$#" -ge 3 ] || exit 1
cache=$1
output=$2
shift 2
case "$cache:$output" in /*:/*) ;; *) exit 1 ;; esac
[ ! -e "$cache" ] && [ ! -L "$cache" ] || exit 1
[ ! -e "$output" ] && [ ! -L "$output" ] || exit 1
for package do
    case "$package" in ''|*[!a-zA-Z0-9._+-]*) exit 1 ;; esac
done
pkg_bin=${PKG_BIN:-/usr/local/sbin/pkg}
sha256_bin=${SHA256_BIN:-sha256}
mkdir "$cache"
"$pkg_bin" fetch -y -d -o "$cache" pkg "$@"
# pkg fetch assigns public modes independently of umask. This cache was
# created by this invocation; keep its directories and verified archives private.
find "$cache" -type d -exec chmod 700 {} +
format=$(printf '%%n\t%%v')
tmp="$output.tmp"
[ ! -e "$tmp" ] && [ ! -L "$tmp" ] || exit 1
(set -C; : >"$tmp")
[ ! -e "$tmp.sorted" ] && [ ! -L "$tmp.sorted" ] || exit 1
[ ! -e "$tmp.archives" ] && [ ! -L "$tmp.archives" ] || exit 1
trap 'rm -f "$tmp" "$tmp.sorted" "$tmp.archives"' EXIT HUP INT TERM
# Current pkg mirrors repository paths (including Hashed/); do not assume
# the All/ layout described by older pkg-fetch documentation.
find "$cache" -type f \( -name '*.pkg' -o -name '*.txz' \) -print >"$tmp.archives"
set --
while IFS= read -r archive; do
    [ -f "$archive" ] && [ ! -L "$archive" ] || fail 'unsafe package archive'
    chmod 600 "$archive"
    metadata=$("$pkg_bin" query -F "$archive" "$format") || fail "cannot query ${archive##*/}"
    printf '%s\n' "$metadata" | awk -F '\t' '
        NF != 2 || $1 !~ /^[a-zA-Z0-9._+-]+$/ || $2 !~ /^[a-zA-Z0-9._+:,-]+$/ { bad = 1 }
        END { exit (NR != 1 || bad) }
    ' || fail "invalid metadata in ${archive##*/}"
    digest=$("$sha256_bin" -q "$archive")
    case "$digest" in ''|*[!0-9a-f]*) exit 1 ;; esac
    [ "${#digest}" = 64 ] || exit 1
    printf '%s\t%s\n' "$metadata" "$digest" >>"$tmp"
    set -- "$@" "$archive"
done <"$tmp.archives"
[ "$#" -gt 0 ] || fail 'no package archives found under fetched directory'
awk -F '\t' 'seen[$1]++ { bad = 1 } END { exit bad }' "$tmp" || fail 'duplicate package archive'
printf 'package resolver: installing %s verified archives\n' "$#"
# pkg add resolves dependencies from this directory, without re-resolving
# against a possibly changed repository catalogue. Force the resolved pkg
# archive too: bootstrap may already have installed the same version.
# Only public package installation gets this mask, never cache or receipts.
(umask 022; "$pkg_bin" add -f "$@")
for archive do
    metadata=$("$pkg_bin" query -F "$archive" "$format")
    name=${metadata%%"$(printf '\t')"*}
    installed=$("$pkg_bin" query "$format" "$name")
    [ "$installed" = "$metadata" ] || fail "installed version mismatch: $name"
    digest=$("$sha256_bin" -q "$archive")
    record=$(printf '%s\t%s' "$metadata" "$digest")
    grep -Fxq "$record" "$tmp" || fail "archive changed during install: $name"
done
(set -C; LC_ALL=C sort "$tmp" >"$tmp.sorted")
mv "$tmp.sorted" "$output"
rm "$tmp" "$tmp.archives"
trap - EXIT HUP INT TERM
printf 'package resolver: dependency inventory verified\n'

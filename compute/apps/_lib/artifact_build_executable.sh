#!/bin/sh
# Build a FreeBSD amd64 executable payload without installing or starting it.
# MODE SOURCE EXPECTED_BINARY_SHA256 RELEASE OUTPUT
# verified-file is a file from the caller's verified package closure; download
# is the declaration's pinned HTTPS upstream binary. Neither is a source commit.
set -eu
mode=${1:?mode required}
source=${2:?input required}
expected=${3:?binary SHA-256 required}
release=${4:?release name required}
output=${5:?output required}
refuse() { echo 'executable worker: invalid or unsafe input' >&2; exit 1; }
case "$expected" in ''|*[!0-9a-f]*) refuse ;; esac
[ "${#expected}" -eq 64 ] || refuse
case "$release" in ''|-*|*[!a-z0-9_-]*) refuse ;; esac
[ "${#release}" -le 128 ] || refuse
case "$output" in /*) ;; *) refuse ;; esac
[ ! -e "$output" ] && [ ! -L "$output" ] || refuse
case "$mode" in
    verified-file)
        case "$source" in /*) ;; *) refuse ;; esac
        [ -f "$source" ] && [ ! -L "$source" ] || refuse ;;
    download)
        case "$source" in https://?*) ;; *) refuse ;; esac
        case "$source" in *[!a-zA-Z0-9/.:_+-]*) refuse ;; esac ;;
    *) refuse ;;
esac
umask 077
stage=$output.tmp.$$
mkdir "$stage"
trap 'rm -rf "$stage"' EXIT
trap 'exit 1' HUP INT TERM
mkdir -p "$stage/payload/bin" "$stage/result"
binary=$stage/payload/bin/$release
case "$mode" in
    verified-file) cp "$source" "$binary" ;;
    download) fetch -o "$binary" "$source" ;;
esac
[ -f "$binary" ] && [ ! -L "$binary" ] || refuse
[ "$(sha256 -q "$binary")" = "$expected" ] || refuse
[ "$(wc -c <"$binary")" -ge 64 ] || refuse
# Check the actual ELF header, not filename or a platform URL label. Pocket ID
# is static, so ldd's non-dynamic exit is not an OS/architecture test.
header=$(od -An -tu1 -N20 "$binary")
# All header characters are decimal bytes and whitespace produced by od.
# shellcheck disable=SC2086
set -- $header
[ "$#" -eq 20 ] || refuse
[ "$1 $2 $3 $4 $5 $6 $7 $8" = '127 69 76 70 2 1 1 9' ] || refuse
shift 16
case "$1 $2 $3 $4" in '2 0 62 0'|'3 0 62 0') ;; *) refuse ;; esac
chmod 755 "$binary"
tar -cf "$stage/result/release.tar" -C "$stage/payload" .
sha256 -q "$stage/result/release.tar" >"$stage/result/release.sha256"
printf '%s\n' "$expected" >"$stage/result/binary.sha256"
mv "$stage/result" "$output"

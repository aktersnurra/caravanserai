#!/bin/sh
# Install a verified Phoenix release into a versioned directory in one jail.
# The host-side serai lock must be held by the caller. This script only stages
# a release; it never changes /opt/<app> or stops/starts a service. APP names
# the in-jail paths; it differs from JAIL only in a test jail.
# Usage: artifact_install.sh JAIL IDENTITY ARCHIVE SHA256 APP
set -eu

jail=${1:?jail required}
identity=${2:?artifact identity required}
archive=${3:?archive required}
expected=${4:?SHA-256 required}
app=${5:?app required}

safe_component() {
    case "$1" in
        ''|.|..|*[!a-zA-Z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

safe_component "$jail" && safe_component "$identity" && safe_component "$app" || {
    echo 'invalid jail, app or artifact identity' >&2
    exit 1
}
[ "${#jail}" -le 128 ] && [ "${#identity}" -le 128 ] && [ "${#app}" -le 128 ] || {
    echo 'jail, app or artifact identity is too long' >&2
    exit 1
}
case "$expected" in
    *[!0-9a-fA-F]*|'') echo 'invalid SHA-256' >&2; exit 1 ;;
esac
[ "${#expected}" -eq 64 ] || { echo 'invalid SHA-256 length' >&2; exit 1; }
[ -f "$archive" ] && [ ! -L "$archive" ] || { echo 'archive must be a regular file' >&2; exit 1; }

sha256_bin=${SHA256_BIN:-sha256}
actual=$("$sha256_bin" -q "$archive")
[ "$actual" = "$expected" ] || { echo 'artifact SHA-256 mismatch' >&2; exit 1; }

# The archive is produced by the trusted build jail. Still refuse obviously
# unsafe names and the metadata path reserved by the installer.
tar -tf "$archive" | awk '
    /^\// || /(^|\/)\.\.(\/|$)/ || /(^|\/)\.infra-sha256$/ || /[[:cntrl:]]/ { bad = 1 }
    END { exit bad }
' || { echo 'unsafe artifact archive entry' >&2; exit 1; }

# This adapter accepts only file/directory Phoenix payloads. The native verified
# candidate contains no links. Refuse links/devices before root extraction:
# a valid digest alone does not make an escaping link safe to unpack.
tar -tvf "$archive" | awk '
    substr($0, 1, 1) != "-" && substr($0, 1, 1) != "d" { bad = 1 }
    END { exit bad }
' || { echo 'unsupported artifact archive entry type' >&2; exit 1; }

jroot=${JAIL_ROOT:-/jails/$jail}
release_root="$jroot/opt/.infra-releases/$app"
target="$release_root/$identity"
umask 022
[ -d "$jroot/opt" ] && [ ! -L "$jroot/opt" ] || {
    echo 'jail opt directory is missing or is a symlink' >&2
    exit 1
}
[ ! -L "$jroot/opt/.infra-releases" ] || { echo 'artifact directory is a symlink' >&2; exit 1; }
[ ! -L "$release_root" ] || { echo 'release root is a symlink' >&2; exit 1; }
mkdir -p "$release_root"

if [ -e "$target" ] || [ -L "$target" ]; then
    [ -d "$target" ] && [ ! -L "$target" ] &&
        [ "$(cat "$target/.infra-sha256" 2>/dev/null || :)" = "$expected" ] || {
        echo 'artifact identity already contains another release' >&2
        exit 1
    }
    echo "release already installed: $target"
    exit 0
fi

tmp=$(mktemp -d "$release_root/.install.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
tar -xf "$archive" -C "$tmp"
printf '%s\n' "$expected" >"$tmp/.infra-sha256"
chown_bin=${CHOWN_BIN:-chown}
"$chown_bin" -R root:wheel "$tmp"
# Build stages use umask 077. Runtime code contains no secrets/config and must
# be traversable/readable by the service account after root takes ownership.
# Preserve executable bits without making every regular data file executable.
chmod -R u=rwX,go=rX "$tmp"
mv "$tmp" "$target"
trap - EXIT HUP INT TERM
echo "release installed: $target"

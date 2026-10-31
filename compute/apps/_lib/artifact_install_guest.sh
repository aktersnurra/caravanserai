#!/bin/sh
# Stage a guest workload's verified immutable release on Linux; no
# unit/config/state changes.
# RELEASE GROUP IDENTITY ARCHIVE ARCHIVE_SHA. Must run as root on the native target.
set -eu
release=${1:?}; group=${2:?}; identity=${3:?}; archive=${4:?}; expected=${5:?}
fail() { echo "guest artifact installation: $*" >&2; exit 1; }
case "$release" in [a-z]*) ;; *) fail 'invalid release name' ;; esac
case "$group" in [a-z_]*) ;; *) fail 'invalid service group' ;; esac
case "$release:$group" in *[!a-z0-9_:-]*) fail 'invalid release name or service group' ;; esac
case "$identity:$expected" in *[!0-9a-f:]*) fail 'invalid digests' ;; esac
[ "${#identity}" = 64 ] && [ "${#expected}" = 64 ] || fail 'invalid digest length'
[ -f "$archive" ] && [ ! -L "$archive" ] || fail 'archive must be regular'
value=$(sha256sum "$archive") || fail 'archive checksum failed'
[ "${value%% *}" = "$expected" ] || fail 'archive digest mismatch'
# Capture and check tar exit status before parsing: a pipeline could hide errors.
names=$(tar -tf "$archive") || fail 'archive name listing failed'
printf '%s\n' "$names" | awk '
 /^\// || /(^|\/)\.\.(\/|$)/ || /(^|\/)\.infra-sha256$/ || /[^a-zA-Z0-9_.+\/-]/ { bad=1 }
 { name=$0; if (name=="." || name=="./") next; sub(/^\.\//,"",name); if (name !~ /^(bin|\.infra-build)(\/|$)/) bad=1 }
 END {exit bad}' || fail 'unsafe archive name'
entries=$(tar -tvf "$archive") || fail 'archive metadata listing failed'
printf '%s\n' "$entries" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {bad=1} END{exit bad}' || fail 'unsupported archive entry type'
root=${GUEST_ROOT:-/}; root=${root%/}
release_root=$root/opt/.infra-releases/$release
target=$release_root/$identity
[ -d "$root/opt" ] && [ ! -L "$root/opt" ] || fail 'missing or redirected opt directory'
for path in "$root/opt/.infra-releases" "$release_root"; do
 [ ! -L "$path" ] || fail 'redirected release root'
 if [ -e "$path" ]; then [ -d "$path" ] || fail 'occupied release root'; fi
done
umask 027
mkdir -p "$release_root"
chown_bin=${CHOWN_BIN:-chown}
"$chown_bin" "root:$group" "$root/opt/.infra-releases" "$release_root"
chmod 750 "$root/opt/.infra-releases" "$release_root"
if [ -e "$target" ] || [ -L "$target" ]; then
 [ -d "$target" ] && [ ! -L "$target" ] && [ -f "$target/.infra-sha256" ] && [ ! -L "$target/.infra-sha256" ] \
  && [ "$(cat "$target/.infra-sha256")" = "$expected" ] || fail 'occupied artifact identity'
 echo "$release release already installed: $identity"; exit 0
fi
tmp=$(mktemp -d "$release_root/.install.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
tar --no-same-owner --no-same-permissions -xf "$archive" -C "$tmp" || fail 'archive extraction failed'
[ -f "$tmp/bin/$release" ] && [ ! -L "$tmp/bin/$release" ] && [ -x "$tmp/bin/$release" ] || fail 'missing executable'
printf '%s\n' "$expected" >"$tmp/.infra-sha256"
"$chown_bin" -R "root:$group" "$tmp"
chmod -R u=rwX,g=rX,o= "$tmp"
mv -T "$tmp" "$target"
trap - EXIT HUP INT TERM
echo "$release release installed: $identity"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/jail/opt" "$TMP/input/bin" "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' >"$TMP/input/bin/demo"
chmod 0755 "$TMP/input/bin/demo"
printf 'public release bytes\n' >"$TMP/input/bin/runtime-data"
chmod 0700 "$TMP/input/bin"
chmod 0600 "$TMP/input/bin/runtime-data"
tar -cf "$TMP/release.tar" -C "$TMP/input" bin
cat >"$TMP/bin/sha256" <<'EOF'
#!/bin/sh
[ "$1" = -q ] || exit 1
sha256sum "$2" | awk '{ print $1 }'
EOF
chmod +x "$TMP/bin/sha256"
sha=$(sha256sum "$TMP/release.tar" | awk '{ print $1 }')
installer="$ROOT/compute/apps/_lib/artifact_install.sh"

# A test jail installs under the app's own name.
JAIL_ROOT="$TMP/jail" SHA256_BIN="$TMP/bin/sha256" CHOWN_BIN=true \
    sh "$installer" demotest rev1 "$TMP/release.tar" "$sha" demo >/dev/null
target="$TMP/jail/opt/.infra-releases/demo/rev1"
test -x "$target/bin/demo"
test "$(stat -c '%a' "$target")" = 755
test "$(stat -c '%a' "$target/bin")" = 755
test "$(stat -c '%a' "$target/bin/runtime-data")" = 644
test "$(cat "$target/.infra-sha256")" = "$sha"

# Reinstalling the same artifact must leave the existing release in place.
printf 'sentinel\n' >"$target/sentinel"
JAIL_ROOT="$TMP/jail" SHA256_BIN="$TMP/bin/sha256" CHOWN_BIN=true \
    sh "$installer" demo rev1 "$TMP/release.tar" "$sha" demo >/dev/null
test "$(cat "$target/sentinel")" = sentinel

if JAIL_ROOT="$TMP/jail" SHA256_BIN="$TMP/bin/sha256" CHOWN_BIN=true \
    sh "$installer" demo rev2 "$TMP/release.tar" "$(printf '%064d' 0)" demo >/dev/null 2>&1; then
    echo 'accepted a checksum mismatch' >&2; exit 1
fi
test ! -e "$TMP/jail/opt/.infra-releases/demo/rev2"

if JAIL_ROOT="$TMP/jail" SHA256_BIN="$TMP/bin/sha256" CHOWN_BIN=true \
    sh "$installer" demo ../escape "$TMP/release.tar" "$sha" demo >/dev/null 2>&1; then
    echo 'accepted a path escape' >&2; exit 1
fi
test ! -e "$TMP/jail/opt/.infra-releases/escape"
if JAIL_ROOT="$TMP/jail" SHA256_BIN="$TMP/bin/sha256" CHOWN_BIN=true \
    sh "$installer" demo rev3 "$TMP/release.tar" "$sha" .. >/dev/null 2>&1; then
    echo 'accepted an app path escape' >&2; exit 1
fi
test ! -e "$TMP/jail/opt/rev3"

printf 'other\n' >"$target/.infra-sha256"
if JAIL_ROOT="$TMP/jail" SHA256_BIN="$TMP/bin/sha256" CHOWN_BIN=true \
    sh "$installer" demo rev1 "$TMP/release.tar" "$sha" demo >/dev/null 2>&1; then
    echo 'accepted an artifact identity collision' >&2; exit 1
fi

test ! -e "$TMP/jail/opt/demo"
# Even a correctly hashed archive must not install links or special files.
mkdir -p "$TMP/unsafe"
ln -s "$TMP/jail/opt" "$TMP/unsafe/redirect"
tar -cf "$TMP/unsafe.tar" -C "$TMP/unsafe" redirect
unsafe_sha=$(sha256sum "$TMP/unsafe.tar" | awk '{ print $1 }')
if JAIL_ROOT="$TMP/jail" SHA256_BIN="$TMP/bin/sha256" CHOWN_BIN=true \
    sh "$installer" demo unsafe "$TMP/unsafe.tar" "$unsafe_sha" demo >/dev/null 2>&1; then
    echo 'accepted an archive symlink' >&2; exit 1
fi
test ! -e "$TMP/jail/opt/.infra-releases/demo/unsafe"
echo 'ok - verified artifact install is versioned, idempotent, and leaves active release untouched'

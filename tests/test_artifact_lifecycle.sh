#!/usr/bin/env bash
# Run the real jail-side transaction/install/activation/conversion helpers.
# Only FreeBSD command/network boundaries are faked; archives and renames are real.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/jail/opt" "$TMP/jail/var/db/demo" "$TMP/jail/usr/local/etc"
printf 'mutable database fixture\n' >"$TMP/jail/var/db/demo/state"
printf 'synthetic external config fixture\n' >"$TMP/jail/usr/local/etc/demo.env"
chmod 640 "$TMP/jail/usr/local/etc/demo.env"
config_metadata=$(stat -c '%i:%s:%Y:%a' "$TMP/jail/usr/local/etc/demo.env")
a=$(printf 'a%.0s' {1..64}); b=$(printf 'b%.0s' {1..64}); c=$(printf 'c%.0s' {1..64})
for version in a b c; do
 mkdir -p "$TMP/$version/bin" "$TMP/$version/lib" "$TMP/$version/releases"
 printf '#!/bin/sh\nexit 0\n' >"$TMP/$version/bin/demo_release"
 chmod 755 "$TMP/$version/bin/demo_release"
 printf 'public code %s\n' "$version" >"$TMP/$version/lib/code"
 tar -cf "$TMP/$version.tar" -C "$TMP/$version" .
done
sha_a=$(sha256sum "$TMP/a.tar" | awk '{print $1}')
sha_b=$(sha256sum "$TMP/b.tar" | awk '{print $1}')
sha_c=$(sha256sum "$TMP/c.tar" | awk '{print $1}')
cat >"$TMP/bin/sha256" <<'EOF'
#!/bin/sh
[ "$1" = -q ] || exit 1
sha256sum "$2" | awk '{print $1}'
EOF
cat >"$TMP/bin/chown" <<'EOF'
#!/bin/sh
[ "$1" = -R ] && [ "$2" = root:wheel ]
EOF
cat >"$TMP/bin/mv" <<'EOF'
#!/bin/sh
if [ "$1" = -fh ]; then shift; exec mv -fT "$@"; fi
exec mv "$@"
EOF
cat >"$TMP/bin/stat" <<'EOF'
#!/bin/sh
[ "$1" != --version ] || exit 1
case "$2" in
 '%u:%l') printf '0:%s\n' "$(/usr/bin/stat -c %h "$3")" ;;
 *) printf '0:700\n' ;;
esac
EOF
cat >"$TMP/bin/jexec" <<'EOF'
#!/bin/sh
[ "${JAIL-unset}" = unset ] || exit 99
case "$*" in
 'demo pkg config abi') printf 'abi\n' >>"$EVENTS"; printf '%s\n' "${ABI:-FreeBSD:14:amd64}" ;;
 'demo service demo_release stop') printf 'stop\n' >>"$EVENTS"; rm -f "$RUNNING" ;;
 'demo service demo_release status') printf 'status\n' >>"$EVENTS"; test -f "$RUNNING" ;;
 'demo service demo_release start') printf 'start\n' >>"$EVENTS"; test "${FAIL_START:-0}" = 0 || exit 1; touch "$RUNNING" ;;
 'idp pkg config abi') printf 'abi\n' >>"$EVENTS"; printf 'FreeBSD:14:amd64\n' ;;
 'idp service idp stop') printf 'stop\n' >>"$EVENTS"; rm -f "$RUNNING" ;;
 'idp service idp status') printf 'status\n' >>"$EVENTS"; test -f "$RUNNING" ;;
 'idp service idp start') printf 'start\n' >>"$EVENTS"; touch "$RUNNING" ;;
 *) exit 1 ;;
esac
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
printf 'check\n' >>"$EVENTS"
[ "${FAIL_CHECK:-0}" = 0 ] && [ -f "$RUNNING" ]
EOF
chmod +x "$TMP/bin/"*
export EVENTS="$TMP/events" RUNNING="$TMP/running"
apply() {
 INFRA_LOCK_HELD=1 JAIL_ROOT="$TMP/jail" JEXEC_BIN="$TMP/bin/jexec" \
 CURL_BIN="$TMP/bin/curl" MV_BIN="$TMP/bin/mv" SHA256_BIN="$TMP/bin/sha256" \
 CHOWN_BIN="$TMP/bin/chown" STAT_BIN="$TMP/bin/stat" \
 sh "$ROOT/compute/apps/_lib/artifact_apply.sh" "$1" demo "$2" "$3" "$4" demo_release \
 http://10.40.0.200:4000/ FreeBSD:14:amd64 - - demo
}
: >"$EVENTS"
if ABI=FreeBSD:15:amd64 apply upgrade "$a" "$sha_a" "$TMP/a.tar" >"$TMP/error" 2>&1; then exit 1; fi
test "$(cat "$EVENTS")" = abi
test ! -e "$TMP/jail/opt/.infra-releases"
: >"$EVENTS"
apply upgrade "$a" "$sha_a" "$TMP/a.tar" >/dev/null
test "$(readlink "$TMP/jail/opt/demo")" = ".infra-releases/demo/$a"
test "$(cat "$EVENTS")" = $'abi\nstart\ncheck'
: >"$EVENTS"
apply upgrade "$b" "$sha_b" "$TMP/b.tar" >/dev/null
test "$(cat "$EVENTS")" = $'abi\nstop\nstatus\nstart\ncheck'
test "$(readlink "$TMP/jail/opt/.infra-releases/demo/.previous")" = "$a"
: >"$EVENTS"
apply upgrade "$b" "$sha_b" "$TMP/b.tar" >/dev/null
test "$(cat "$EVENTS")" = $'abi\nstatus\ncheck'
: >"$EVENTS"
if FAIL_CHECK=1 apply upgrade "$c" "$sha_c" "$TMP/c.tar" >"$TMP/error" 2>&1; then exit 1; fi
test "$(readlink "$TMP/jail/opt/demo")" = ".infra-releases/demo/$c"
test "$(readlink "$TMP/jail/opt/.infra-releases/demo/.previous")" = "$b"
: >"$EVENTS"
if apply rollback "$a" "$sha_a" "$TMP/a.tar" >"$TMP/error" 2>&1; then exit 1; fi
test "$(cat "$EVENTS")" = abi
apply rollback "$b" "$sha_b" "$TMP/b.tar" >/dev/null
test "$(readlink "$TMP/jail/opt/demo")" = ".infra-releases/demo/$b"
test "$(readlink "$TMP/jail/opt/.infra-releases/demo/.previous")" = "$c"
# Phoenix conversion ended with drill's adoption: refused before the ABI
# probe or any install.
: >"$EVENTS"
if apply convert "$a" "$sha_a" "$TMP/a.tar" >"$TMP/error" 2>&1; then exit 1; fi
grep -Fq 'conversion is for executables only' "$TMP/error"
test ! -s "$EVENTS"
test "$(readlink "$TMP/jail/opt/demo")" = ".infra-releases/demo/$b"
test "$(cat "$TMP/jail/var/db/demo/state")" = 'mutable database fixture'
test "$(stat -c '%i:%s:%Y:%a' "$TMP/jail/usr/local/etc/demo.env")" = "$config_metadata"
test "$(find "$TMP/jail/opt" -name '.install.*' -o -name '.switch.*' | wc -l)" -eq 0
# Binary archives use a stable rc/anchor name distinct from the launcher.
mkdir -p "$TMP/jail/usr/local/bin" "$TMP/pocket-a/bin" "$TMP/pocket-b/bin"
for version in a b; do
 printf '#!/bin/sh\n# public executable %s\nexit 0\n' "$version" >"$TMP/pocket-$version/bin/idp"
 chmod 755 "$TMP/pocket-$version/bin/idp"
 tar -cf "$TMP/pocket-$version.tar" -C "$TMP/pocket-$version" .
done
cp "$TMP/pocket-a/bin/idp" "$TMP/jail/usr/local/bin/idp"
pa_sha=$(sha256sum "$TMP/pocket-a.tar" | awk '{print $1}')
pb_sha=$(sha256sum "$TMP/pocket-b.tar" | awk '{print $1}')
apply_binary() {
 INFRA_LOCK_HELD=1 JAIL_ROOT="$TMP/jail" JEXEC_BIN="$TMP/bin/jexec" \
 CURL_BIN="$TMP/bin/curl" MV_BIN="$TMP/bin/mv" SHA256_BIN="$TMP/bin/sha256" \
 CHOWN_BIN="$TMP/bin/chown" STAT_BIN="$TMP/bin/stat" \
 sh "$ROOT/compute/apps/_lib/artifact_apply.sh" "$1" idp "$2" "$3" "$4" idp \
 http://10.40.0.5:1411/ FreeBSD:14:amd64 /usr/local/bin/idp - idp
}
apply_binary convert "$a" "$pa_sha" "$TMP/pocket-a.tar" >/dev/null
: >"$EVENTS"
if ! apply_binary upgrade "$b" "$pb_sha" "$TMP/pocket-b.tar" >"$TMP/binary-result" 2>&1; then
 echo 'FAIL - binary activation must invoke rc idp, not launcher idp' >&2; exit 1
fi
test "$(cat "$EVENTS")" = $'abi\nstop\nstatus\nstart\ncheck'
test "$(readlink "$TMP/jail/opt/idp")" = ".infra-releases/idp/$b"
apply_binary rollback "$a" "$pa_sha" "$TMP/pocket-a.tar" >/dev/null
test "$(readlink "$TMP/jail/opt/idp")" = ".infra-releases/idp/$a"
test "$(readlink "$TMP/jail/usr/local/bin/idp")" = /opt/idp/bin/idp
echo 'ok - real Phoenix/binary archive/install/switch/reuse/failure/rollback and binary conversion path preserves external state/config'

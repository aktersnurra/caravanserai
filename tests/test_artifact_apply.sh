#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/jail/opt/.infra-releases/demo" "$TMP/jail/var/db/demo"
printf 'state stays here\n' >"$TMP/jail/var/db/demo/state"
id=$(printf 'a%.0s' {1..64})
cat >"$TMP/bin/jexec" <<'EOF'
#!/bin/sh
[ "${JAIL-unset}" = unset ] || exit 99
if [ "$2 $3 $4" = 'pkg config abi' ]; then printf '%s\n' "${ABI:-FreeBSD:15:amd64}"; exit 0; fi
exit 1
EOF
# Test the real transaction wrapper; installer/activator get independent shell
# fixtures so their call order, lock propagation and rollback guards are visible.
mkdir "$TMP/scripts"
cat >"$TMP/scripts/artifact_install.sh" <<'EOF'
#!/bin/sh
[ "$SERAI_LOCK_HELD" = 1 ] || exit 1
printf 'install %s %s %s\n' "$1" "$5" "$6" >>"$EVENTS"
EOF
cat >"$TMP/scripts/artifact_activate.sh" <<'EOF'
#!/bin/sh
[ "$SERAI_LOCK_HELD" = 1 ] || exit 1
printf 'activate %s %s %s %s\n' "$1" "$4" "$7" "$8" >>"$EVENTS"
EOF
chmod +x "$TMP/bin/jexec"
export EVENTS="$TMP/events"
run() {
 SERAI_LOCK_HELD="${SERAI_LOCK_HELD:-1}" JAIL_ROOT="$TMP/jail" JEXEC_BIN="$TMP/bin/jexec" \
 sh "$TMP/scripts/artifact_apply.sh" "$1" "${RUN_JAIL:-demo}" "$id" "$(printf 'b%.0s' {1..64})" \
 "$TMP/archive" demo http://10.40.0.200:4000/ FreeBSD:15:amd64 "${ANCHOR:--}" "${MIGRATE:--}" demo "${SOURCE:--}"
}
cp "$ROOT/compute/apps/_lib/artifact_apply.sh" "$TMP/scripts/"
printf 'archive\n' >"$TMP/archive"
run upgrade
test "$(cat "$EVENTS")" = $'install demo demo -\nactivate demo demo - demo'
: >"$EVENTS"
# The source commit a release was built from reaches the installer.
SOURCE=$(printf 'c%.0s' {1..40}) run upgrade
test "$(cat "$EVENTS")" = "install demo demo $(printf 'c%.0s' {1..40})"$'\nactivate demo demo - demo'
: >"$EVENTS"
MIGRATE=migrate run upgrade
test "$(cat "$EVENTS")" = $'install demo demo -\nactivate demo demo migrate demo'
: >"$EVENTS"
if MIGRATE=bogus run upgrade >"$TMP/error" 2>&1; then exit 1; fi
test ! -s "$EVENTS"
if ABI=Linux:x86_64 run upgrade >"$TMP/error" 2>&1; then exit 1; fi
test ! -s "$EVENTS"
if SERAI_LOCK_HELD=0 run upgrade >"$TMP/error" 2>&1; then exit 1; fi
test ! -s "$EVENTS"
if run rollback >"$TMP/error" 2>&1; then exit 1; fi
test ! -s "$EVENTS"
ln -s "$id" "$TMP/jail/opt/.infra-releases/demo/.previous"
run rollback
test "$(cat "$EVENTS")" = $'install demo demo -\nactivate demo demo - demo'
: >"$EVENTS"
# A missing anchor is legacy beside an /opt/demo directory or in a rollback,
# and so is any anchor that is not the managed link.
mkdir -p "$TMP/jail/usr/local/bin" "$TMP/jail/opt/demo"
if ANCHOR=/usr/local/bin/demo run upgrade >"$TMP/error" 2>&1; then exit 1; fi
test ! -s "$EVENTS"
rmdir "$TMP/jail/opt/demo"
if ANCHOR=/usr/local/bin/demo run rollback >"$TMP/error" 2>&1; then exit 1; fi
test ! -s "$EVENTS"
printf 'legacy binary\n' >"$TMP/jail/usr/local/bin/demo"
if ANCHOR=/usr/local/bin/demo run upgrade >"$TMP/error" 2>&1; then exit 1; fi
test ! -s "$EVENTS"
rm "$TMP/jail/usr/local/bin/demo"
# The first activation of a new jail creates it.
ANCHOR=/usr/local/bin/demo run upgrade
test "$(readlink "$TMP/jail/usr/local/bin/demo")" = /opt/demo/bin/demo
test "$(cat "$EVENTS")" = $'install demo demo -\nactivate demo demo - demo'
: >"$EVENTS"
JAIL=must-not-leak ANCHOR=/usr/local/bin/demo run upgrade
test "$(cat "$EVENTS")" = $'install demo demo -\nactivate demo demo - demo'
test "$(cat "$TMP/jail/var/db/demo/state")" = 'state stays here'
# In the test jail demotest the anchor, the executable's service and every
# path stay the app's; only the jexec target changes. Conversion is refused.
: >"$EVENTS"
RUN_JAIL=demotest ANCHOR=/usr/local/bin/demo run upgrade
test "$(cat "$EVENTS")" = $'install demotest demo -\nactivate demotest demo - demo'
: >"$EVENTS"
if RUN_JAIL=demotest run convert >"$TMP/error" 2>&1; then exit 1; fi
grep -Fq 'conversion is for live jails only' "$TMP/error"
test ! -s "$EVENTS"
echo 'ok - one locked transaction checks ABI, executable anchor and explicit rollback before installation/activation, which receives migrate'

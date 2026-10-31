#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
activator="$ROOT/compute/apps/_lib/artifact_activate.sh"
a=$(printf 'a%.0s' {1..64})
b=$(printf 'b%.0s' {1..64})
c=$(printf 'd%.0s' {1..64})
sha=$(printf 'c%.0s' {1..64})
mkdir -p "$TMP/jail/opt/.infra-releases/demo" "$TMP/bin" "$TMP/jail/var/db/demo"
install_release() {
    dir="$TMP/jail/opt/.infra-releases/demo/$1"
    mkdir -p "$dir/bin"
    printf '#!/bin/sh\nexit 0\n' >"$dir/bin/demo"
    chmod 0755 "$dir/bin/demo"
    printf '%s\n' "$sha" >"$dir/.infra-sha256"
}
install_release "$a"
printf 'mutable marker\n' >"$TMP/jail/var/db/demo/marker"
cat >"$TMP/bin/jexec" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$EVENTS"
[ "${JAIL-unset}" = unset ] || exit 99
case "$*" in
    *' stop')
        [ "${DELAY_STOP:-0}" != 1 ] || printf '2\n' >"$EVENTS.remaining"
        [ "${FAIL_STOP:-0}" = 0 ] ;;
    *' start') [ "${FAIL_START:-0}" = 0 ] ;;
    *' migrate') [ "${FAIL_MIGRATE:-0}" = 0 ] ;;
    *' status')
        [ "${UNKNOWN_STATUS:-0}" = 0 ] || exit 2
        if [ "${DELAY_STOP:-0}" = 1 ]; then
            left=$(cat "$EVENTS.remaining")
            [ "$left" -gt 0 ] || exit 1
            printf '%s\n' "$((left - 1))" >"$EVENTS.remaining"
            exit 0
        fi
        [ "${STILL_RUNNING:-0}" = 1 ] ;;
esac
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
printf 'check\n' >>"$EVENTS"
case "$*" in *'--retry 5 --retry-connrefused --retry-delay 1 --retry-max-time 30'*) ;; *) exit 97 ;; esac
[ "${FAIL_CHECK:-0}" = 0 ]
EOF
cat >"$TMP/bin/sleep" <<'EOF'
#!/bin/sh
[ "$1" = 1 ] || exit 99
EOF
# FreeBSD mv -h is GNU mv -T: whichever this system has, both perform a real
# rename over a destination symlink rather than moving into its directory.
cat >"$TMP/bin/mv" <<'EOF'
#!/bin/sh
[ "$1" = -fh ] || exit 98
shift
if mv --version >/dev/null 2>&1; then exec mv -fT "$@"; fi; exec mv -fh "$@"
EOF
chmod +x "$TMP/bin/"*
# A refused attempt that a retry recovers from prints nothing; a failed
# check prints only curl's last error.
cat >"$TMP/retrying-curl" <<'EOF'
#!/bin/sh
echo 'curl: (7) refused' >&2
echo 'curl: (7) refused' >&2
[ "${FAIL_CHECK:-0}" = 0 ] || { echo 'curl: (22) returned error: 503' >&2; exit 22; }
EOF
chmod +x "$TMP/retrying-curl"
CURL_BIN="$TMP/retrying-curl" sh "$ROOT/compute/apps/_lib/artifact_check_health.sh" http://127.0.0.1:1/ 2>"$TMP/health-err"
test ! -s "$TMP/health-err"
if FAIL_CHECK=1 CURL_BIN="$TMP/retrying-curl" sh "$ROOT/compute/apps/_lib/artifact_check_health.sh" http://127.0.0.1:1/ 2>"$TMP/health-err"; then
    echo 'FAIL - a failed health check passed' >&2; exit 1
fi
test "$(cat "$TMP/health-err")" = 'curl: (22) returned error: 503'
export EVENTS="$TMP/events"
activate() {
    JAIL_ROOT="$TMP/jail" JEXEC_BIN="$TMP/bin/jexec" CURL_BIN="$TMP/bin/curl" \
        MV_BIN="$TMP/bin/mv" SLEEP_BIN="$TMP/bin/sleep" sh "$activator" demo "$1" "$sha" demo demo http://10.40.0.200:4000/ "${MIGRATE:--}" demo
}
# Activation in the test jail demotest: jexec targets it, every path is the app's.
activate_test_jail() {
    JAIL_ROOT="$TMP/jail" JEXEC_BIN="$TMP/bin/jexec" CURL_BIN="$TMP/bin/curl" \
        MV_BIN="$TMP/bin/mv" SLEEP_BIN="$TMP/bin/sleep" sh "$activator" demotest "$1" "$sha" demo demo http://10.40.0.200:4000/ - demo
}
refused() {
    : >"$EVENTS"
    if activate "$1" >/dev/null 2>&1; then echo "accepted $2" >&2; exit 1; fi
    test ! -s "$EVENTS"
}
activate "$a" >/dev/null
test "$(readlink "$TMP/jail/opt/demo")" = ".infra-releases/demo/$a"
test "$(cat "$EVENTS")" = $'demo service demo start\ncheck'
test ! -e "$TMP/jail/opt/.infra-releases/demo/.previous"
: >"$EVENTS"
install_release "$b"
JAIL=must-not-leak activate "$b" >/dev/null
test "$(readlink "$TMP/jail/opt/demo")" = ".infra-releases/demo/$b"
test "$(readlink "$TMP/jail/opt/.infra-releases/demo/.previous")" = "$a"
test "$(cat "$EVENTS")" = $'demo service demo stop\ndemo service demo status\ndemo service demo start\ncheck'
test ! -e "$TMP/jail/opt/.infra-releases/demo/$a/.switch"
: >"$EVENTS"
if ! STILL_RUNNING=1 activate "$b" >/dev/null; then
    echo 'FAIL - same-identity activation must check without stopping/restarting' >&2; exit 1
fi
test "$(cat "$EVENTS")" = $'demo service demo status\ncheck'
test "$(readlink "$TMP/jail/opt/.infra-releases/demo/.previous")" = "$a"
# Explicit rollback runs the same guarded operation with the previous identity.
activate "$a" >/dev/null
test "$(readlink "$TMP/jail/opt/demo")" = ".infra-releases/demo/$a"
test "$(readlink "$TMP/jail/opt/.infra-releases/demo/.previous")" = "$b"
: >"$EVENTS"
if ! DELAY_STOP=1 activate "$b" >/dev/null; then
    echo 'FAIL - wait for asynchronous old-service shutdown before switching' >&2; exit 1
fi
test "$(grep -c 'service demo status' "$EVENTS")" -eq 3
test "$(readlink "$TMP/jail/opt/demo")" = ".infra-releases/demo/$b"
activate "$a" >/dev/null
: >"$EVENTS"
if UNKNOWN_STATUS=1 activate "$b" >/dev/null 2>&1; then
    echo 'FAIL - unknown stopped status must not permit switching' >&2; exit 1
fi
test "$(readlink "$TMP/jail/opt/demo")" = ".infra-releases/demo/$a"
: >"$EVENTS"
FAIL_STOP=1 activate "$b" >/dev/null 2>&1 && { echo 'ignored stop failure' >&2; exit 1; }
test "$(readlink "$TMP/jail/opt/demo")" = ".infra-releases/demo/$a"
test "$(cat "$EVENTS")" = 'demo service demo stop'
: >"$EVENTS"
STILL_RUNNING=1 activate "$b" >/dev/null 2>&1 && { echo 'switched while old service still runs' >&2; exit 1; }
test "$(readlink "$TMP/jail/opt/demo")" = ".infra-releases/demo/$a"
: >"$EVENTS"
FAIL_START=1 activate "$b" >/dev/null 2>&1 && { echo 'ignored start failure' >&2; exit 1; }
test "$(readlink "$TMP/jail/opt/demo")" = ".infra-releases/demo/$b"
test "$(readlink "$TMP/jail/opt/.infra-releases/demo/.previous")" = "$a"
test "$(cat "$EVENTS")" = $'demo service demo stop\ndemo service demo status\ndemo service demo start'
: >"$EVENTS"
STILL_RUNNING=1 FAIL_CHECK=1 activate "$b" >/dev/null 2>&1 && { echo 'ignored health failure' >&2; exit 1; }
test "$(cat "$EVENTS")" = $'demo service demo status\ncheck'
test "$(readlink "$TMP/jail/opt/.infra-releases/demo/.previous")" = "$a"
# Migrate runs on the new release after the switch, before start. A healthy
# activation keeps only the active and previous releases.
install_release "$c"
mkdir "$TMP/jail/opt/.infra-releases/demo/not-a-release"
: >"$EVENTS"
MIGRATE=migrate activate "$c" >/dev/null
test "$(cat "$EVENTS")" = $'demo service demo stop\ndemo service demo status\ndemo service demo migrate\ndemo service demo start\ncheck'
test "$(readlink "$TMP/jail/opt/demo")" = ".infra-releases/demo/$c"
test "$(readlink "$TMP/jail/opt/.infra-releases/demo/.previous")" = "$b"
test ! -e "$TMP/jail/opt/.infra-releases/demo/$a"
test -d "$TMP/jail/opt/.infra-releases/demo/$b"
test -d "$TMP/jail/opt/.infra-releases/demo/not-a-release"
# A failed migrate leaves the service stopped on the new release: data may
# have changed, so nothing restarts the old one automatically.
install_release "$a"
: >"$EVENTS"
if MIGRATE=migrate FAIL_MIGRATE=1 activate "$a" >/dev/null 2>"$TMP/error"; then
    echo 'FAIL - ignored migrate failure' >&2; exit 1
fi
test "$(cat "$EVENTS")" = $'demo service demo stop\ndemo service demo status\ndemo service demo migrate'
test "$(readlink "$TMP/jail/opt/demo")" = ".infra-releases/demo/$a"
grep -q "previous release $c retained" "$TMP/error"
test -d "$TMP/jail/opt/.infra-releases/demo/$b"
# Running it again once the cause is fixed resumes the stopped release in
# place: migrate, start, health, no stop and no switch. A status that is
# neither running nor stopped is refused.
: >"$EVENTS"
if UNKNOWN_STATUS=1 MIGRATE=migrate activate "$a" >/dev/null 2>&1; then
    echo 'FAIL - resumed with an unknown status' >&2; exit 1
fi
test "$(cat "$EVENTS")" = 'demo service demo status'
: >"$EVENTS"
MIGRATE=migrate activate "$a" >"$TMP/out"
test "$(cat "$EVENTS")" = $'demo service demo status\ndemo service demo migrate\ndemo service demo start\ncheck'
grep -q 'release resumed and healthy' "$TMP/out"
test "$(readlink "$TMP/jail/opt/demo")" = ".infra-releases/demo/$a"
test "$(readlink "$TMP/jail/opt/.infra-releases/demo/.previous")" = "$c"
MIGRATE=bogus refused "$c" 'unknown migrate mode'
: >"$EVENTS"
activate_test_jail "$b" >/dev/null
test "$(cat "$EVENTS")" = $'demotest service demo stop\ndemotest service demo status\ndemotest service demo start\ncheck'
test "$(readlink "$TMP/jail/opt/demo")" = ".infra-releases/demo/$b"
test "$(readlink "$TMP/jail/opt/.infra-releases/demo/.previous")" = "$a"
test ! -e "$TMP/jail/opt/demotest"
test ! -e "$TMP/jail/opt/.infra-releases/demotest"
refused ../escape 'path escape'
printf 'mismatch\n' >"$TMP/jail/opt/.infra-releases/demo/$a/.infra-sha256"
refused "$a" 'digest mismatch'
printf '%s\n' "$sha" >"$TMP/jail/opt/.infra-releases/demo/$a/.infra-sha256"
rm "$TMP/jail/opt/demo"
ln -s ../var/db/demo "$TMP/jail/opt/demo"
refused "$a" 'unmanaged pointer'
rm "$TMP/jail/opt/demo"
mkdir "$TMP/jail/opt/demo"
refused "$a" 'legacy directory'
rmdir "$TMP/jail/opt/demo"
rm "$TMP/jail/opt/.infra-releases/demo/.previous"
ln -s /etc "$TMP/jail/opt/.infra-releases/demo/.previous"
refused "$a" 'unmanaged previous pointer'
test "$(cat "$TMP/jail/var/db/demo/marker")" = 'mutable marker'
test "$(find "$TMP/jail/opt" -name '.switch.*' | wc -l)" -eq 0
echo 'ok - guarded activation, migrate, pruning, explicit rollback, failure boundaries and external state'

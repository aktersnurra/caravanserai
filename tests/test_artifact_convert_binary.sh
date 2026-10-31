#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
id=$(printf 'a%.0s' {1..64}); digest=$(printf 'b%.0s' {1..64})
mkdir -p "$TMP/jail/opt/.infra-releases/idp/$id/bin" "$TMP/jail/usr/local/bin" "$TMP/bin" "$TMP/jail/var/db/idp"
printf '#!/bin/sh\nexit 0\n' >"$TMP/jail/usr/local/bin/idp"
cp "$TMP/jail/usr/local/bin/idp" "$TMP/jail/opt/.infra-releases/idp/$id/bin/idp"
chmod 755 "$TMP/jail/usr/local/bin/idp" "$TMP/jail/opt/.infra-releases/idp/$id/bin/idp"
printf '%s\n' "$digest" >"$TMP/jail/opt/.infra-releases/idp/$id/.infra-sha256"
printf 'external state\n' >"$TMP/jail/var/db/idp/marker"
cat >"$TMP/bin/jexec" <<'EOF'
#!/bin/sh
[ "$1 $2 $3" = 'idp service idp' ] || exit 2
printf '%s\n' "$4" >>"$EVENTS"
case "$4" in
 stop) if [ "${DELAY_STOP:-0}" = 1 ]; then printf '2\n' >"$RUNNING.remaining"; else rm -f "$RUNNING"; fi ;;
 start) [ "${FAIL_START:-0}" = 0 ] || exit 1; touch "$RUNNING" ;;
 status)
  [ "${UNKNOWN_STATUS:-0}" = 0 ] || exit 2
  if [ -f "$RUNNING.remaining" ]; then
   left=$(cat "$RUNNING.remaining")
   if [ "$left" -gt 0 ]; then printf '%s\n' "$((left - 1))" >"$RUNNING.remaining"; exit 0; fi
   rm -f "$RUNNING" "$RUNNING.remaining"
  fi
  [ -f "$RUNNING" ] ;;
 *) exit 2 ;;
esac
EOF
cat >"$TMP/bin/stat" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --version ]; then exec /usr/bin/stat --version; fi
case "$2" in '%u:%a') printf '0:%s\n' "$(/usr/bin/stat -c %a "$3")" ;; '%u:%h') printf '%s:%s\n' "${SOURCE_UID:-0}" "$(/usr/bin/stat -c %h "$3")" ;; *) exit 1 ;; esac
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
printf 'check\n' >>"$EVENTS"
[ "${FAIL_HEALTH:-0}" = 0 ]
EOF
cat >"$TMP/bin/sleep" <<'EOF'
#!/bin/sh
[ "$1" = 1 ] || exit 1
EOF
chmod +x "$TMP/bin/"*
export RUNNING="$TMP/running" EVENTS="$TMP/events"
run() {
 INFRA_LOCK_HELD=1 JAIL_ROOT="$TMP/jail" JEXEC_BIN="$TMP/bin/jexec" STAT_BIN="$TMP/bin/stat" CURL_BIN="$TMP/bin/curl" SLEEP_BIN="$TMP/bin/sleep" \
 sh "$ROOT/compute/apps/_lib/artifact_convert_binary.sh" idp "$id" "$digest" idp http://test/ /usr/local/bin/idp
}
touch "$RUNNING"
if ! DELAY_STOP=1 run >"$TMP/result" 2>&1; then
 echo 'FAIL - binary conversion must await delayed shutdown using rc idp, not launcher idp' >&2; exit 1
fi
[ "$(readlink "$TMP/jail/usr/local/bin/idp")" = /opt/idp/bin/idp ]
[ "$(readlink "$TMP/jail/opt/idp")" = ".infra-releases/idp/$id" ]
test -f "$TMP/jail/opt/.infra-legacy/idp/$id.binary"
test "$(/usr/bin/stat -c %a "$TMP/jail/opt/.infra-legacy/idp")" = 700
: >"$EVENTS"
run >/dev/null
[ "$(cat "$EVENTS")" = $'status\ncheck' ]
if FAIL_HEALTH=1 run >/dev/null 2>&1; then exit 1; fi
if UNKNOWN_STATUS=1 run >/dev/null 2>&1; then exit 1; fi
rm -f "$RUNNING"
run >/dev/null
test -f "$RUNNING"
# Resume after active pointer creation, before binary anchor creation.
rm "$TMP/jail/usr/local/bin/idp" "$RUNNING"
run >/dev/null
test -L "$TMP/jail/usr/local/bin/idp"
test -f "$RUNNING"
# Non-equivalent or linked code refuses before stopping.
rm "$TMP/jail/usr/local/bin/idp" "$TMP/jail/opt/idp"
printf 'different code\n' >"$TMP/jail/usr/local/bin/idp"
chmod 755 "$TMP/jail/usr/local/bin/idp"
: >"$EVENTS"
if run >"$TMP/error" 2>&1; then exit 1; fi
grep -Fq 'legacy executable does not match verified artifact' "$TMP/error"
test ! -s "$EVENTS"
rm "$TMP/jail/usr/local/bin/idp"
cp "$TMP/jail/opt/.infra-releases/idp/$id/bin/idp" "$TMP/jail/usr/local/bin/idp"
ln "$TMP/jail/usr/local/bin/idp" "$TMP/extra-link"
if run >"$TMP/error" 2>&1; then exit 1; fi
grep -Fq 'legacy executable does not match verified artifact' "$TMP/error"
test ! -s "$EVENTS"
rm "$TMP/extra-link"
if SOURCE_UID=1000 run >"$TMP/error" 2>&1; then exit 1; fi
grep -Fq 'legacy executable does not match verified artifact' "$TMP/error"
test ! -s "$EVENTS"
# A failed original rename leaves a receipt; only matching stopped code resumes.
rm "$TMP/jail/opt/.infra-legacy/idp/$id.binary" "$TMP/jail/opt/.infra-legacy/idp/$id.binary-receipt"
cat >"$TMP/bin/mv-fail" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$TMP/bin/mv-fail"
if MV_BIN="$TMP/bin/mv-fail" run >"$TMP/error" 2>&1; then exit 1; fi
test -f "$TMP/jail/usr/local/bin/idp"
test -f "$TMP/jail/opt/.infra-legacy/idp/$id.binary-receipt"
run >/dev/null
test -L "$TMP/jail/usr/local/bin/idp"
test -f "$TMP/jail/opt/.infra-legacy/idp/$id.binary"
test "$(cat "$TMP/jail/var/db/idp/marker")" = 'external state'
echo 'ok - binary conversion preserves state, matches bytes, awaits shutdown and uses the declared rc service'

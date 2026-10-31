#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
identity=$(printf 'a%.0s' {1..64})
digest=$(printf 'b%.0s' {1..64})
mkdir -p "$TMP/jail/opt/.infra-releases/garage/$identity/bin" "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' >"$TMP/jail/opt/.infra-releases/garage/$identity/bin/garage"
chmod +x "$TMP/jail/opt/.infra-releases/garage/$identity/bin/garage"
printf '%s\n' "$digest" >"$TMP/jail/opt/.infra-releases/garage/$identity/.infra-sha256"
cat >"$TMP/bin/jexec" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$EVENTS"
case "$*" in
 *' status')
  if [ "${RC_BECOMES_READY:-0}" = 1 ]; then
   [ -f "$EVENTS.service-remaining" ] || printf '2\n' >"$EVENTS.service-remaining"
   left=$(cat "$EVENTS.service-remaining")
   if [ "$left" -gt 0 ]; then printf '%s\n' "$((left - 1))" >"$EVENTS.service-remaining"; exit 1; fi
  fi
  [ "${NOT_RUNNING:-0}" = 0 ] ;;
 *) exit 0 ;;
esac
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
printf 'curl\n' >>"$EVENTS"
status=${RESPONSE:-403}
if [ "${BECOMES_READY:-0}" = 1 ]; then
 if [ ! -f "$EVENTS.remaining" ]; then printf '2\n' >"$EVENTS.remaining"; fi
 left=$(cat "$EVENTS.remaining")
 if [ "$left" -gt 0 ]; then status=503; printf '%s\n' "$((left - 1))" >"$EVENTS.remaining"; fi
fi
# Faithfully model curl -f rejecting Garage's unsigned 403.
case "$*" in *'-fsS'*) [ "$status" != 403 ] || exit 22 ;; esac
[ "${TRANSPORT_FAIL:-0}" = 0 ] || exit 7
case "$*" in *'%{http_code}'*) printf '%s' "$status" ;; esac
EOF
cat >"$TMP/bin/sleep" <<'EOF'
#!/bin/sh
[ "$1" = 1 ] || exit 99
printf 'sleep\n' >>"$EVENTS"
EOF
cat >"$TMP/bin/mv" <<'EOF'
#!/bin/sh
[ "$1" = -fh ] || exit 99
shift
if mv --version >/dev/null 2>&1; then exec mv -fT "$@"; fi; exec mv -fh "$@"
EOF
chmod +x "$TMP/bin/"*
export EVENTS="$TMP/events"
activate() {
 JAIL_ROOT="$TMP/jail" JEXEC_BIN="$TMP/bin/jexec" CURL_BIN="$TMP/bin/curl" SLEEP_BIN="$TMP/bin/sleep" \
  MV_BIN="$TMP/bin/mv" SERAI_ARTIFACT_HTTP_STATUS=403 SERAI_ARTIFACT_SERVICE_STATUS=process sh "$ROOT/compute/apps/_lib/artifact_activate.sh" \
  garage "$identity" "$digest" garage garage http://10.40.0.4:3900/ - garage
}
if ! activate >"$TMP/result" 2>&1; then
 echo 'FAIL - approved Garage readiness must accept exact S3 403' >&2; exit 1
fi
grep -Fq 'garage service garage status' "$EVENTS"
test "$(grep -c '^curl$' "$EVENTS")" -eq 1
: >"$EVENTS"
activate >/dev/null
! grep -q ' start\| stop' "$EVENTS"
: >"$EVENTS"
BECOMES_READY=1 activate >/dev/null
test "$(grep -c '^curl$' "$EVENTS")" -eq 3
test "$(grep -c '^sleep$' "$EVENTS")" -eq 2
: >"$EVENTS"
if ! RC_BECOMES_READY=1 activate >"$TMP/result" 2>&1; then
 echo 'FAIL - Garage rc readiness must be retried before declaring health failure' >&2; exit 1
fi
test "$(grep -c '^curl$' "$EVENTS")" -eq 1
test "$(grep -c '^sleep$' "$EVENTS")" -eq 2
if grep -q ' start\| stop' "$EVENTS"; then
 echo 'FAIL - same-identity readiness retries must not restart Garage' >&2; exit 1
fi
for status in 200 401 404 500; do
 : >"$EVENTS"
 if RESPONSE="$status" activate >/dev/null 2>&1; then echo "accepted wrong S3 status $status" >&2; exit 1; fi
 test "$(grep -c '^curl$' "$EVENTS")" -eq 6
 test "$(grep -c '^sleep$' "$EVENTS")" -eq 5
 test "$(readlink "$TMP/jail/opt/garage")" = ".infra-releases/garage/$identity"
done
: >"$EVENTS"
if TRANSPORT_FAIL=1 activate >/dev/null 2>&1; then exit 1; fi
test "$(grep -c '^curl$' "$EVENTS")" -eq 6
: >"$EVENTS"
if NOT_RUNNING=1 activate >/dev/null 2>&1; then exit 1; fi
! grep -q '^curl$' "$EVENTS"
echo 'ok - Garage requires running service plus exact 403 with bounded retries, no restart or storage writes'

#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/systemctl" <<'EOF'
#!/bin/sh
[ "$*" = 'is-active ledger' ] || exit 9
printf '%s\n' "$STATE"
exit "$RESULT"
EOF
chmod +x "$TMP/systemctl"
for spec in active:0:0 inactive:3:1 inactive:1:2 active:1:2 failed:3:2 activating:3:2; do
 IFS=: read -r state result expected <<<"$spec"
 rc=0
 STATE="$state" RESULT="$result" SYSTEMCTL_BIN="$TMP/systemctl" \
 sh "$ROOT/compute/apps/_lib/artifact_service_guest.sh" ledger service ledger status || rc=$?
 if [ "$rc" -ne "$expected" ]; then
  printf 'FAIL - service state %s/exit %s must map to %s, got %s\n' "$state" "$result" "$expected" "$rc" >&2; exit 1
 fi
done
for args in 'ledger service other status' 'ledger exec ledger status' '-x service -x status' \
  'Ledger service Ledger status' 'ledger service ledger restart'; do
 rc=0
 # shellcheck disable=SC2086
 STATE=active RESULT=0 SYSTEMCTL_BIN="$TMP/systemctl" \
 sh "$ROOT/compute/apps/_lib/artifact_service_guest.sh" $args || rc=$?
 [ "$rc" -eq 1 ] || { printf 'FAIL - service boundary accepted: %s\n' "$args" >&2; exit 1; }
done
echo 'ok - Ledger conversion service boundary accepts only exact running/stopped status results'

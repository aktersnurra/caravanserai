#!/usr/bin/env bash
# Linux Ledger conversion fixture; no guest, root privilege or runtime secrets.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
id="$(printf 'a%.0s' {1..64})"; sha="$(printf 'b%.0s' {1..64})"
mkdir -p "$TMP/root/opt/.infra-releases/ledger/$id/bin" "$TMP/root/usr/local/bin" \
 "$TMP/root/var/lib/ledger" "$TMP/root/etc/ledger" "$TMP/bin"
cp "$ROOT/tests/stat-field" "$TMP/bin/"
printf '#!/bin/sh\nexit 0\n' >"$TMP/root/usr/local/bin/ledger"
chmod 755 "$TMP/root/usr/local/bin/ledger"
cp "$TMP/root/usr/local/bin/ledger" "$TMP/root/opt/.infra-releases/ledger/$id/bin/ledger"
printf '%s\n' "$sha" >"$TMP/root/opt/.infra-releases/ledger/$id/.infra-sha256"
printf 'public state fixture\n' >"$TMP/root/var/lib/ledger/state"
printf 'public configuration fixture\n' >"$TMP/root/etc/ledger/ledger.sexp"
chmod 640 "$TMP/root/etc/ledger/ledger.sexp"
before="$(sha256sum "$TMP/root/var/lib/ledger/state" "$TMP/root/etc/ledger/ledger.sexp")"
cat >"$TMP/bin/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$EVENTS"
case "$*" in
 'stop ledger') rm -f "$RUNNING" ;;
 'start ledger') touch "$RUNNING" ;;
 'is-active ledger')
  if [ "${UNKNOWN_STATUS:-0}" = 1 ]; then echo failed; exit 3; fi
  if [ -e "$RUNNING" ]; then echo active; else echo inactive; exit 3; fi ;;
 *) exit 2 ;;
esac
EOF
cat >"$TMP/bin/stat" <<'EOF'
#!/bin/sh
if [ "${1:-}" = --version ]; then exec /usr/bin/stat --version; fi
case "$2" in
 '%u:%a' | '%u:%Lp') printf '0:%s\n' "$("${0%/*}/stat-field" perm "$3")" ;;
 '%u:%h' | '%u:%l') printf '0:%s\n' "$("${0%/*}/stat-field" links "$3")" ;;
 *) exit 1 ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/curl"
cp "$ROOT/compute/apps/_lib/artifact_service_guest.sh" "$TMP/bin/service"
chmod +x "$TMP/bin/"*
export EVENTS="$TMP/events" RUNNING="$TMP/running"
run() {
 SERAI_LOCK_HELD=1 JAIL_ROOT="$TMP/root" STAT_BIN="$TMP/bin/stat" \
 JEXEC_BIN="$TMP/bin/service" SYSTEMCTL_BIN="$TMP/bin/systemctl" CURL_BIN="$TMP/bin/curl" \
 sh "$ROOT/compute/apps/_lib/artifact_convert_binary.sh" ledger "$id" "$sha" ledger http://10.40.0.10:4010/health /usr/local/bin/ledger
}
touch "$RUNNING"
if UNKNOWN_STATUS=1 run >"$TMP/error" 2>&1; then exit 1; fi
[ ! -L "$TMP/root/usr/local/bin/ledger" ]
[ ! -e "$TMP/root/opt/ledger" ]
run >/dev/null
[ "$(readlink "$TMP/root/usr/local/bin/ledger")" = /opt/ledger/bin/ledger ]
[ "$(readlink "$TMP/root/opt/ledger")" = ".infra-releases/ledger/$id" ]
[ -f "$TMP/root/opt/.infra-legacy/ledger/$id.binary" ]
[ "$("$ROOT/tests/stat-field" perm "$TMP/root/opt/.infra-legacy/ledger")" = 700 ]
: >"$EVENTS"
run >/dev/null
[ "$(cat "$EVENTS")" = 'is-active ledger' ]
[ "$(sha256sum "$TMP/root/var/lib/ledger/state" "$TMP/root/etc/ledger/ledger.sexp")" = "$before" ]
[ "$("$ROOT/tests/stat-field" perm "$TMP/root/etc/ledger/ledger.sexp")" = 640 ]
echo 'ok - Ledger conversion uses systemd boundary, retains protected original and preserves external state/config'

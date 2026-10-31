#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
id_a="$(printf 'a%.0s' {1..64})"
id_b="$(printf 'b%.0s' {1..64})"
sha="$(printf 'c%.0s' {1..64})"
for id in "$id_a" "$id_b"; do
 mkdir -p "$TMP/root/opt/.infra-releases/ledger/$id/bin"
 printf '#!/bin/sh\nexit 0\n' >"$TMP/root/opt/.infra-releases/ledger/$id/bin/ledger"
 chmod 755 "$TMP/root/opt/.infra-releases/ledger/$id/bin/ledger"
 printf '%s\n' "$sha" >"$TMP/root/opt/.infra-releases/ledger/$id/.infra-sha256"
done
mkdir -p "$TMP/bin" "$TMP/root/usr/local/bin" "$TMP/root/var/lib/ledger"
printf 'external state\n' >"$TMP/root/var/lib/ledger/state"
ln -s /opt/ledger/bin/ledger "$TMP/root/usr/local/bin/ledger"
cat >"$TMP/bin/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$EVENTS"
case "$*" in
 'is-active ledger') case "${STATUS:-}" in inactive-error) echo inactive; exit 1 ;; unknown|activating|failed) echo "${STATUS}"; exit 3 ;; esac; if [ -e "$RUNNING" ]; then echo active; else echo inactive; exit 3; fi ;;
 'stop ledger') [ "${FAIL_STOP:-0}" != 1 ] || exit 1; rm -f "$RUNNING" ;;
 'start ledger') [ "${FAIL_START:-0}" != 1 ] || exit 1; touch "$RUNNING" ;;
 *) exit 1 ;;
esac
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
[ "${FAIL_HEALTH:-0}" != 1 ]
EOF
chmod +x "$TMP/bin/"*
export EVENTS="$TMP/events" RUNNING="$TMP/running"
run() {
 SERAI_LOCK_HELD=1 GUEST_ROOT="$TMP/root" SYSTEMCTL_BIN="$TMP/bin/systemctl" CURL_BIN="$TMP/bin/curl" \
 sh "$ROOT/compute/apps/_lib/artifact_activate_guest.sh" "$1" ledger "$2" "$sha" http://10.40.0.10:4010/health
}
run upgrade "$id_a"
[ "$(readlink "$TMP/root/opt/ledger")" = ".infra-releases/ledger/$id_a" ]
[ ! -e "$TMP/root/opt/.infra-releases/ledger/.previous" ]
: >"$EVENTS"
run upgrade "$id_a"
[ "$(cat "$EVENTS")" = 'is-active ledger' ]
run upgrade "$id_b"
[ "$(readlink "$TMP/root/opt/.infra-releases/ledger/.previous")" = "$id_a" ]
run rollback "$id_a"
[ "$(readlink "$TMP/root/opt/ledger")" = ".infra-releases/ledger/$id_a" ]
: >"$EVENTS"
if run rollback "$id_a" >"$TMP/error" 2>&1; then exit 1; fi
[ ! -s "$EVENTS" ]
if FAIL_STOP=1 run upgrade "$id_b" >"$TMP/error" 2>&1; then exit 1; fi
[ "$(readlink "$TMP/root/opt/ledger")" = ".infra-releases/ledger/$id_a" ]
if STATUS=activating run upgrade "$id_b" >"$TMP/error" 2>&1; then exit 1; fi
[ "$(readlink "$TMP/root/opt/ledger")" = ".infra-releases/ledger/$id_a" ]
if STATUS=failed run upgrade "$id_b" >"$TMP/error" 2>&1; then exit 1; fi
[ "$(readlink "$TMP/root/opt/ledger")" = ".infra-releases/ledger/$id_a" ]
if STATUS=inactive-error run upgrade "$id_b" >"$TMP/error" 2>&1; then
 echo 'FAIL - unrecognized status exit must not authorize switching code' >&2; exit 1
fi
[ "$(readlink "$TMP/root/opt/ledger")" = ".infra-releases/ledger/$id_a" ]
if FAIL_HEALTH=1 run upgrade "$id_b" >"$TMP/error" 2>&1; then exit 1; fi
[ "$(readlink "$TMP/root/opt/.infra-releases/ledger/.previous")" = "$id_a" ]
[ "$(cat "$TMP/root/var/lib/ledger/state")" = 'external state' ]
export FAIL_HEALTH=0
run rollback "$id_a"
# A failed active rename restores the exact retained previous identity.
cat >"$TMP/bin/mv" <<'EOF'
#!/bin/sh
for arg in "$@"; do [ "$arg" = "$GUEST_ROOT/opt/ledger" ] && exit 1; done
exec mv "$@"
EOF
chmod +x "$TMP/bin/mv"
if MV_BIN="$TMP/bin/mv" run upgrade "$id_b" >"$TMP/error" 2>&1; then exit 1; fi
[ "$(readlink "$TMP/root/opt/ledger")" = ".infra-releases/ledger/$id_a" ]
[ "$(readlink "$TMP/root/opt/.infra-releases/ledger/.previous")" = "$id_b" ]
[ ! -e "$TMP/root/opt/.infra-releases/ledger/.switch-transaction" ]
# Reset a managed stopped guest to one exact pointer state.
reset_state() {
 rm -f "$TMP/root/opt/ledger" "$TMP/root/opt/.infra-releases/ledger/.previous" "$TMP/root/opt/.infra-releases/ledger/.switch-transaction" "$RUNNING"
 ln -s ".infra-releases/ledger/$1" "$TMP/root/opt/ledger"
 [ "$2" = - ] || ln -s "$2" "$TMP/root/opt/.infra-releases/ledger/.previous"
}
write_transaction() { printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >"$TMP/root/opt/.infra-releases/ledger/.switch-transaction"; }
# A rollback retry reaches root-side reconciliation before retained-previous authorization.
reset_state "$id_b" "$id_b"
write_transaction "$id_b" "$id_a" "$id_a" rollback
run rollback "$id_a"
[ "$(readlink "$TMP/root/opt/ledger")" = ".infra-releases/ledger/$id_a" ]
[ "$(readlink "$TMP/root/opt/.infra-releases/ledger/.previous")" = "$id_b" ]
[ ! -e "$TMP/root/opt/.infra-releases/ledger/.switch-transaction" ]
# Publication before previous replacement (and restored-before-cleanup, the same exact state) is safe to clear and retry.
reset_state "$id_b" "$id_a"
write_transaction "$id_b" "$id_a" "$id_a" rollback
run rollback "$id_a"
[ "$(readlink "$TMP/root/opt/ledger")" = ".infra-releases/ledger/$id_a" ]
# The no-prior-previous publication state is also exact and recoverable.
reset_state "$id_a" -
write_transaction "$id_a" "$id_b" - upgrade
run upgrade "$id_b"
[ "$(readlink "$TMP/root/opt/ledger")" = ".infra-releases/ledger/$id_b" ]
[ "$(readlink "$TMP/root/opt/.infra-releases/ledger/.previous")" = "$id_a" ]
# A failed previous replacement retains its receipt; an exact retry reconciles it.
reset_state "$id_b" "$id_a"
cat >"$TMP/bin/mv-previous" <<'EOF'
#!/bin/sh
for arg in "$@"; do [ "$arg" = "$GUEST_ROOT/opt/.infra-releases/ledger/.previous" ] && exit 1; done
exec mv "$@"
EOF
chmod +x "$TMP/bin/mv-previous"
if MV_BIN="$TMP/bin/mv-previous" run rollback "$id_a" >"$TMP/error" 2>&1; then exit 1; fi
[ -f "$TMP/root/opt/.infra-releases/ledger/.switch-transaction" ]
run rollback "$id_a"
[ "$(readlink "$TMP/root/opt/ledger")" = ".infra-releases/ledger/$id_a" ]
# Post-active rename receipt authorizes recovery of only its exact selected release.
reset_state "$id_a" "$id_b"
write_transaction "$id_b" "$id_a" "$id_a" rollback
if FAIL_START=1 run rollback "$id_a" >"$TMP/error" 2>&1; then exit 1; fi
[ -f "$TMP/root/opt/.infra-releases/ledger/.switch-transaction" ]
export FAIL_START=0
run rollback "$id_a"
[ -e "$RUNNING" ]
[ ! -e "$TMP/root/opt/.infra-releases/ledger/.switch-transaction" ]
reset_state "$id_a" "$id_b"
write_transaction "$id_b" "$id_a" "$id_a" rollback
if FAIL_HEALTH=1 run rollback "$id_a" >"$TMP/error" 2>&1; then exit 1; fi
[ -f "$TMP/root/opt/.infra-releases/ledger/.switch-transaction" ]
export FAIL_HEALTH=0
run rollback "$id_a"
[ ! -e "$TMP/root/opt/.infra-releases/ledger/.switch-transaction" ]
rm "$RUNNING"
: >"$EVENTS"
if run upgrade "$id_a" >"$TMP/error" 2>&1; then exit 1; fi
[ "$(readlink "$TMP/root/opt/ledger")" = ".infra-releases/ledger/$id_a" ]
[ "$(readlink "$TMP/root/opt/.infra-releases/ledger/.previous")" = "$id_b" ]
[ "$(cat "$EVENTS")" = 'is-active ledger' ]
# Wrong selected identity and altered evidence fail closed before service mutation.
reset_state "$id_a" "$id_b"
write_transaction "$id_b" "$id_a" "$id_a" rollback
: >"$EVENTS"
if run upgrade "$id_a" >"$TMP/error" 2>&1; then exit 1; fi
[ ! -s "$EVENTS" ]
write_transaction "$id_b" "$id_a" "$id_b" rollback
if run rollback "$id_a" >"$TMP/error" 2>&1; then exit 1; fi
[ ! -s "$EVENTS" ]
echo 'ok - Linux systemd activation retains previous identity and reconciles exact pointer transaction interruption states'

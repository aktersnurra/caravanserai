#!/bin/sh
# A guest workload's Linux file activation only; never rewrite unit/config/state
# or enable it. RELEASE names the executable, the systemd unit and /opt/RELEASE.
# MODE RELEASE IDENTITY ARCHIVE_SHA HEALTH_URL. Root caller holds guest lifecycle lock.
set -eu
mode=${1:?}; release=${2:?}; identity=${3:?}; expected=${4:?}; url=${5:?}
fail() { echo "guest artifact activation: $*" >&2; exit 1; }
case "$release" in [a-z]*) ;; *) fail 'invalid release name' ;; esac
case "$release" in *[!a-z0-9_-]*) fail 'invalid release name' ;; esac
digest() { case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac; [ "${#1}" = 64 ]; }
[ "${SERAI_LOCK_HELD:-0}" = 1 ] || fail 'lifecycle lock required'
case "$mode" in upgrade|rollback) ;; *) fail 'invalid operation' ;; esac
digest "$identity" && digest "$expected" || fail 'invalid identity or digest'
case "$url" in http://*) ;; *) fail 'invalid health URL' ;; esac
case "$url" in *[!a-zA-Z0-9./:_?=\&%+-]*) fail 'unsafe health URL' ;; esac
root=${GUEST_ROOT:-/}; root=${root%/}
release_root=$root/opt/.infra-releases/$release; target=$release_root/$identity
active=$root/opt/$release; previous=$release_root/.previous; transaction=$release_root/.switch-transaction
for path in "$root/opt" "$root/opt/.infra-releases" "$release_root" "$target" "$target/bin" "$root/usr" "$root/usr/local" "$root/usr/local/bin"; do
 [ -d "$path" ] && [ ! -L "$path" ] || fail 'missing or redirected release directory'
done
[ -f "$target/.infra-sha256" ] && [ ! -L "$target/.infra-sha256" ] && [ "$(cat "$target/.infra-sha256")" = "$expected" ] || fail 'installed archive digest mismatch'
[ -f "$target/bin/$release" ] && [ ! -L "$target/bin/$release" ] && [ -x "$target/bin/$release" ] || fail 'invalid release executable'
[ -L "$root/usr/local/bin/$release" ] && [ "$(readlink "$root/usr/local/bin/$release")" = "/opt/$release/bin/$release" ] || fail 'legacy executable needs explicit conversion'
pointer_id() {
 [ -L "$1" ] || return 1
 value=$(readlink "$1")
 if [ "$1" = "$active" ]; then case "$value" in ".infra-releases/$release/"*) value=${value#".infra-releases/$release/"} ;; *) return 1 ;; esac; fi
 digest "$value" && [ -d "$release_root/$value" ] && [ ! -L "$release_root/$value" ] || return 1
 printf '%s\n' "$value"
}
read_pointers() {
 old_id=''; previous_id=''
 if [ -L "$active" ]; then old_id=$(pointer_id "$active") || fail 'unmanaged active pointer'; elif [ -e "$active" ]; then fail 'occupied active path'; fi
 if [ -L "$previous" ]; then previous_id=$(pointer_id "$previous") || fail 'invalid previous pointer'; elif [ -e "$previous" ]; then fail 'occupied previous pointer'; fi
}
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}; mv_bin=${MV_BIN:-mv}
service_state() {
 rc=0; state=$("$systemctl_bin" is-active "$release" 2>/dev/null) || rc=$?
 case "$rc:$state" in 0:active) echo running ;; 3:inactive) echo stopped ;; *) echo unknown ;; esac
}
require_stopped() { case "$(service_state)" in stopped) ;; running) fail 'old service still running; pointer unchanged' ;; *) fail 'service status is unknown; pointer unchanged' ;; esac; }
script_dir=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
check_health() { sh "$script_dir/artifact_check_health.sh" "$url"; }
read_pointers
# This root-side receipt is the only authority for recovery between pointer
# replacements. Its mode binds a rollback retry to the exact retained release.
if [ -e "$transaction" ] || [ -L "$transaction" ]; then
 [ -f "$transaction" ] && [ ! -L "$transaction" ] || fail 'invalid switch transaction evidence'
 # Split the four whitespace-separated fields; each is validated below.
 # shellcheck disable=SC2046
 set -- $(cat "$transaction")
 [ "$#" = 4 ] && digest "$1" && digest "$2" && { [ "$3" = - ] || digest "$3"; } && { [ "$4" = upgrade ] || [ "$4" = rollback ]; } || fail 'invalid switch transaction evidence'
 txn_old=$1; txn_new=$2; txn_prior=$3; txn_mode=$4
 # An unhealthy upgrade may be explicitly rolled back to its exact retained
 # previous release; this safely supersedes its post-switch receipt.
 if [ "$txn_mode" != "$mode" ] || [ "$txn_new" != "$identity" ]; then
  if [ "$txn_mode" = upgrade ] && [ "$mode" = rollback ] && [ "$identity" = "$txn_old" ] && [ "$old_id" = "$txn_new" ] && [ "$previous_id" = "$txn_old" ]; then
   rm -f -- "$transaction"
  else fail 'switch transaction does not authorize selected operation'; fi
 elif [ "$mode" = rollback ] && { [ "$txn_prior" = - ] || [ "$txn_new" != "$txn_prior" ]; }; then
  fail 'switch transaction does not authorize selected rollback'
 # Published before the previous replacement, or left after restoring it:
 # both exact old/prior pointer states are safe to clear and retry.
 elif [ "$old_id" = "$txn_old" ] && { [ "$previous_id" = "$txn_prior" ] || { [ "$txn_prior" = - ] && [ -z "$previous_id" ]; }; }; then
  rm -f -- "$transaction"
 # Previous was replaced but active was not: restore exactly the prior pointer.
 elif [ "$old_id" = "$txn_old" ] && [ "$previous_id" = "$txn_old" ]; then
  tmp_recover=$(mktemp -d "$release_root/.recover.XXXXXXXX")
  trap 'rm -rf "$tmp_recover"' EXIT HUP INT TERM
  if [ "$txn_prior" = - ]; then rm -f -- "$previous"
  else ln -s "$txn_prior" "$tmp_recover/previous" && "$mv_bin" -Tf "$tmp_recover/previous" "$previous" || fail 'switch transaction recovery failed'; fi
  rm -f -- "$transaction"; trap - EXIT HUP INT TERM; rm -rf "$tmp_recover"
  previous_id=$txn_prior; [ "$previous_id" = - ] && previous_id=''
 # Active changed, but the receipt intentionally remains until start/health.
 elif [ "$old_id" = "$txn_new" ] && [ "$previous_id" = "$txn_old" ]; then
  case "$(service_state)" in
   running) ;;
   stopped) "$systemctl_bin" start "$release" || fail 'transaction recovery start failed; receipt retained' ;;
   *) fail 'transaction recovery status unknown; receipt retained' ;;
  esac
  check_health || fail 'transaction recovery health failed; receipt retained'
  rm -f -- "$transaction"
  echo "$release recovered and healthy: $identity"; exit 0
 else fail 'switch transaction does not match managed pointers'; fi
fi
# Reconciliation above precedes this retained-previous authorization.
if [ "$mode" = rollback ]; then [ -L "$previous" ] && [ "$(readlink "$previous")" = "$identity" ] || fail 'identity is not retained previous release'; fi
if [ "$old_id" = "$identity" ]; then
 [ "$(service_state)" = running ] || fail 'selected release is not running; pointer unchanged'
 check_health || fail 'selected release is unhealthy; pointer unchanged'
 echo "$release already active and healthy: $identity"; exit 0
fi
umask 022
tmp=$(mktemp -d "$release_root/.switch.XXXXXXXX"); trap 'rm -rf "$tmp"' EXIT HUP INT TERM
ln -s ".infra-releases/$release/$identity" "$tmp/current"
if [ -n "$old_id" ]; then
 ln -s "$old_id" "$tmp/previous"
 "$systemctl_bin" stop "$release" || fail 'old service stop failed; pointer unchanged'
 require_stopped
else case "$(service_state)" in stopped) ;; running) fail 'service running without managed release; pointer unchanged' ;; *) fail 'service status is unknown; pointer unchanged' ;; esac; fi
if [ -L "$tmp/previous" ]; then
 prior=${previous_id:--}
 printf '%s %s %s %s\n' "$old_id" "$identity" "$prior" "$mode" >"$tmp/transaction"
 "$mv_bin" -Tf "$tmp/transaction" "$transaction" || fail 'switch transaction creation failed; active unchanged'
 "$mv_bin" -Tf "$tmp/previous" "$previous" || fail 'previous pointer switch failed; transaction retained for retry'
 if ! "$mv_bin" -Tf "$tmp/current" "$active"; then
  if [ "$prior" = - ]; then rm -f -- "$previous"
  else ln -s "$prior" "$tmp/restore-previous" && "$mv_bin" -Tf "$tmp/restore-previous" "$previous" || fail 'active switch failed and previous restoration failed'; fi
  rm -f -- "$transaction"
  fail 'active pointer switch failed; previous restored'
 fi
else "$mv_bin" -Tf "$tmp/current" "$active" || fail 'active pointer switch failed'; fi
"$systemctl_bin" start "$release" || fail 'new service start failed; transaction retained for recovery'
check_health || fail 'new release unhealthy; transaction retained for recovery'
rm -f -- "$transaction"
echo "$release active and healthy: $identity"

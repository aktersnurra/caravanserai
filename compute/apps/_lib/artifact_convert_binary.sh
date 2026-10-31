#!/bin/sh
# Convert only a byte-equivalent root-owned legacy executable, never state/config.
# JAIL IDENTITY ARCHIVE_SHA RELEASE HEALTH_URL ANCHOR; caller holds lifecycle lock.
set -eu
jail=${1:?}; identity=${2:?}; expected=${3:?}; release=${4:?}; url=${5:?}; anchor=${6:?}
fail() { echo "binary artifact conversion: $*" >&2; exit 1; }
[ "${INFRA_LOCK_HELD:-0}" = 1 ] || fail 'lifecycle lock required'
# rc: the service's rc status says whether it runs. process: its rc status
# checks something else, so a process named after the release decides.
service_status=${INFRA_ARTIFACT_SERVICE_STATUS:-rc}
case "$service_status" in rc|process) ;; *) fail 'invalid service status mode' ;; esac
case "$jail:$release" in *[!a-zA-Z0-9_:-]*) fail 'invalid names' ;; esac
[ -n "$jail" ] && [ -n "$release" ] || fail 'empty names'
case "$identity:$expected" in *[!0-9a-f:]*) fail 'invalid digests' ;; esac
[ "${#identity}" = 64 ] && [ "${#expected}" = 64 ] || fail 'invalid digest lengths'
[ "$anchor" = "/usr/local/bin/$release" ] || fail 'invalid binary anchor'
jroot=${JAIL_ROOT:-/jails/$jail}
target=$jroot/opt/.infra-releases/$jail/$identity
active=$jroot/opt/$jail
binary=$jroot$anchor
for path in "$jroot" "$jroot/opt" "$jroot/opt/.infra-releases" "$jroot/opt/.infra-releases/$jail" "$target" "$target/bin" "$jroot/usr" "$jroot/usr/local" "$jroot/usr/local/bin"; do
 [ -d "$path" ] && [ ! -L "$path" ] || fail 'missing or redirected directory'
done
[ -f "$target/.infra-sha256" ] && [ ! -L "$target/.infra-sha256" ] \
 && [ "$(cat "$target/.infra-sha256")" = "$expected" ] || fail 'installed artifact digest mismatch'
[ -f "$target/bin/$release" ] && [ ! -L "$target/bin/$release" ] && [ -x "$target/bin/$release" ] || fail 'invalid installed executable'
unset JAIL JAIL_IP JROOT APP
jexec_bin=${JEXEC_BIN:-jexec}; mv_bin=${MV_BIN:-mv}
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
check_health() {
 sh "$script_dir/artifact_check_health.sh" "$url" "$jail" "$jail"
}
service_state() {
 if "$jexec_bin" "$jail" service "$jail" status >/dev/null 2>&1; then
  echo running
 else
  case $? in
   1)
    if [ "$service_status" = process ]; then
     # rc status failure is ambiguous here; the release's process decides.
     if ! processes=$("$jexec_bin" "$jail" ps -axo comm=) || [ -z "$processes" ]; then
      echo unknown
     elif printf '%s\n' "$processes" | awk -v name="$release" '$NF == name || substr($NF, length($NF) - length(name)) == "/" name { found=1 } END { exit !found }'; then
      echo running
     else echo stopped; fi
    else echo stopped; fi ;;
   *) echo unknown ;;
  esac
 fi
}
require_stopped() {
 remaining=10
 while :; do
  case "$(service_state)" in
   stopped) return 0 ;;
   running)
    [ "$remaining" -gt 0 ] || fail 'service still running; original retained'
    "${SLEEP_BIN:-sleep}" 1 || fail 'service wait failed; original retained'
    remaining=$((remaining - 1)) ;;
   *) fail 'service status is unknown; original retained' ;;
  esac
 done
}
if [ -L "$binary" ] && [ "$(readlink "$binary")" = "/opt/$jail/bin/$release" ] \
 && [ -L "$active" ] && [ "$(readlink "$active")" = ".infra-releases/$jail/$identity" ]; then
 case "$(service_state)" in
  running) ;;
  stopped) "$jexec_bin" "$jail" service "$jail" start || fail 'converted service start failed; original retained' ;;
  *) fail 'service status is unknown; original retained' ;;
 esac
 check_health || fail 'converted release unhealthy; original retained'
 echo "binary layout already converted and healthy: $jail"; exit 0
fi
if [ -e "$active" ] || [ -L "$active" ]; then
 [ ! -e "$binary" ] && [ ! -L "$binary" ] && [ -L "$active" ] \
  && [ "$(readlink "$active")" = ".infra-releases/$jail/$identity" ] \
  || fail 'occupied active path; refusing unknown code/state'
fi
stat_bin=${STAT_BIN:-stat}
metadata() {
 if "$stat_bin" --version >/dev/null 2>&1; then "$stat_bin" -c "$1" "$2"
 else case "$1" in '%u:%a') "$stat_bin" -f '%u:%Lp' "$2" ;; '%u:%h') "$stat_bin" -f '%u:%l' "$2" ;; esac; fi
}
code_matches() {
 [ -f "$1" ] && [ ! -L "$1" ] && [ -x "$1" ] \
 && [ "$(metadata '%u:%h' "$1")" = 0:1 ] && cmp -s "$1" "$target/bin/$release"
}
backup_root=$jroot/opt/.infra-legacy/$jail
backup=$backup_root/$identity.binary
receipt=$backup_root/$identity.binary-receipt
for path in "$jroot/opt/.infra-legacy" "$backup_root"; do
 [ ! -L "$path" ] || fail 'redirected backup path'
 if [ -e "$path" ]; then
  [ -d "$path" ] && [ "$(metadata '%u:%a' "$path")" = 0:700 ] || fail 'backup directory must be root-owned and private'
 fi
done
receipt_matches() { [ -f "$receipt" ] && [ ! -L "$receipt" ] && [ "$(cat "$receipt")" = "$expected" ]; }
if [ -e "$binary" ] || [ -L "$binary" ]; then
 code_matches "$binary" || fail 'legacy executable does not match verified artifact'
 if [ -e "$receipt" ] || [ -L "$receipt" ]; then
  receipt_matches && [ ! -e "$backup" ] && [ ! -L "$backup" ] \
   || fail 'occupied backup; inspect rather than overwrite'
  require_stopped
  "$mv_bin" "$binary" "$backup" || fail 'protected original rename failed; retry is safe'
 else
  [ ! -e "$backup" ] && [ ! -L "$backup" ] || fail 'occupied backup; inspect rather than overwrite'
  umask 077
  mkdir -p "$backup_root"
  chmod 700 "$jroot/opt/.infra-legacy" "$backup_root"
  "$jexec_bin" "$jail" service "$jail" stop || fail 'service stop failed; original retained'
  require_stopped
  code_matches "$binary" || fail 'legacy executable changed during stop; original retained'
  printf '%s\n' "$expected" >"$receipt"
  "$mv_bin" "$binary" "$backup" || fail 'protected original rename failed; retry is safe'
 fi
else
 receipt_matches && code_matches "$backup" || fail 'no matching protected interrupted-conversion receipt'
 require_stopped
fi
if [ ! -L "$active" ]; then ln -s ".infra-releases/$jail/$identity" "$active"; fi
ln -s "/opt/$jail/bin/$release" "$binary"
"$jexec_bin" "$jail" service "$jail" start || fail 'service start failed; protected original retained'
check_health || fail 'converted release unhealthy; protected original retained'
echo "binary legacy layout converted: $jail $identity"

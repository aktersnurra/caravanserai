#!/usr/bin/env bash
# _lib/check.sh, which serai check runs with each app's declared inputs, and
# the credential handling in the generated jail scripts, run directly
# against fakes. serai's own tests hold the inputs (Dispatcher's check
# environment); these hold what check_app does with them.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$tmp/bin"
cat >"$tmp/bin/ssh" <<'EOF'
#!/bin/sh
printf 'ssh|%s|%s\n' "$1" "$2" >>"$OPS_LOG"
case "$2" in
  *'service '*status) printf '%s\n' service-status ;;
  *'curl -o /dev/null -sS -w '\''%{http_code}'\'' --max-time 10 '*)
    [ "${DIRECT_FAIL:-0}" = 1 ] && exit 44
    printf '%s' "${DIRECT_STATUS:-200}" ;;
esac
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/sh
printf 'curl|%s\n' "$*" >>"$OPS_LOG"
[ "${CURL_FAIL:-0}" = 1 ] && exit 44
printf '%s' "${PUBLIC_STATUS:-200}"
EOF
chmod +x "$tmp/bin/ssh" "$tmp/bin/curl"

declare -A service=([hello]=hello [counter]=counter [store]=garage)
declare -A ip=([hello]=10.20.0.2 [counter]=10.20.0.3 [store]=10.20.0.4)
declare -A port=([hello]=4000 [counter]=4001 [store]=3900)
declare -A host=([hello]=hello.example.org [counter]=counter.example.org [store]=s3.example.org)
declare -A path=([hello]=/ [counter]=/health [store]=/)

# check_app as serai check runs it: the app's declared inputs plus
# COMPUTE_TARGET, EDGE_TARGET and CURL_BIN.
run_check() {
  OPS_LOG="$tmp/log" SSH_BIN="$tmp/bin/ssh" CURL_BIN="$tmp/bin/curl" \
    COMPUTE_TARGET=compute-test EDGE_TARGET=edge-test \
    JAIL="$1" JAIL_IP="${ip[$1]}" PORT="${port[$1]}" PUBLIC_HOST="${host[$1]}" \
    SERVICE="${service[$1]}" CHECK_PATH="${path[$1]}" \
    sh -c 'set -eu; . "$1"; check_app' sh "$root/compute/apps/_lib/check.sh"
}

# The pinned-binary strategy's generated script (its golden render) keeps
# its generated secret out of command arguments and readiness output: awk
# reads it from a file.
binary_jail="$root/serai/test/golden/strategy/fetch_binary.sh"
! grep -Eq 'log .*SESSION_KEY' "$binary_jail" || fail "${binary_jail##*/} prints a credential"
! grep -Eq -- '-(e|v) [^ ]*SESSION_KEY' "$binary_jail" || fail 'credential passed as an argument'
grep -Fq 'getline s_SESSION_KEY < (secrets_dir "/SESSION_KEY")' "$binary_jail" \
  || fail 'the binary credential is not rendered from a file'

# Checks use rc.d through compute host plus exact edge host-direct and public URLs. HTTP bodies stay captured.
for app in hello counter store; do
  : >"$tmp/log"
  run_check "$app" >"$tmp/out"
  grep -Fxq "ssh|compute-test|doas jexec ${app} service ${service[$app]} status" "$tmp/log" || fail "$app service check changed"
  grep -Fxq "ssh|edge-test|curl -o /dev/null -sS -w '%{http_code}' --max-time 10 http://${ip[$app]}:${port[$app]}${path[$app]}" "$tmp/log" || fail "$app direct check changed"
  grep -Fxq "curl|-o /dev/null -sS -w %{http_code} --max-time 10 https://${host[$app]}${path[$app]}" "$tmp/log" || fail "$app public check changed"
  [ "$(cat "$tmp/out")" = service-status ] || fail "$app check printed an HTTP response body"
done
# Authenticated roots (an S3 store's) can return 403 and still be reachable;
# failures cannot.
DIRECT_STATUS=403 PUBLIC_STATUS=403 run_check store >"$tmp/out" || fail '403 was rejected'
if DIRECT_STATUS=500 run_check store >"$tmp/out" 2>&1; then fail '500 direct response accepted'; fi
if PUBLIC_STATUS=500 run_check store >"$tmp/out" 2>&1; then fail '500 public response accepted'; fi
if DIRECT_FAIL=1 run_check store >"$tmp/out" 2>&1; then fail 'direct transport failure accepted'; fi
if CURL_FAIL=1 run_check store >"$tmp/out" 2>&1; then fail 'public transport failure accepted'; fi
! grep -Eqi 'REPLACE_ME|secret|token|password' "$tmp/out" || fail 'a check printed sensitive-looking output'

echo 'hook tests: PASS'

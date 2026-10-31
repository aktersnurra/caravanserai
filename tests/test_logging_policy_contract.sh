#!/usr/bin/env bash
set -euo pipefail
# The example configuration's logging policy, on this engine.
root=$(cd "$(dirname "$0")/.." && pwd)
config="$root/example"
[ -f "$config/logging.sexp" ] || { echo 'FAIL - logging declaration missing' >&2; exit 1; }
(cd "$root/infra" && dune build bin/main.exe)
out=$(cd "$config" && "$root/infra/_build/default/bin/main.exe" render-logging-targets)
expected=$'hello local_only\ncounter counter_service'
[ "$out" = "$expected" ] || { echo 'FAIL - rendered logging targets differ from typed declaration' >&2; exit 1; }
manifest="$root/compute/apps/_lib/logging/target-manifest.sh"
[ -f "$manifest" ] || { echo 'FAIL - remote manifest validator missing' >&2; exit 1; }
# shellcheck source=/dev/null
. "$manifest"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$out" >"$tmp/targets"
validate_logging_targets "$tmp/targets" logs || { echo 'FAIL - generated targets refused' >&2; exit 1; }
# Which app ships which sender is the typed policy's to refuse; the remote
# validator refuses anything that is not a sender name.
for invalid in 'hello Unknown' 'counter 9source' 'hello /var/log/auth.log' \
  $'counter counter_service\ncounter counter_service' 'logs local_only' 'counter local_only extra'; do
  printf '%s\n' "$invalid" >"$tmp/targets"
  if validate_logging_targets "$tmp/targets" logs >/dev/null 2>&1; then
    echo "FAIL - invalid logging manifest accepted" >&2; exit 1
  fi
done
[ ! -e "$config/apps/logs/logging-targets" ] || {
  echo 'FAIL - generated targets were checked in instead of rendered by infra' >&2; exit 1;
}
if grep -Eq "^JAILS='" "$root/compute/apps/_lib/logging/bootstrap.sh"; then
  echo 'FAIL - jail list still hardcoded in installer' >&2; exit 1
fi
if grep -Eq 'for jail in hello counter' "$config/apps/logs/check-forwarding"; then
  echo 'FAIL - jail list still hardcoded in health check' >&2; exit 1
fi
# Exercise the example's logs/check-forwarding remote script with a local, root-command stub.
# Only the installed manifest path is rewritten to a throwaway fixture.
printf '#!/bin/sh\nsed "s@targets=/usr/local/etc/central-logging/targets@targets=$LOGGING_TEST_TARGETS@" | sh -c "$2"\n' >"$tmp/ssh"
printf '#!/bin/sh\nexec "$@"\n' >"$tmp/doas"
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >>"$LOGGING_TEST_TRACE"\n' >"$tmp/jexec"
printf '#!/bin/sh\nexit 0\n' >"$tmp/service"
printf '#!/bin/sh\nexit 0\n' >"$tmp/curl"
chmod +x "$tmp/ssh" "$tmp/doas" "$tmp/jexec" "$tmp/service" "$tmp/curl"
printf 'hello local_only\n' >"$tmp/targets"
SSH_BIN="$tmp/ssh" PATH="$tmp:$PATH" \
  LOGGING_TEST_TARGETS="$tmp/targets" LOGGING_TEST_TRACE="$tmp/trace" \
  sh "$config/apps/logs/check-forwarding" offline >/dev/null || {
    echo 'FAIL - health check rejected the installed local-only manifest' >&2; exit 1;
  }
[ "$(<"$tmp/trace")" = hello ] || {
  echo 'FAIL - health check did not inspect exactly the declared jails' >&2; exit 1;
}
printf 'hello /var/log/auth.log\n' >"$tmp/targets"
if SSH_BIN="$tmp/ssh" PATH="$tmp:$PATH" \
  LOGGING_TEST_TARGETS="$tmp/targets" LOGGING_TEST_TRACE="$tmp/trace" \
  sh "$config/apps/logs/check-forwarding" offline >/dev/null 2>&1; then
  echo 'FAIL - health check accepted a tampered installed source' >&2; exit 1
fi
printf 'ok - infra renders and validates exactly the declared jail logging policies\n'

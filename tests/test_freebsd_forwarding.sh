#!/usr/bin/env bash
# Source contract only: never executes the privileged remote installer.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/compute/apps/_lib/logging"
fail() { printf 'FAIL - %s\n' "$1" >&2; exit 1; }
for name in bootstrap.sh central-logging.rc.template; do
  [ -f "$dir/$name" ] || fail "missing $name"
done
sh -n "$dir/bootstrap.sh" "$dir/central-logging.rc.template"
# The installer fills in the boot order (test_logging_bootstrap.sh); the
# engine names no app's service.
grep -qx '# __RCORDER__' "$dir/central-logging.rc.template" || fail 'rc template has no order line'
# FreeBSD's awk refuses a literal newline in a -v value, so each order is
# one line (GNU awk, here, would accept it).
grep -Eq "^render_rc '[^']*'.*\"\\\$tmp/central-logging-jail.rc\"$" "$dir/bootstrap.sh" ||
  fail 'jail rc order spans lines; FreeBSD awk refuses that'
if grep -Eq '^# (REQUIRE|BEFORE):' "$dir/central-logging.rc.template"; then
  fail 'rc template fixes its own boot order'
fi
# The host relay and jail base are rendered by infra's Logging_relay, whose
# tests pin their content; here only the installer. The engine names no app:
# every remote source comes from an app's reviewed sender.
if grep -Eq 'file\(|program\(' "$dir/bootstrap.sh"; then fail 'engine hardcodes a jail source'; fi
grep -Fq 'sh "$sender/preflight" "$ROOT/jails/$jail"' "$dir/bootstrap.sh" ||
  fail 'reviewed sender preflight not run before installing'
grep -Fq -- '--syntax-only' "$dir/bootstrap.sh" || fail 'candidate not checked before activation'
python3 - "$dir/bootstrap.sh" <<'PY'
import pathlib, sys
installer = pathlib.Path(sys.argv[1]).read_text()
# After the cleanup trap: cleanup itself restarts a replaced sender's predecessor.
main = installer.index('trap cleanup EXIT')
assert installer.rfind('--syntax-only') < installer.find('service central_logging onestart', main), \
    'a sender is started before all candidates validate'
PY
grep -Fq 'central_logging_enable' "$dir/bootstrap.sh" || fail 'dedicated service not enabled'
if grep -Fq 'syslog_ng_enable' "$dir/bootstrap.sh"; then fail 'default syslog-ng service takeover'; fi
printf 'ok - the private FreeBSD relay installs only reviewed senders and preserves local logging\n'

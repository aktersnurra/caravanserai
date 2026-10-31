#!/usr/bin/env bash
# Pure installed-state contract; never runs the privileged FreeBSD installer.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
state="$root/compute/apps/_lib/logging/installed-state.sh"
installer="$root/compute/apps/_lib/logging/bootstrap.sh"
fail() { echo "FAIL - $*" >&2; exit 1; }
[ -f "$state" ] || fail 'missing installed-state helper'
# shellcheck source=/dev/null
. "$state"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'private receiver\n' >"$tmp/expected-config"
printf 'dedicated rc\n' >"$tmp/expected-rc"
printf 'redactor\n' >"$tmp/expected-gate"
cp "$tmp/expected-config" "$tmp/config"
cp "$tmp/expected-rc" "$tmp/rc"
cp "$tmp/expected-gate" "$tmp/gate"
args=("$tmp/expected-config" "$tmp/config" "$tmp/expected-rc" "$tmp/rc" "$tmp/expected-gate" "$tmp/gate")
[ "$(installed_logging_state yes YES "${args[@]}")" = ready ] || fail 'matching active service not resumable'
[ "$(installed_logging_state no NO "${args[@]}")" = install ] || fail 'matching stopped service cannot restart'
for target in config rc gate; do
  cp "$tmp/$target" "$tmp/save"
  printf 'operator modification\n' >"$tmp/$target"
  # Drift is reported, for only a deliberate replace to overwrite.
  [ "$(installed_logging_state yes YES "${args[@]}")" = differs ] || fail "active $target drift not reported"
  [ "$(installed_logging_state no NO "${args[@]}")" = differs ] || fail "stopped $target drift not reported"
  mv "$tmp/save" "$tmp/$target"
done
ln -s "$tmp/config" "$tmp/linked"
if installed_logging_state yes YES "$tmp/expected-config" "$tmp/linked" >/dev/null 2>&1; then
  fail 'linked active config accepted'
fi
for state in 'yes NO' 'no YES'; do
  read -r active enabled <<<"$state"
  if installed_logging_state "$active" "$enabled" "${args[@]}" >/dev/null 2>&1; then
    fail "inconsistent service status $state accepted"
  fi
done
rm "$tmp/config" "$tmp/rc" "$tmp/gate"
[ "$(installed_logging_state no NO "${args[@]}")" = install ] || fail 'fresh service cannot install'
# A partial install is never reported as replaceable.
printf 'operator modification\n' >"$tmp/config"
if installed_logging_state no NO "${args[@]}" >/dev/null 2>&1; then
  fail 'a partial install accepted'
fi
grep -Fq 'installed_logging_state' "$installer" || fail 'installer does not use the state gate'
grep -Fq 'ready_instances' "$installer" || fail 'installer cannot skip verified active senders'
python3 - "$installer" <<'PY'
from pathlib import Path
import sys
installer = Path(sys.argv[1]).read_text()
start = installer.index('for instance in $to_install; do')
assert start < installer.index('pkg install -y syslog-ng'), \
    'matching active senders still receive package operations on retry'
PY
python3 - "$root" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
# The example guest's sender stands for any guest's.
for relative, side_effect in [
    ('example/guests/ledger/logging', 'apt-get update'),
    ('edge/03-logging', 'pacman -S --needed'),
    ('edge/04-vmui-auth', 'curl --fail'),
]:
    script = (root / relative).read_text()
    assert script.index('systemctl is-active --quiet') < script.index(side_effect), \
        f'{relative}: active sender modified before the retry guard'
    assert script.index('cmp -s') < script.index(side_effect), \
        f'{relative}: active sender config drift not checked first'
PY
printf 'ok - matching senders can resume; drift is reported and partial or inconsistent states fail closed\n'

#!/usr/bin/env bash
# Runs the real compute host logging installer against a fake root: the host and two
# jails as directories, with stub service, sysrc, jexec, jls, ifconfig, pkg
# and syslog-ng that keep each instance's state in files. Synthetic configs
# only; no real host, jail or log is touched.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL - %s\n' "$1" >&2; exit 1; }

fake="$tmp/root" state="$tmp/state" bin="$tmp/bin" stage="$tmp/stage/compute/apps"
mkdir -p "$state" "$bin" "$stage/collector"
for r in "$fake" "$fake/jails/alpha" "$fake/jails/beta" "$fake/jails/collector"; do mkdir -p "$r/usr/local/etc/rc.d"; done
cp -R "$root/compute/apps/_lib" "$stage/_lib"
printf 'alpha local_only\nbeta beta_service\n' >"$stage/collector/logging-targets"
# What infra renders from the declarations, staged beside the targets.
printf '@version: 4.12\n# host relay\n' >"$stage/collector/syslog-ng-host.conf"
printf '@version: 4.12\n# jail sender\n' >"$stage/collector/syslog-ng-jail.conf"
printf '10.40.0.254\n' >"$stage/collector/guest-bridge"
mkdir -p "$stage/beta/logging/beta_service/etc"
printf 'source s_reviewed_file { file("/var/log/beta.log"); };\n' >"$stage/beta/logging/beta_service/sender.conf"
printf 'gate v1\n' >"$stage/beta/logging/beta_service/etc/beta-gate.awk"

# An instance is host or a jail; its root is the fake root or the jail's dir.
cat >"$bin/instance-root" <<'EOF'
#!/bin/sh
if [ "${LOGGING_INSTANCE:-host}" = host ]; then printf '%s\n' "$FAKE_ROOT"
else printf '%s/jails/%s\n' "$FAKE_ROOT" "$LOGGING_INSTANCE"; fi
EOF
cat >"$bin/service" <<'EOF'
#!/bin/sh
i=${LOGGING_INSTANCE:-host}
[ "$1" = central_logging ] || exit 1
printf '%s %s\n' "$i" "$2" >>"$STATE_DIR/events"
case "$2" in
  onestatus) [ "$(cat "$STATE_DIR/$i.active" 2>/dev/null)" = yes ] ;;
  onestart)
    # A planted marker fails the next start once: the new config's.
    if [ -e "$STATE_DIR/$i.fail-next-start" ]; then rm "$STATE_DIR/$i.fail-next-start"; exit 1; fi
    echo yes >"$STATE_DIR/$i.active"
    # What the started sender runs with.
    cp "$(instance-root)/usr/local/etc/central-logging/syslog-ng.conf" "$STATE_DIR/$i.running" ;;
  onestop) echo no >"$STATE_DIR/$i.active" ;;
  *) exit 1 ;;
esac
EOF
cat >"$bin/sysrc" <<'EOF'
#!/bin/sh
i=${LOGGING_INSTANCE:-host}
case "$*" in
  '-n central_logging_enable') cat "$STATE_DIR/$i.enabled" 2>/dev/null || exit 1 ;;
  central_logging_enable=*) printf '%s\n' "${1#*=}" >"$STATE_DIR/$i.enabled" ;;
  *) exit 1 ;;
esac
EOF
cat >"$bin/jexec" <<'EOF'
#!/bin/sh
jail=$1; shift
case "$1" in /usr/local/sbin/syslog-ng) exit 0 ;; esac
LOGGING_INSTANCE=$jail exec "$@"
EOF
printf '#!/bin/sh\nexit 0\n' >"$bin/pkg"
printf '#!/bin/sh\nexit 0\n' >"$bin/jls"
printf '#!/bin/sh\nexit 0\n' >"$bin/syslog-ng"
printf '#!/bin/sh\necho 0\n' >"$bin/id"
printf '#!/bin/sh\nprintf "\\tinet 10.40.0.254 netmask 0xffffff00\\n"\n' >"$bin/ifconfig"
chmod +x "$bin"/*

run() {
  PATH="$bin:$PATH" FAKE_ROOT="$fake" STATE_DIR="$state" CENTRAL_LOGGING_ROOT="$fake" \
    SYSLOG_NG_BIN="$bin/syslog-ng" sh "$stage/_lib/logging/bootstrap.sh" collector "$@"
}
conf() { if [ "$1" = host ]; then printf '%s\n' "$fake/usr/local/etc/central-logging/syslog-ng.conf"
  else printf '%s\n' "$fake/jails/$1/usr/local/etc/central-logging/syslog-ng.conf"; fi; }
snapshot() { (cd "$fake" && find . -type f | sort | xargs sha256sum) >"$1"; }

for args in '' 'Collector' 'collector --force' 'collector --replace extra'; do
  # shellcheck disable=SC2086 # each case is its argument list
  if PATH="$bin:$PATH" FAKE_ROOT="$fake" STATE_DIR="$state" CENTRAL_LOGGING_ROOT="$fake" \
      SYSLOG_NG_BIN="$bin/syslog-ng" sh "$stage/_lib/logging/bootstrap.sh" $args >/dev/null 2>&1; then
    fail "bootstrap.sh accepted the arguments '$args'"
  fi
done
[ ! -e "$state/events" ] || fail 'a refused invocation touched a sender'
run >/dev/null || fail 'a fresh install failed'
for i in host alpha beta; do
  [ "$(cat "$state/$i.active")" = yes ] && [ "$(cat "$state/$i.enabled")" = YES ] ||
    fail "$i is not running and enabled after a fresh install"
done
[ "$(cat "$fake/jails/beta/usr/local/etc/central-logging/beta-gate.awk")" = 'gate v1' ] ||
  fail "beta's reviewed sender file is not installed"
# A jail's logger owns its syslog socket: it starts before any service, all
# of which require NETWORKING. The host relay listens on the guest bridge,
# which vm creates.
rc() { if [ "$1" = host ]; then printf '%s\n' "$fake/usr/local/etc/rc.d/central_logging"
  else printf '%s\n' "$fake/jails/$1/usr/local/etc/rc.d/central_logging"; fi; }
for i in alpha beta; do
  grep -qx '# REQUIRE: FILESYSTEMS' "$(rc "$i")" && grep -qx '# BEFORE: NETWORKING' "$(rc "$i")" ||
    fail "$i's logger does not start before its services"
done
grep -qx '# REQUIRE: NETWORKING vm' "$(rc host)" || fail 'the host relay may start before the guest bridge'
! grep -q '^# BEFORE:' "$(rc host)" || fail 'the host relay orders itself before services it does not serve'
! grep -q '__RCORDER__' "$(rc host)" "$(rc alpha)" || fail 'an rc script was installed unrendered'

: >"$state/events"
out=$(run) || fail 'a matching rerun failed'
grep -Fq 'preserving matching active senders: host alpha beta' <<<"$out" || fail 'a matching rerun did not preserve the senders'
! grep -Eq 'onestart|onestop' "$state/events" || fail 'a matching rerun restarted a sender'

# Changed declarations: the host and both jail configs now differ.
printf '# v2\n' >>"$stage/collector/syslog-ng-jail.conf"
printf '# v2\n' >>"$stage/collector/syslog-ng-host.conf"
snapshot "$tmp/before"
: >"$state/events"
if run >"$tmp/out" 2>&1; then fail 'drift was overwritten without --replace'; fi
grep -Fq 'replace' "$tmp/out" || fail 'refused drift does not point at the deliberate replace'
snapshot "$tmp/after"
cmp -s "$tmp/before" "$tmp/after" || fail 'a refused run changed installed files'
! grep -Eq 'onestart|onestop' "$state/events" || fail 'a refused run touched a sender'

# A replace whose last start fails puts every sender back as it was.
cp "$(conf beta)" "$tmp/beta-v1"
touch "$state/beta.fail-next-start"
if run --replace >/dev/null 2>&1; then fail 'a failed replace reported success'; fi
snapshot "$tmp/rolled-back"
cmp -s "$tmp/before" "$tmp/rolled-back" || fail 'a failed replace did not restore every managed file'
for i in host alpha beta; do
  [ "$(cat "$state/$i.active")" = yes ] && [ "$(cat "$state/$i.enabled")" = YES ] ||
    fail "$i is not running and enabled after a failed replace"
done
cmp -s "$state/beta.running" "$tmp/beta-v1" || fail 'beta does not run its previous config after a failed replace'

# The deliberate replace: each differing sender is stopped, replaced and started.
: >"$state/events"
run --replace >/dev/null || fail 'a replace failed'
for i in host alpha beta; do
  grep -Fq '# v2' "$(conf "$i")" || fail "$i's config was not replaced"
  grep -Fq '# v2' "$state/$i.running" || fail "$i does not run the replaced config"
  [ "$(cat "$state/$i.enabled")" = YES ] || fail "$i is not enabled after a replace"
done
[ "$(grep -n 'host onestop' "$state/events" | cut -d: -f1)" -lt "$(grep -n 'host onestart' "$state/events" | cut -d: -f1)" ] ||
  fail 'the host relay was not stopped before it was replaced'
out=$(run) || fail 'a rerun after a replace failed'
grep -Fq 'preserving matching active senders: host alpha beta' <<<"$out" || fail 'a replace did not converge'

# The relay listens on the declared bridge only if the host has it; a host
# without guests has no bridge to check.
printf '10.40.0.99\n' >"$stage/collector/guest-bridge"
if run >/dev/null 2>&1; then fail 'a missing guest bridge address was accepted'; fi
: >"$stage/collector/guest-bridge"
run --replace >/dev/null || fail 'a host without guests was refused'
grep -qx '# REQUIRE: NETWORKING' "$(rc host)" || fail 'a host relay without guests still waits for vm'
printf '10.40.0.254\n' >"$stage/collector/guest-bridge"
run --replace >/dev/null || fail 'a host regaining guests was refused'

# Partial or unmanaged state stays refused, replace or not.
rm "$fake/jails/beta/usr/local/etc/central-logging/beta-gate.awk"
if run --replace >/dev/null 2>&1; then fail 'a partially installed sender was replaced'; fi
printf 'ok - the compute host logging installer converges, refuses drift, and replaces only on request with rollback\n'

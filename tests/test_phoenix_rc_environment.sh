#!/usr/bin/env bash
# Exercise the generated Phoenix rc script (its golden render) with synthetic
# values only; never a jail env. What the env file sets must still be
# exported when the service runs su -m.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' PHX_SERVER=true PHX_HOST=public_fixture_only PORT=4000 \
    DATABASE_PATH=public_fixture_only POOL_SIZE=5 LANG=C.UTF-8 \
    SECRET_KEY_BASE=public_fixture_only RELEASE_COOKIE=public_fixture_only \
    RELEASE_TMP=public_fixture_only ENVIRONMENT_PROOF=public_fixture_only >"$TMP/fixture"
cat >"$TMP/subr" <<'SUBR'
load_rc_config() { :; }
mkdir() { :; }
chown() { :; }
su() { [ "${ENVIRONMENT_PROOF-unset}" = public_fixture_only ] && [ "${HOME-}" = /var/db/hello ]; }
run_rc_command() { hello_start; }
SUBR
sed -e "s|/etc/rc.subr|$TMP/subr|" \
    -e "s|/etc/hello/env|$TMP/fixture|g" \
    -e "s|/var/log/hello/hello.log|$TMP/service.log|g" \
    "$ROOT/infra/test/golden/strategy/rc_hello.sh" >"$TMP/service"
grep -Fq "$TMP/fixture" "$TMP/service"
env -u RELEASE_COOKIE -u ENVIRONMENT_PROOF sh "$TMP/service" start
echo 'ok - Phoenix rc keeps sourced fixture environment in the service shell'

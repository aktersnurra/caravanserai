#!/usr/bin/env bash
# Source contract: the host setup scripts and the shared app check carry no
# private address of their own; each value comes from the operator, or from
# infra, out of the declarations. Never runs the scripts.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fail() { printf 'FAIL - %s\n' "$1" >&2; exit 1; }
base="$root/compute/01-base" bhyve="$root/compute/02-bhyve"
headscale="$root/edge/00-headscale" check="$root/compute/apps/_lib/check.sh"
tailscale="$root/edge/01-tailscale"
for script in "$base" "$bhyve" "$headscale" "$check" "$tailscale" "$root/edge/01-headscale-policy" \
              "$root/edge/02-caddy" "$root/edge/03-logging" "$root/edge/04-vmui-auth"; do
  # An address in an "e.g." of a usage message is an example, not a value.
  if grep -nE '(^|[^0-9.])(10\.[0-9]|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' "$script" | grep -v 'e\.g\.'; then
    fail "${script#"$root"/} names a private address"
  fi
done
requires() {
  local script=$1; shift
  for var in "$@"; do
    grep -Fq "${var}=\"\${${var}:?" "$script" || fail "${script#"$root"/} does not require $var"
  done
}
requires "$base" HEADSCALE_URL PREAUTH_KEY SSH_PUBKEY ADMIN_USER LAN_NET JAIL_SUBNET JAIL_GATEWAY
requires "$bhyve" JAIL_SUBNET GUEST_BRIDGE
requires "$headscale" HEADSCALE_DOMAIN BASE_DOMAIN HEADSCALE_USER
requires "$tailscale" HEADSCALE_URL PREAUTH_KEY
# infra check always passes both targets; a default would only hide a caller
# that forgot them.
for var in COMPUTE_TARGET EDGE_TARGET; do
  grep -Fq ": \"\${${var}:?" "$check" || fail "check.sh does not require $var"
done
printf 'ok - the host scripts and app check require every personal value\n'

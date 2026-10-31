#!/usr/bin/env bash
# The three edge scripts' <X>_DIFF_ONLY=1 mode: validate, print a diff of
# live vs candidate, exit 0 when current and 10 when changes are pending,
# and never touch the live file.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$tmp/bin"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/pfctl"
# FreeBSD's awk (the compute host's) rejects a -v value containing a newline; GNU awk
# does not, so this stand-in enforces the stricter rule before delegating.
real_awk=$(command -v awk)
cat >"$tmp/bin/awk" <<EOF_AWK
#!/usr/bin/env bash
prev=
for arg in "\$@"; do
  case "\$prev:\$arg" in
    -v:*\$'\n'*)
      echo "awk: newline in string (FreeBSD awk rejects multi-line -v values)" >&2
      exit 2 ;;
  esac
  prev=\$arg
done
exec "$real_awk" "\$@"
EOF_AWK
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/caddy"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/systemctl"
chmod +x "$tmp/bin/"*
# Plan mode prints only a diff or one "already current" line: no install
# wording, no caddy validate JSON.
quiet_plan() {
  ! grep -Eq 'Installing|rendered by the caller|"level"|validated|Tailscale address|not building' "$tmp/out" "$tmp/err" ||
    fail "$1: plan mode printed install chatter: $(cat "$tmp/out" "$tmp/err")"
}
expect_exit() { # expect_exit <code> <description> <command...>
  local want=$1 what=$2 got=0
  shift 2
  "$@" >"$tmp/out" 2>"$tmp/err" || got=$?
  [ "$got" = "$want" ] || { cat "$tmp/err" >&2; fail "$what: exit $got, want $want"; }
}

# --- pf ----------------------------------------------------------------
begin='# BEGIN generated service rules (nuc/01-pf-rules)'
end='# END generated service rules'
printf '%s\n' 'set skip on lo' "$begin" 'pass in on $ts_if proto tcp from 100.64.0.1 to 10.40.0.2 port 4000 keep state  # drill' "$end" >"$tmp/pf.conf"
cp "$tmp/pf.conf" "$tmp/pf.conf.orig"
printf '%s\n' 'pass in on $ts_if proto tcp from __EDGE__ to 10.40.0.2 port 4000 keep state  # drill' >"$tmp/rules.same"
printf '%s\n' 'pass in on $ts_if proto tcp from __EDGE__ to 10.40.0.2 port 4001 keep state  # drill' >"$tmp/rules.new"
pf() { PATH="$tmp/bin:$PATH" PF_CONF="$tmp/pf.conf" EDGE_TS_IP=100.64.0.1 PF_DIFF_ONLY=1 PF_SOURCE="$1" sh "$root/compute/01-pf-rules"; }
expect_exit 0 'pf: current rules' pf "$tmp/rules.same"
quiet_plan pf
expect_exit 10 'pf: changed rules' pf "$tmp/rules.new"
grep -Fq '+pass in on $ts_if proto tcp from 100.64.0.1 to 10.40.0.2 port 4001' "$tmp/out" || fail 'pf: diff missing the added rule'
cmp -s "$tmp/pf.conf" "$tmp/pf.conf.orig" || fail 'pf: diff-only mode modified pf.conf'

# Several rules in the anchored block: the shape that broke on the compute host.
two='pass in on $ts_if proto tcp from __EDGE__ to 10.40.0.3 port 4001 keep state  # board'
printf '%s\n' 'set skip on lo' "$begin" \
  'pass in on $ts_if proto tcp from 100.64.0.1 to 10.40.0.2 port 4000 keep state  # drill' \
  'pass in on $ts_if proto tcp from 100.64.0.1 to 10.40.0.3 port 4001 keep state  # board' \
  "$end" >"$tmp/pf.conf"
printf '%s\n' 'pass in on $ts_if proto tcp from __EDGE__ to 10.40.0.2 port 4000 keep state  # drill' "$two" >"$tmp/rules.multi"
expect_exit 0 'pf: several current rules' pf "$tmp/rules.multi"
printf '%s\n' 'pass in on $ts_if proto tcp from __EDGE__ to 10.40.0.2 port 4002 keep state  # drill' "$two" >"$tmp/rules.multi"
expect_exit 10 'pf: several rules, one changed' pf "$tmp/rules.multi"
grep -Fq '+pass in on $ts_if proto tcp from 100.64.0.1 to 10.40.0.2 port 4002' "$tmp/out" || fail 'pf: multi-rule diff missing the changed rule'
ls "$tmp" | grep -q 'pf.conf.backup' && fail 'pf: diff-only mode wrote a backup'

# --- headscale policy ---------------------------------------------------
printf '%s\n' '{ "acls": [] }' >"$tmp/acls.yaml"
cp "$tmp/acls.yaml" "$tmp/acls.yaml.orig"
printf '%s\n' '{ "acls": [] }' >"$tmp/policy.same"
printf '%s\n' '{ "acls": [ { "action": "accept" } ] }' >"$tmp/policy.new"
policy() { PATH="$tmp/bin:$PATH" POLICY_FILE="$tmp/acls.yaml" POLICY_DIFF_ONLY=1 POLICY_SOURCE="$1" bash "$root/edge/01-headscale-policy"; }
expect_exit 0 'policy: current' policy "$tmp/policy.same"
quiet_plan policy
expect_exit 10 'policy: changed' policy "$tmp/policy.new"
grep -Fq '"action": "accept"' "$tmp/out" || fail 'policy: diff missing the new rule'
cmp -s "$tmp/acls.yaml" "$tmp/acls.yaml.orig" || fail 'policy: diff-only mode modified the policy'

# --- caddy --------------------------------------------------------------
mkdir -p "$tmp/caddy/conf.d" "$tmp/source/conf.d"
printf '%s\n' 'VIDEO_SECRET=synthetic-test-value' >"$tmp/caddy/secrets.env"
printf '%s\n' 'import conf.d/*.caddy' >"$tmp/caddy/Caddyfile"
printf '%s\n' 'demo.example.org {' '}' >"$tmp/caddy/conf.d/40-demo.caddy"
cp "$tmp/caddy/Caddyfile" "$tmp/source/Caddyfile"
cp "$tmp/caddy/conf.d/40-demo.caddy" "$tmp/source/conf.d/40-demo.caddy"
caddy_diff() { PATH="$tmp/bin:$PATH" CADDY_DIR="$tmp/caddy" CADDY_UNIT_FILE="$tmp/unit" CADDY_DIFF_ONLY=1 CADDY_SOURCE="$tmp/source" bash "$root/edge/02-caddy"; }
expect_exit 0 'caddy: current' caddy_diff
quiet_plan caddy
printf '%s\n' 'demo.example.org {' '    respond "new"' '}' >"$tmp/source/conf.d/40-demo.caddy"
expect_exit 10 'caddy: changed' caddy_diff
grep -Fq '+    respond "new"' "$tmp/out" || fail 'caddy: diff missing the changed line'
[ ! -e "$tmp/unit" ] || fail 'caddy: diff-only mode wrote the systemd unit'
ls "$tmp" | grep -q 'caddy.backup' && fail 'caddy: diff-only mode wrote a backup'
grep -Fxq 'demo.example.org {' "$tmp/caddy/conf.d/40-demo.caddy" && ! grep -q respond "$tmp/caddy/conf.d/40-demo.caddy" || fail 'caddy: diff-only mode modified live config'

echo 'edge diff modes: PASS'

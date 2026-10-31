#!/usr/bin/env bash
# edge/02-caddy's CADDY_SOURCE: installs a tree rendered elsewhere (serai
# edge, serai caddy-install) through the validate/backup/rollback path,
# refuses an incomplete or unsubstituted tree before touching the live
# config, and refuses to run at all without one.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/edge/02-caddy"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$tmp/caddy" "$tmp/bin" "$tmp/source/conf.d"
printf '%s\n' 'VIDEO_SECRET=synthetic-test-value' >"$tmp/caddy/secrets.env"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/caddy"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/systemctl"
cat >"$tmp/bin/install" <<'EOF'
#!/usr/bin/env bash
set -eu
args=()
dir_mode=0
while [ $# -gt 0 ]; do
  case "$1" in
    -d) dir_mode=1; shift ;;
    -o | -g | -m) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
if [ "$dir_mode" = 1 ]; then mkdir -p "${args[@]}"; exit 0; fi
dest="${args[-1]}"
unset 'args[-1]'
if [ -d "$dest" ]; then cp "${args[@]}" "$dest/"; else cp "${args[0]}" "$dest"; fi
EOF
chmod +x "$tmp/bin/"*
run() {
  PATH="$tmp/bin:$PATH" CADDY_DIR="$tmp/caddy" CADDY_UNIT_FILE="$tmp/unit" \
    CADDY_SKIP_BUILD=1 CADDY_SKIP_SETUP=1 CADDY_SOURCE="$1" bash "$script"
}

# Without CADDY_SOURCE there is nothing to install: the script fails naming
# the serai commands, before reading secrets, building, or touching the live
# config. secrets.env is moved aside to prove the check comes first.
mkdir -p "$tmp/spy"
for tool in caddy systemctl install; do
  printf '#!/bin/sh\necho %s >>"%s/called"\nexit 0\n' "$tool" "$tmp" >"$tmp/spy/$tool"
done
chmod +x "$tmp/spy/"*
printf '%s\n' keep-me >"$tmp/caddy/Caddyfile"
mv "$tmp/caddy/secrets.env" "$tmp/secrets.env"
if PATH="$tmp/spy:$PATH" CADDY_DIR="$tmp/caddy" CADDY_UNIT_FILE="$tmp/unit" \
  CADDY_SKIP_BUILD=1 CADDY_SKIP_SETUP=1 env -u CADDY_SOURCE bash "$script" >"$tmp/out" 2>&1; then
  fail 'ran without CADDY_SOURCE'
fi
grep -Fq 'ERROR: CADDY_SOURCE is required; run serai edge (config) or serai caddy-install (build/unit/first install)' "$tmp/out" ||
  fail "missing-CADDY_SOURCE diagnostic absent: $(cat "$tmp/out")"
[ ! -e "$tmp/called" ] || fail "ran $(tr '\n' ' ' <"$tmp/called")without CADDY_SOURCE"
grep -Fxq keep-me "$tmp/caddy/Caddyfile" || fail 'live Caddyfile touched without CADDY_SOURCE'
[ ! -e "$tmp/unit" ] || fail 'unit written without CADDY_SOURCE'
! ls "$tmp" | grep -q 'caddy.backup' || fail 'backup written without CADDY_SOURCE'
rm -f "$tmp/caddy/Caddyfile"
mv "$tmp/secrets.env" "$tmp/caddy/secrets.env"

# A complete tree is installed verbatim, not re-rendered from the templates.
printf '%s\n' 'import conf.d/*.caddy' '# from-source' >"$tmp/source/Caddyfile"
printf '%s\n' 'demo.example.org {' '    respond "from-source"' '}' >"$tmp/source/conf.d/40-demo.caddy"
run "$tmp/source" >"$tmp/out" 2>&1 || { cat "$tmp/out" >&2; fail 'complete source rejected'; }
grep -Fxq '# from-source' "$tmp/caddy/Caddyfile" || fail 'Caddyfile not taken from CADDY_SOURCE'
[ -f "$tmp/caddy/conf.d/40-demo.caddy" ] || fail 'fragment not taken from CADDY_SOURCE'
[ ! -e "$tmp/caddy/conf.d/40-drill.caddy" ] || fail 'templates were rendered despite CADDY_SOURCE'

# Missing directory, missing Caddyfile, empty conf.d: refused before install.
printf '%s\n' keep-me >"$tmp/caddy/Caddyfile"
if run "$tmp/absent" >"$tmp/out" 2>&1; then fail 'missing CADDY_SOURCE accepted'; fi
grep -Fq 'has no Caddyfile' "$tmp/out" || fail 'missing-source diagnostic absent'
mkdir -p "$tmp/empty/conf.d"; printf '%s\n' 'import conf.d/*.caddy' >"$tmp/empty/Caddyfile"
if run "$tmp/empty" >"$tmp/out" 2>&1; then fail 'empty conf.d accepted'; fi
grep -Fq 'has no conf.d/*.caddy' "$tmp/out" || fail 'empty-conf.d diagnostic absent'
grep -Fxq keep-me "$tmp/caddy/Caddyfile" || fail 'live Caddyfile touched by a refused source'

# An unsubstituted placeholder is still caught by the existing grep gate.
mkdir -p "$tmp/leftover/conf.d"
printf '%s\n' 'import conf.d/*.caddy' >"$tmp/leftover/Caddyfile"
printf '%s\n' '__DEMO_HOSTNAME__ {' '}' >"$tmp/leftover/conf.d/40-demo.caddy"
if run "$tmp/leftover" >"$tmp/out" 2>&1; then fail 'unsubstituted placeholder accepted'; fi
grep -Fq 'unsubstituted placeholders' "$tmp/out" || fail 'placeholder diagnostic absent'
grep -Fxq keep-me "$tmp/caddy/Caddyfile" || fail 'live Caddyfile touched by a leftover placeholder'

echo 'caddy CADDY_SOURCE tests: PASS'

#!/usr/bin/env bash
# Isolated assertions for secret loading, literal rejection, and rollback wiring.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/edge/02-caddy"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# Tests are intentionally synthetic; no live Caddy config or secret is read.
mkdir -p "$tmp/caddy" "$tmp/bin" "$tmp/source/conf.d"
cat > "$tmp/bin/caddy" <<EOF_CADDY
#!/bin/sh
touch "$tmp/validated"
exit 42
EOF_CADDY
chmod +x "$tmp/bin/caddy"
# The tree infra renders and stages; 02-caddy installs only such a tree.
printf '%s\n' 'import conf.d/*.caddy' >"$tmp/source/Caddyfile"
printf '%s\n' 'demo.example.org {' '    reverse_proxy 10.40.0.2:4002 {' '        header_up X-Video-Secret "{$VIDEO_SECRET}"' '    }' '}' >"$tmp/source/conf.d/40-demo.caddy"
run() { PATH="$tmp/bin:$PATH" CADDY_DIR="$tmp/caddy" CADDY_SOURCE="$tmp/source" CADDY_SKIP_BUILD=1 CADDY_SKIP_SETUP=1 "$script"; }
# Missing and empty files must fail even when the caller inherited a secret.
if VIDEO_SECRET=inherited run >"$tmp/out" 2>&1; then fail 'missing file accepted'; fi
grep -Fq 'missing or unreadable' "$tmp/out" || fail 'missing-file diagnostic absent'
: > "$tmp/caddy/secrets.env"
if VIDEO_SECRET=inherited run >"$tmp/out" 2>&1; then fail 'empty file accepted via inherited secret'; fi
grep -Fq 'must define a nonempty VIDEO_SECRET' "$tmp/out" || fail 'empty-file diagnostic absent'
printf '%s\n' 'VIDEO_SECRET=synthetic-test-value' > "$tmp/caddy/secrets.env"
if VIDEO_SECRET=inherited run >"$tmp/out" 2>&1; then fail 'validation failure unexpectedly succeeded'; fi
[ -f "$tmp/validated" ] || fail 'valid file was not exported to validation'
# Inject activation failure after install and verify root, fragments, and unit roll back.
printf '%s\n' old-root > "$tmp/caddy/Caddyfile"
mkdir -p "$tmp/caddy/conf.d"; printf '%s\n' old-fragment > "$tmp/caddy/conf.d/old.caddy"
printf '%s\n' old-unit > "$tmp/unit"
cat > "$tmp/bin/caddy" <<'EOF_CADDY'
#!/bin/sh
exit 0
EOF_CADDY
cat > "$tmp/bin/install" <<'EOF_INSTALL'
#!/usr/bin/env bash
set -eu
if [ "$1" = -d ]; then mkdir -p "${@: -1}"; exit 0; fi
last="${@: -1}"; prev="${@: -2:1}"
if [ -d "$last" ]; then cp "$prev" "$last/"; else cp "$prev" "$last"; fi
EOF_INSTALL
cat > "$tmp/bin/systemctl" <<'EOF_SYSTEMCTL'
#!/bin/sh
case "$1" in is-active) exit 1 ;; start) exit 1 ;; *) exit 0 ;; esac
EOF_SYSTEMCTL
chmod +x "$tmp/bin/caddy" "$tmp/bin/install" "$tmp/bin/systemctl"
if PATH="$tmp/bin:$PATH" CADDY_DIR="$tmp/caddy" CADDY_UNIT_FILE="$tmp/unit" CADDY_SKIP_BUILD=1 CADDY_SKIP_SETUP=1 run >"$tmp/out" 2>&1; then fail 'activation failure accepted'; fi
grep -Fxq old-root "$tmp/caddy/Caddyfile" || fail 'root was not rolled back'
grep -Fxq old-fragment "$tmp/caddy/conf.d/old.caddy" || fail 'fragments were not rolled back'
grep -Fxq old-unit "$tmp/unit" || fail 'unit was not rolled back'
grep -Fq 'rollback_armed=1' "$script" || fail 'rollback is not armed before install'
grep -Fq 'CADDY_UNIT_FILE' "$script" || fail 'unit rollback is not covered'
echo 'caddy lifecycle regression tests: PASS'

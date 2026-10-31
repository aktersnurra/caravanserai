#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -m 700 "$TMP/store"
cat >"$TMP/ssh" <<'EOF'
#!/bin/sh
printf 'remote\n' >>"$REMOTE_LOG"
exit 1
EOF
chmod +x "$TMP/ssh"
(cd "$ROOT/serai" && dune build bin/main.exe)
CLI="$ROOT/serai/_build/default/bin/main.exe"
# The example configuration, on this engine.
cd "$ROOT/example"
for app in hello logs counter; do
for mode in upgrade rollback convert; do
 if SSH_BIN="$TMP/ssh" REMOTE_LOG="$TMP/remote" "$CLI" artifact "$mode" "$app" \
  --identity "$(printf 'a%.0s' {1..64})" --store "$TMP/store" --yes >"$TMP/error" 2>&1; then exit 1; fi
 if ! grep -Fq 'artifact store: cannot load entry' "$TMP/error"; then
  echo "FAIL - $mode must select a verified store entry before remote work" >&2
  exit 1
 fi
 test ! -e "$TMP/remote"
done
done
echo 'ok - upgrade, rollback and conversion select a verified store entry before host work'

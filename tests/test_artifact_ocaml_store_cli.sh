#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -m 700 "$TMP/store"
printf 'public base fixture\n' >"$TMP/base.txz"
cat >"$TMP/remote" <<'EOF'
#!/bin/sh
printf 'unexpected remote/source call\n' >>"$CALLS"
exit 1
EOF
chmod +x "$TMP/remote"
(cd "$ROOT/serai" && dune build bin/main.exe)
CLI="$ROOT/serai/_build/default/bin/main.exe"
# The example configuration, on this engine.
cd "$ROOT/example"
if SSH_BIN="$TMP/remote" JJ_BIN="$TMP/remote" CALLS="$TMP/calls" "$CLI" \
 artifact build counter --revision "$(printf '1%.0s' {1..40})" --ip 10.20.0.200 \
 --base "$TMP/base.txz" --sha256 "$(printf '0%.0s' {1..64})" --store "$TMP/store" \
 --opam-repository "$TMP/repository" --opam-revision "$(printf '2%.0s' {1..40})" --yes >"$TMP/result" 2>&1; then
 echo 'FAIL - invalid base accepted' >&2; exit 1
fi
if ! grep -Fq 'base archive SHA-256 mismatch' "$TMP/result"; then
 echo 'FAIL - OCaml CLI must accept immutable repository inputs and validate base before source/host work' >&2; exit 1
fi
test ! -e "$TMP/calls"
echo 'ok - OCaml build accepts immutable repository inputs and rejects a mismatched base before source/host work'

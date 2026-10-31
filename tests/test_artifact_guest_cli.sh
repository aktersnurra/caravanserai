#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -m 700 "$TMP/store"
cat >"$TMP/remote" <<'EOF'
#!/bin/sh
printf 'unexpected source/host work\n' >>"$CALLS"
exit 1
EOF
chmod +x "$TMP/remote"
(cd "$ROOT/infra" && dune build bin/main.exe)
CLI="$ROOT/infra/_build/default/bin/main.exe"
# The example configuration, on this engine.
cd "$ROOT/example"
for mode in upgrade rollback convert; do
 if SSH_BIN="$TMP/remote" JJ_BIN="$TMP/remote" CALLS="$TMP/calls" "$CLI" \
  artifact "$mode" ledger --identity "$(printf 'a%.0s' {1..64})" --store "$TMP/store" --yes >"$TMP/result" 2>&1; then exit 1; fi
 if ! grep -Fq 'artifact store: cannot load entry' "$TMP/result"; then
  echo "FAIL - guest $mode must select a verified artifact before host work" >&2; exit 1
 fi
 test ! -e "$TMP/calls"
done
if SSH_BIN="$TMP/remote" JJ_BIN="$TMP/remote" CALLS="$TMP/calls" "$CLI" \
 artifact build ledger --revision "$(printf '1%.0s' {1..40})" \
 --opam-repository "$TMP/repository" --opam-revision "$(printf '2%.0s' {1..40})" \
 --compiler ocaml-variants.5.2.0+ox --store "$TMP/store" --reuse "$(printf 'a%.0s' {1..64})" --yes >"$TMP/result" 2>&1; then exit 1; fi
if ! grep -Fq 'artifact store: cannot load entry' "$TMP/result"; then
 echo 'FAIL - guest explicit reuse must verify selection before source/host work' >&2; exit 1
fi
test ! -e "$TMP/calls"
echo 'ok - guest artifact CLI verifies explicit store selections before source/host work'

#!/usr/bin/env bash
# serai edge's JSON forms: a JSON apply names the approved plan, and every
# other form is refused, before the repository loads or anything is contacted.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
(cd "$ROOT/serai" && dune build bin/main.exe)
CLI="$ROOT/serai/_build/default/bin/main.exe"
fail() { echo "FAIL - $*" >&2; exit 1; }
cp -R "$ROOT/example" "$TMP/config"
mkdir -p "$TMP/config/compute/apps/_lib"
printf '#!/bin/sh\necho "$0 $*" >>"%s/contacted"\nexit 1\n' "$TMP" >"$TMP/fake"
chmod +x "$TMP/fake"
json() {
  set +e
  (cd "$TMP/config" && SSH_BIN="$TMP/fake" RSYNC_BIN="$TMP/fake" CURL_BIN="$TMP/fake" JJ_BIN="$TMP/fake" \
    "$CLI" edge "$@" --json) >"$TMP/output" 2>"$TMP/error"
  code=$?
  set -e
  echo "$code"
}
refused() { # refused <what it says> <args...>
  local says=$1; shift
  test "$(json "$@")" = 1 || fail "serai edge $* --json was not refused"
  test "$(wc -l <"$TMP/output")" -eq 1 || fail "serai edge $* --json wrote more than its result"
  grep -Fq '"operation":"edge","status":"refused"' "$TMP/output" && grep -Fq '"code":"invalid_request"' "$TMP/output" \
    && grep -Fq -- "$says" "$TMP/output" || { cat "$TMP/output"; fail "serai edge $* --json: no invalid_request saying $says"; }
}
refused 'requires --expect-plan' --yes
refused 'is not a plan id' --yes --expect-plan NOTANID
refused 'takes --plan, or --yes --expect-plan' 
refused 'takes --plan, or --yes --expect-plan' --expect-plan 0123456789abcdef
refused 'takes --plan, or --yes --expect-plan' --plan --yes
test ! -e "$TMP/contacted" || fail "a refused request contacted something: $(cat "$TMP/contacted")"
echo 'ok - serai edge refuses JSON requests without an approved plan before contacting anything'

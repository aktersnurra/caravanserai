#!/usr/bin/env bash
# serai up refuses incomplete requests locally, before any host or remote is contacted.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
(cd "$ROOT/serai" && dune build bin/main.exe)
CLI="$ROOT/serai/_build/default/bin/main.exe"
# A copy of the example configuration whose hello declares no source;
# compute/apps/_lib marks it as its own engine too.
cp -R "$ROOT/example" "$TMP/config"
mkdir -p "$TMP/config/compute/apps/_lib"
sed '/(source (git /d' "$ROOT/example/apps/hello/app.sexp" >"$TMP/config/apps/hello/app.sexp"
printf '#!/bin/sh\necho "$0 $*" >>"%s/contacted"\nexit 1\n' "$TMP" >"$TMP/fake"
chmod +x "$TMP/fake"
run() {
  (cd "$TMP/config" && SERAI_CACHE="$TMP/cache" SERAI_STORE="$TMP/store" \
    SSH_BIN="$TMP/fake" RSYNC_BIN="$TMP/fake" CURL_BIN="$TMP/fake" JJ_BIN="$TMP/fake" \
    "$CLI" up "$@" --yes) >"$TMP/output" 2>&1
}
if run counter; then echo 'FAIL - up without --revision ran' >&2; exit 1; fi
grep -q '^usage:' "$TMP/output"
if run hello --revision main; then echo 'FAIL - up ran for an app without a declared source' >&2; exit 1; fi
grep -Fq 'hello: declare (source (git <url>)) in its app.sexp to use serai up' "$TMP/output"
if run logs --revision main; then echo 'FAIL - up ran for a package app' >&2; exit 1; fi
grep -Fq 'logs: serai up handles phoenix and ocaml apps only' "$TMP/output"
test ! -e "$TMP/contacted"
test "$("$ROOT/tests/stat-field" perm "$TMP/store")" = 700

# A JSON apply names the approved plan, or is refused before the repository loads.
json() {
  (cd "$TMP/config" && SERAI_CACHE="$TMP/cache" SERAI_STORE="$TMP/store" \
    SSH_BIN="$TMP/fake" RSYNC_BIN="$TMP/fake" CURL_BIN="$TMP/fake" JJ_BIN="$TMP/fake" \
    "$CLI" up "$@" --json) >"$TMP/output" 2>"$TMP/error"
}
if json counter --revision main --yes; then echo 'FAIL - up --yes --json ran without --expect-plan' >&2; exit 1; fi
grep -Fq '"operation":"up","status":"refused"' "$TMP/output" && grep -Fq '"code":"invalid_request"' "$TMP/output" \
  && grep -Fq -- '--expect-plan' "$TMP/output" || { cat "$TMP/output"; echo 'FAIL - no invalid_request without --expect-plan' >&2; exit 1; }
if json counter --revision main --source "$TMP" --yes; then echo 'FAIL - up --source --yes --json ran without --expect-plan' >&2; exit 1; fi
grep -Fq '"code":"invalid_request"' "$TMP/output"
if json counter --revision main --yes --expect-plan NOTANID; then echo 'FAIL - a malformed plan id was accepted' >&2; exit 1; fi
grep -Fq '"code":"invalid_request"' "$TMP/output" && grep -Fq 'is not a plan id' "$TMP/output"
test ! -e "$TMP/contacted"
echo 'ok - serai up refuses incomplete requests before contacting anything'

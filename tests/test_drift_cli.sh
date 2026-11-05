#!/usr/bin/env bash
# serai drift: one result whatever can't be reached, each section on its
# own; a broken declaration or a stray argument refused before contact.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
(cd "$ROOT/serai" && dune build bin/main.exe)
CLI="$ROOT/serai/_build/default/bin/main.exe"
fail() { echo "FAIL - $*" >&2; exit 1; }
cp -R "$ROOT/example" "$TMP/config"
mkdir -p "$TMP/config/compute/apps/_lib" "$TMP/cache" "$TMP/store"
chmod 700 "$TMP/cache" "$TMP/store"
# Every host and remote unreachable: ssh, rsync, curl and jj all fail.
printf '#!/bin/sh\necho "$0 $*" >>"%s/contacted"\nexit 1\n' "$TMP" >"$TMP/fake"
chmod +x "$TMP/fake"
drift() {
  set +e
  (cd "$TMP/config" && env -u SERAI_IDP_API_KEY SSH_BIN="$TMP/fake" RSYNC_BIN="$TMP/fake" CURL_BIN="$TMP/fake" \
    JJ_BIN="$TMP/fake" SERAI_CACHE="$TMP/cache" SERAI_STORE="$TMP/store" "$CLI" drift "$@") >"$TMP/output" 2>"$TMP/error"
  code=$?
  set -e
  echo "$code"
}
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" <"$TMP/output"; }

# Nothing reachable: every section and app says why; incomplete, exit 1.
test "$(drift --json)" = 1 || { cat "$TMP/output" "$TMP/error"; fail "an unreachable system did not exit 1"; }
test "$(wc -l <"$TMP/output")" -eq 1 || fail "drift --json wrote more than its result"
test "$(field 'd["operation"] + " " + d["status"]')" = "drift succeeded" || { cat "$TMP/output"; fail "the envelope"; }
test "$(field 'd["data"]["drifted"], d["data"]["complete"]')" = "False False" || fail "drifted/complete"
test "$(field 'd["data"]["edge"]["state"]')" = unavailable || fail "the edge was not unavailable"
test "$(field 'd["data"]["idp"]["state"]')" = unavailable && field 'd["data"]["idp"]["message"]' | grep -q SERAI_IDP_API_KEY \
  || { cat "$TMP/output"; fail "the idp without a key"; }
test "$(field '[(a["app"], a["state"]) for a in d["data"]["apps"]]')" \
  = "[('counter', 'unavailable'), ('hello', 'unavailable'), ('logs', 'not_covered'), ('ledger', 'not_covered')]" \
  || { cat "$TMP/output"; fail "the apps"; }
grep -q 'release-probe-active' "$TMP/contacted" || fail "the apps' releases were not probed"
! grep -q '/api/' "$TMP/contacted" || fail "Pocket ID was asked without a key"

# The plain form says the same, one line each.
rm -f "$TMP/contacted"
test "$(drift)" = 1 || fail "plain drift did not exit 1"
for line in '^edge: unavailable: ' '^idp: unavailable: set SERAI_IDP_API_KEY' '^app hello: unavailable: ' \
  '^app logs: not covered$' '^app ledger: not covered$'; do
  grep -Eq "$line" "$TMP/output" || { cat "$TMP/output"; fail "plain drift has no line matching $line"; }
done

# Stray arguments, and a broken declaration: refused before contact.
rm -f "$TMP/contacted"
test "$(drift --yes --json)" = 1 || fail "drift --yes --json was not refused"
test "$(field 'd["error"]["code"]')" = invalid_request || { cat "$TMP/output"; fail "drift --yes --json is not invalid_request"; }
test "$(drift hello)" = 1 || fail "drift hello was not refused"
echo '(broken' >"$TMP/config/apps/hello/app.sexp"
test "$(drift --json)" = 1 || fail "a broken declaration was not refused"
test "$(field 'd["status"]')" != succeeded || fail "a broken declaration succeeded"
test ! -e "$TMP/contacted" || fail "a refused request contacted something: $(cat "$TMP/contacted")"
echo 'ok - serai drift reports each section on its own and refuses before contact'

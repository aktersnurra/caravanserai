#!/usr/bin/env bash
# Every command under --json: a command that changes a host applies only
# the plan the operator approved, and the read side reports live state.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
(cd "$ROOT/serai" && dune build bin/main.exe)
CLI="$ROOT/serai/_build/default/bin/main.exe"
fail() { echo "FAIL - $*" >&2; cat "$TMP/output" "$TMP/error" >&2 2>/dev/null || true; exit 1; }
cp -R "$ROOT/example" "$TMP/config"
cp -R "$ROOT/compute" "$ROOT/edge" "$TMP/config/"
# Stands in for ssh and rsync: records the call, answers the lock probe.
cat >"$TMP/fake" <<EOF_FAKE
#!/bin/sh
echo "\$0 \$*" >>"$TMP/contacted"
case "\$*" in
  *'lock-holder: '*) echo 'lock-holder: ops@elsewhere: serai edge (pid 4)'; echo 'lock-age: 42' ;;
  *'jail-probe-root: '*) echo 'jail-probe-root: absent' ;;
esac
exit 0
EOF_FAKE
chmod +x "$TMP/fake"
serai() {
  set +e
  (cd "$TMP/config" && SSH_BIN="$TMP/fake" RSYNC_BIN="$TMP/fake" CURL_BIN="$TMP/fake" JJ_BIN="$TMP/fake" \
    "$CLI" "$@") >"$TMP/output" 2>"$TMP/error"
  code=$?
  set -e
}
has() { grep -Fq -- "$1" "$TMP/output" || fail "$2"; }
field() { sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p" "$TMP/output"; }

serai bootstrap hello --plan --json
test "$code" = 2 || fail "a plan exits 2, not $code"
has '"operation":"bootstrap","status":"succeeded"' 'the plan is not a succeeded bootstrap result'
has '"applied":false' 'the plan does not say it applied nothing'
plan=$(field plan_id)
test "${#plan}" = 16 || fail "no plan id in the plan"
test ! -e "$TMP/contacted" || fail "planning contacted a host: $(cat "$TMP/contacted")"

serai bootstrap hello --yes --json
test "$code" = 1 || fail '--yes without a plan was not refused'
has '"code":"invalid_request"' '--yes alone is not an invalid request'
serai bootstrap hello --yes --json --expect-plan 0123456789abcdef
test "$code" = 1 || fail 'another plan was not refused'
has '"code":"stale_plan"' 'another plan is not stale'
serai bootstrap counter --yes --json --expect-plan "$plan"
has '"code":"stale_plan"' "one app's plan approved another's bootstrap"
test ! -e "$TMP/contacted" || fail "a refused apply contacted a host: $(cat "$TMP/contacted")"

serai bootstrap hello --yes --json --expect-plan "$plan"
test "$code" = 0 || fail "the approved plan was not applied (exit $code)"
has '"operation":"bootstrap","status":"succeeded"' 'the approved bootstrap did not succeed'
test "$(wc -l <"$TMP/output")" -eq 1 || fail 'stdout holds more than the one result'
grep -q 'doas sh' "$TMP/contacted" || fail 'the approved bootstrap ran nothing on the host'

# The same plan id from the terminal form.
serai bootstrap hello --plan
test "$code" = 2 || fail 'a text plan exits 2'
grep -Fxq "plan $plan" "$TMP/output" || fail 'the text plan prints another id than the JSON one'

rm -f "$TMP/contacted"
serai locks --json
test "$code" = 0 || fail "locks failed (exit $code)"
has '"state":"held"' 'a held lock is not reported'
has '"holder":"ops@elsewhere: serai edge (pid 4)"' 'the holder is not named'
has '"age_seconds":42' 'the age is missing'
has '"holder_alive":null' "another machine's holder is not of unknown liveness"
! grep -q 'mkdir\|rm -rf' "$TMP/contacted" || fail 'reading the locks took or removed one'

serai status hello --json
test "$code" = 0 || fail "status failed (exit $code)"
has '"app":"hello"' 'status does not name the app'
has '"jail":{"state":"absent"}' 'an absent jail is not reported'
echo 'ok - under --json a host changes only by an approved plan; locks and status read live state'

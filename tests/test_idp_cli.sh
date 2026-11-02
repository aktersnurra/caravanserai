#!/usr/bin/env bash
# serai idp against a fake curl serving Pocket ID v2.19.1's responses for the
# example configuration (serai/test/fixtures/pocket-id). Exercises the real
# sh -c / printf / curl --config - path: the fake curl checks that the key
# arrives in its config on stdin and in none of its arguments.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
(cd "$ROOT/serai" && dune build bin/main.exe)
CLI="$ROOT/serai/_build/default/bin/main.exe"
FIXTURES="$ROOT/serai/test/fixtures/pocket-id"
KEY="pid_TESTKEY123"
fail() { echo "FAIL - $*" >&2; exit 1; }

# A configuration: the example's idp.sexp, and an engine marker above it.
mkdir -p "$TMP/compute/apps/_lib" "$TMP/config" "$TMP/responses"
cp "$ROOT/example/serai.sexp" "$TMP/config/"
cp "$ROOT/example/idp.sexp" "$TMP/config/"

respond() { cp "$FIXTURES/$2" "$TMP/responses/$1.json"; }
respond GET_api_version_current version.json
respond GET_api_user-groups user-groups.json
respond GET_api_users users.json
respond GET_api_oidc_clients oidc-clients.json
respond GET_api_apis apis.json
respond GET_api_apis_5b3a9f20-0000-4000-8000-000000000001_clients api-clients.json

cat >"$TMP/curl" <<'EOF'
#!/usr/bin/env bash
config="$(cat)"
case "$config" in *"X-API-Key: $EXPECTED_KEY"*) ;; *) echo "fake curl: no key in its config" >&2; exit 99 ;; esac
for arg in "$@"; do case "$arg" in *"$EXPECTED_KEY"*) echo "fake curl: the key in its arguments" >&2; exit 98 ;; esac; done
method=GET body='' url=''
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data-binary) body="$2"; shift 2 ;;
    -H|-w|--max-time|--config) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
path="${url#https://id.example.org}"
path="${path%%\?*}"
echo "$method $path" >>"$LOG"
if [ -n "$body" ]; then printf '%s %s %s\n' "$method" "$path" "$body" >>"$LOG.bodies"; fi
name="$(printf '%s_%s' "$method" "${path#/}" | tr '/' '_')"
if [ -f "$RESPONSES/$name.json" ]; then
  cat "$RESPONSES/$name.json"
  printf '\n%s' "$(cat "$RESPONSES/$name.status" 2>/dev/null || echo 200)"
elif [ "$method" != GET ]; then
  printf '{"id":"created-%s"}\n201' "$(wc -l <"$LOG" | tr -d ' ')"
else
  printf '{"error":"Not found","code":"not_found"}\n404'
fi
EOF
chmod +x "$TMP/curl"

run() {
  rm -f "$TMP/log" "$TMP/log.bodies"
  (cd "$TMP/config" && EXPECTED_KEY="$KEY" LOG="$TMP/log" RESPONSES="$TMP/responses" \
    CURL_BIN="$TMP/curl" "$CLI" idp "$@" </dev/null) >"$TMP/output" 2>"$TMP/error"
}
status() { set +e; run "$@"; code=$?; set -e; echo "$code"; }

export SERAI_IDP_API_KEY="$KEY"

# Arguments.
test "$(status --bogus)" = 1 || fail "an unknown flag was accepted"
grep -q '^usage:' "$TMP/error"
test "$(status --plan --yes)" = 1 || fail "--plan --yes was accepted"
test "$(status --json)" = 1 || fail "--json without --plan was accepted"
test "$(status --plan --url https://id.example.org)" = 1 || fail "--url without --export was accepted"

# The key: missing or unusable, nothing is requested.
test "$(SERAI_IDP_API_KEY='' status --plan)" = 1 || fail "ran without a key"
grep -Fq 'set SERAI_IDP_API_KEY (an admin API key from https://id.example.org/settings/admin/api-keys)' "$TMP/error"
test ! -e "$TMP/log" || fail "requested without a key"
test "$(SERAI_IDP_API_KEY='has space' status --plan)" = 1 || fail "ran with a key holding a space"
test ! -e "$TMP/log" || fail "requested with an unusable key"

# In sync: nothing to say.
test "$(status --plan)" = 0 || { cat "$TMP/error" "$TMP/output"; fail "in sync --plan did not exit 0"; }
test ! -s "$TMP/output" || fail "in sync --plan printed something"
test "$(head -n1 "$TMP/log")" = "GET /api/version/current" || fail "the version was not checked first"
test "$(status)" = 0 || fail "in sync apply did not exit 0"
test ! -s "$TMP/output"
! grep -qv '^GET ' "$TMP/log" || fail "in sync apply changed something"
test "$(status --plan --json)" = 0 || fail "in sync --plan --json did not exit 0"
test "$(wc -l <"$TMP/output")" -eq 1
grep -Fq '"operation":"idp.plan"' "$TMP/output"
grep -Fq '"pending":false' "$TMP/output"

# Drift: bob changes address and joins a new group.
python3 - "$TMP/config/idp.sexp" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("(family (friendly_name Family) (claims ((household north))))))",
              "(family (friendly_name Family) (claims ((household north))))\n          (guests (friendly_name Guests))))")
s = s.replace("(bob (email bob@example.org) (first_name Bob) (groups (family)))",
              "(bob (email robert@example.org) (first_name Bob) (groups (family guests)))")
open(p, "w").write(s)
EOF
test "$(status --plan)" = 2 || { cat "$TMP/error"; fail "drift --plan did not exit 2"; }
diff -u - "$TMP/output" <<'EOF'
group guests: create
user bob: update email, groups (+guests)
EOF
test "$(status --plan --json)" = 2 || fail "drift --plan --json did not exit 2"
grep -Fq '"pending":true' "$TMP/output"
grep -Fq '{"action":"create","kind":"group","name":"guests"}' "$TMP/output"

test "$(status)" = 1 || fail "applied without a terminal or --yes"
grep -Fq 'needs confirmation but stdin is not a terminal; re-run with --yes' "$TMP/error"
! grep -qv '^GET ' "$TMP/log" || fail "changed something without confirmation"

test "$(status --yes)" = 0 || { cat "$TMP/error" "$TMP/output"; fail "drift --yes did not exit 0"; }
grep -Fxq 'applied 2 changes' "$TMP/output"
BOB=2c5e7a10-0000-4000-8000-000000000002
diff -u - <(grep -v '^GET ' "$TMP/log") <<EOF
POST /api/user-groups
PUT /api/users/$BOB
PUT /api/users/$BOB/user-groups
PUT /api/custom-claims/user/$BOB
EOF
grep -Fq "PUT /api/users/$BOB/user-groups {\"userGroupIds\":[\"6f1d0c3e-0000-4000-8000-000000000002\",\"created-" "$TMP/log.bodies" \
  || fail "the new group's id was not used"

# A failure stops the run and says what is left.
printf '{"error":"Group already exists","code":"already_in_use"}' >"$TMP/responses/POST_api_user-groups.json"
echo 400 >"$TMP/responses/POST_api_user-groups.status"
test "$(status --yes)" = 1 || fail "a failed apply did not exit 1"
grep -Fq 'applied 0 of 2; stopped: POST /api/user-groups (HTTP 400): Group already exists [already_in_use]' "$TMP/output"
rm "$TMP/responses/POST_api_user-groups.json" "$TMP/responses/POST_api_user-groups.status"

# Export.
# The adoption command as typed: the shell creates the empty idp.sexp
# before serai starts, so --export --url must not read it.
: >"$TMP/empty.sexp"
cp "$TMP/config/idp.sexp" "$TMP/kept.sexp"
(cd "$TMP/config" && EXPECTED_KEY="$KEY" LOG="$TMP/log" RESPONSES="$TMP/responses" CURL_BIN="$TMP/curl" \
  "$CLI" idp --export --url https://id.example.org >idp.sexp 2>"$TMP/error") \
  || { cat "$TMP/error"; fail "--export --url > idp.sexp failed"; }
head -n1 "$TMP/config/idp.sexp" | grep -Fq '; Exported from https://id.example.org' || fail "the redirected export is not an export"
test "$(status --plan)" = 0 || { cat "$TMP/error" "$TMP/output"; fail "the redirected export does not plan to nothing"; }
cp "$TMP/kept.sexp" "$TMP/config/idp.sexp"
test "$(status --export)" = 0 || fail "--export from idp.sexp's url failed"
head -n1 "$TMP/output" | grep -Fq '; Exported from https://id.example.org by serai idp --export'
mv "$TMP/config/idp.sexp" "$TMP/declared.sexp"
test "$(status --plan)" = 1 || fail "--plan ran without idp.sexp"
grep -Fq 'nothing is declared' "$TMP/error"
test "$(status --export)" = 1 || fail "--export ran with neither idp.sexp nor --url"
test "$(status --export --url https://id.example.org)" = 0 || fail "--export --url failed"
cp "$TMP/output" "$TMP/config/idp.sexp"
test "$(status --plan)" = 0 || { cat "$TMP/error" "$TMP/output"; fail "the export does not plan to nothing"; }

echo "ok - serai idp: arguments, key handling, plan, JSON, apply, failure and export"

#!/usr/bin/env bash
# serai idp against a real, throwaway Pocket ID v2.19.1: what the unit tests
# can only assume. Runs with SERAI_IDP_CONTRACT=1 (it downloads the release,
# about 75 MB, cached under SERAI_CACHE); otherwise it skips.
# SERAI_IDP_CAPTURE=<dir> also saves the server's responses, to refresh
# serai/test/fixtures/pocket-id/ by hand.
set -euo pipefail
if [ "${SERAI_IDP_CONTRACT:-}" != 1 ]; then
  echo "skip - idp contract (set SERAI_IDP_CONTRACT=1 to run against a real Pocket ID)"
  exit 0
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
SERVER_PID=''
cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT
fail() { echo "FAIL - $*" >&2; [ -f "$TMP/server.log" ] && tail -20 "$TMP/server.log" >&2; exit 1; }

VERSION=v2.19.1
case "$(uname -s)" in
  Linux) ASSET=pocket-id_linux_amd64; SHA256=fbe58b3af6e225600136c7da033810d2d86436fbd13a135fa52205f467544436 ;;
  FreeBSD) ASSET=pocket-id_freebsd_amd64; SHA256=ac0b20e6ab6df3901d4318c0c614ae97496a3315558a977827948a2297bccf60 ;;
  *) echo "skip - idp contract: no Pocket ID release for $(uname -s)"; exit 0 ;;
esac
sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else sha256 -q "$1"; fi; }
CACHE="${SERAI_CACHE:-$HOME/.cache/serai}/pocket-id/$VERSION"
BINARY="$CACHE/$ASSET"
if [ ! -f "$BINARY" ] || [ "$(sha256_of "$BINARY")" != "$SHA256" ]; then
  mkdir -p "$CACHE"
  curl -fsSL -o "$BINARY.partial" "https://github.com/pocket-id/pocket-id/releases/download/$VERSION/$ASSET"
  [ "$(sha256_of "$BINARY.partial")" = "$SHA256" ] || { rm -f "$BINARY.partial"; fail "$ASSET does not match its pinned checksum"; }
  mv "$BINARY.partial" "$BINARY"
  chmod +x "$BINARY"
fi

(cd "$ROOT/serai" && dune build bin/main.exe)
CLI="$ROOT/serai/_build/default/bin/main.exe"

# A throwaway instance on real HTTPS: a self-signed localhost certificate
# that curl trusts through CURL_CA_BUNDLE.
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
PORT="$(free_port)"
ACTORS_PORT="$(free_port)"
URL="https://localhost:$PORT"
KEY="$(openssl rand -hex 24)"
mkdir -p "$TMP/server"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj /CN=localhost \
  -addext subjectAltName=DNS:localhost -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
(cd "$TMP/server" && env -i PATH="$PATH" HOME="$TMP/server" \
  APP_URL="$URL" HOST=127.0.0.1 PORT="$PORT" ACTORS_HOST=127.0.0.1 ACTORS_PORT="$ACTORS_PORT" \
  TLS_CERT_FILE="$TMP/cert.pem" TLS_KEY_FILE="$TMP/key.pem" \
  ENCRYPTION_KEY="$(openssl rand -hex 32)" STATIC_API_KEY="$KEY" \
  ANALYTICS_DISABLED=true VERSION_CHECK_DISABLED=true DISABLE_RATE_LIMITING=true ICON_LIBRARY_URL=disabled \
  "$BINARY") >"$TMP/server.log" 2>&1 &
SERVER_PID=$!
export CURL_CA_BUNDLE="$TMP/cert.pem"
for _ in $(seq 120); do
  if curl -fsS -o /dev/null "$URL/healthz" 2>/dev/null; then break; fi
  kill -0 "$SERVER_PID" 2>/dev/null || fail "Pocket ID exited"
  sleep 0.5
done
curl -fsS -o /dev/null "$URL/healthz" || fail "Pocket ID did not come up"

# The test's own requests, as the admin UI would make them.
api() {
  local method="$1" path="$2"; shift 2
  curl -fsS -X "$method" -H "X-API-Key: $KEY" -H 'Accept: application/json' "$@" "$URL$path"
}
json_body() { api "$1" "$2" -H 'Content-Type: application/json' --data-binary "$3"; }
field() { python3 -c 'import json, sys; d = json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }

# The example's idp.sexp, pointed at the instance.
mkdir -p "$TMP/compute/apps/_lib" "$TMP/config"
cp "$ROOT/example/serai.sexp" "$TMP/config/"
sed "s|(url https://id.example.org)|(url $URL)|" "$ROOT/example/idp.sexp" >"$TMP/config/idp.sexp"
run() { (cd "$TMP/config" && SERAI_IDP_API_KEY="$KEY" "$CLI" idp "$@" </dev/null) >"$TMP/output" 2>"$TMP/error"; }
status() { set +e; run "$@"; code=$?; set -e; echo "$code"; }

test "$(api GET /api/version/current | field 'd["currentVersion"]')" = 2.19.1 || fail "the version response"
test "$(api GET /api/users/me | field 'd["id"]')" = 00000000-0000-0000-0000-000000000000 \
  || fail "the static key does not act as the static API key user"

# 1. The first apply creates; a second plan is empty.
test "$(status --plan)" = 2 || { cat "$TMP/error"; fail "the first plan did not exit 2"; }
! grep -v ': create\|: CIMD on\|: grant ' "$TMP/output" || fail "the first plan holds more than creates"
test "$(status --yes)" = 0 || { cat "$TMP/output" "$TMP/error"; fail "the first apply failed"; }
grep -Fq 'client logs: create a secret for it in the UI' "$TMP/output" || fail "no secret reminder for logs"
test "$(status --plan)" = 0 || { cat "$TMP/output" "$TMP/error"; fail "the plan after applying is not empty"; }
test ! -s "$TMP/output" || { cat "$TMP/output"; fail "the plan after applying printed something"; }

if [ -n "${SERAI_IDP_CAPTURE:-}" ]; then
  mkdir -p "$SERAI_IDP_CAPTURE"
  api GET /api/version/current >"$SERAI_IDP_CAPTURE/version.json"
  api GET /api/users/me >"$SERAI_IDP_CAPTURE/users-me.json"
  api GET '/api/user-groups?pagination[limit]=100' -g >"$SERAI_IDP_CAPTURE/user-groups.json"
  api GET '/api/users?pagination[limit]=100' -g >"$SERAI_IDP_CAPTURE/users.json"
  api GET '/api/oidc/clients?pagination[limit]=100' -g >"$SERAI_IDP_CAPTURE/oidc-clients.json"
  api GET '/api/apis?pagination[limit]=100' -g >"$SERAI_IDP_CAPTURE/apis.json"
  CAPTURE_API="$(api GET /api/apis | field 'd["data"][0]["id"]')"
  api GET "/api/apis/$CAPTURE_API/clients" >"$SERAI_IDP_CAPTURE/api-clients.json"
fi

# 2. The new confidential client holds no secret.
test "$(api GET /api/oidc/clients/logs/secrets | field 'len(d)')" = 0 || fail "logs kept its auto-created secret"

# 3. Drift made by hand is planned exactly, and applying keeps the logo.
ADMINS="$(api GET /api/user-groups | field '[g["id"] for g in d["data"] if g["name"] == "admins"][0]')"
FAMILY="$(api GET /api/user-groups | field '[g["id"] for g in d["data"] if g["name"] == "family"][0]')"
BOB="$(api GET /api/users | field '[u["id"] for u in d["data"] if u["username"] == "bob"][0]')"
api GET /api/oidc/clients/hello | python3 -c 'import json, sys; d = json.load(sys.stdin); d["name"] = "Hullo"; print(json.dumps(d))' >"$TMP/hello.json"
json_body PUT /api/oidc/clients/hello "$(cat "$TMP/hello.json")" >/dev/null
json_body PUT "/api/users/$BOB/user-groups" "{\"userGroupIds\":[\"$FAMILY\",\"$ADMINS\"]}" >/dev/null
json_body PUT "/api/custom-claims/user-group/$ADMINS" '[{"key":"tier","value":"gold"}]' >/dev/null
python3 -c 'import base64, sys; open(sys.argv[1], "wb").write(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="))' "$TMP/logo.png"
api POST /api/oidc/clients/hello/logo -F "file=@$TMP/logo.png;type=image/png" >/dev/null
test "$(status --plan)" = 2 || fail "hand-made drift was not planned"
diff -u - "$TMP/output" <<'EOF' || fail "the drift plan"
group admins: update claims (-tier=gold)
user bob: update groups (-admins)
client hello: update name
EOF
test "$(status --yes)" = 0 || { cat "$TMP/output" "$TMP/error"; fail "applying the drift failed"; }
test "$(status --plan)" = 0 || { cat "$TMP/output"; fail "drift remains after applying"; }
test "$(api GET /api/oidc/clients/hello | field 'd["hasLogo"]')" = True || fail "applying cleared hello's logo"

# 4. A permission left out is removed; the kept one keeps its id and grant.
LEDGER="$(api GET /api/apis | field 'd["data"][0]["id"]')"
READ_ID="$(api GET /api/apis | field '[p["id"] for p in d["data"][0]["permissions"] if p["key"] == "ledger:read"][0]')"
python3 - "$TMP/config/idp.sexp" <<'EOF'
import re, sys
p = sys.argv[1]; s = open(p).read()
s, n = re.subn(r'\n\s*\(ledger:write \(name "Write the ledger"\)\n\s*\(description "Create and change entries"\)\)', '', s)
assert n == 1, "ledger:write not found"
open(p, "w").write(s)
EOF
test "$(status --yes)" = 0 || { cat "$TMP/output" "$TMP/error"; fail "removing a permission failed"; }
test "$(api GET /api/apis | field '[p["key"] for p in d["data"][0]["permissions"]]')" = "['ledger:read']" || fail "ledger:write remains"
test "$(api GET /api/apis | field '[p["id"] for p in d["data"][0]["permissions"]][0]')" = "$READ_ID" || fail "ledger:read changed id"
test "$(api GET "/api/apis/$LEDGER/clients" | field '[c["userDelegatedPermissionIds"] for c in d["data"] if c["client"]["id"] == "hello"][0]')" = "['$READ_ID']" \
  || fail "hello's grant lost ledger:read"
test "$(status --plan)" = 0 || fail "removing a permission left drift"

# 5. A user made by hand is reported and survives; the static key's user never appears.
json_body POST /api/users '{"username":"carol","email":"carol@example.org","firstName":"Carol","lastName":"","displayName":"","isAdmin":false,"disabled":false}' >/dev/null
test "$(status --plan)" = 0 || fail "an undeclared user made the plan pending"
grep -Fxq 'undeclared: user carol (left alone)' "$TMP/output" || fail "carol was not reported"
! grep -q 'static-api-user' "$TMP/output" || fail "the static API key user was reported"
test "$(status --yes)" = 0 || fail "applying with an undeclared user failed"
test "$(api GET /api/users | field '[u["username"] for u in d["data"] if u["username"] == "carol"]')" = "['carol']" \
  || fail "carol was removed"

# 6. The export validates and plans to nothing.
test "$(status --export)" = 0 || { cat "$TMP/error"; fail "--export failed"; }
cp "$TMP/output" "$TMP/config/idp.sexp"
test "$(status --plan)" = 0 || { cat "$TMP/output" "$TMP/error"; fail "the export does not plan to nothing"; }

echo "ok - idp contract: apply, re-plan, no orphan secret, drift, removals, undeclared, export (Pocket ID $VERSION)"

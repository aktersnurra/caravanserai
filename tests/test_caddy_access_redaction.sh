#!/usr/bin/env bash
# Render only: never run the production Caddyfile or contact an external host.
# The example configuration's access-log snippet stands for any.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
fragments="$root/example/edge/caddy/sites"
snippet="$fragments/00-access-logs.caddy.template"
[ -f "$snippet" ] || { echo 'FAIL: missing shared access-log snippet' >&2; exit 1; }
for site in "$fragments"/[1-9]*.caddy.template; do
  grep -Fq 'import access_log' "$site" || {
    echo "FAIL: no access logging in ${site##*/}" >&2
    exit 1
  }
done
# Inspect the adapted Caddy config rather than just matching template text.
# A separate loopback integration test below will assert what reaches stdout.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'import conf.d/*.caddy\n:39847 {\n import access_log\n respond "ok"\n}\n' >"$tmp/Caddyfile"
mkdir "$tmp/conf.d"
cp "$snippet" "$tmp/conf.d/00-access-logs.caddy"
caddy adapt --adapter caddyfile --config "$tmp/Caddyfile" >"$tmp/adapt.json" 2>"$tmp/error" || {
  echo 'FAIL: access logging Caddyfile does not adapt' >&2
  grep -E 'Error|error' "$tmp/error" >&2 || true
  exit 1
}
python3 - "$tmp/adapt.json" <<'PY'
import json, sys
config = json.load(open(sys.argv[1]))
encoded = json.dumps(config)
assert 'regexp' in encoded and 'request>uri' in encoded, 'no URI redaction in adapted config'
PY
# Exercise the encoder on an actual request; adapted JSON alone cannot prove
# that the filter removes credentials from emitted access-log records.
port=$(python3 - <<'PY'
import socket
with socket.socket() as server:
    server.bind(('127.0.0.1', 0))
    print(server.getsockname()[1])
PY
)
printf 'import conf.d/*.caddy\nhttp://127.0.0.1:%s {\n import access_log\n respond "ok"\n}\n' \
  "$port" >"$tmp/Caddyfile"
HOME="$tmp" XDG_DATA_HOME="$tmp/data" XDG_CONFIG_HOME="$tmp/config" \
  caddy run --config "$tmp/Caddyfile" --adapter caddyfile >"$tmp/runtime.log" 2>"$tmp/runtime.err" &
caddy_pid=$!
trap 'kill "$caddy_pid" 2>/dev/null || true; wait "$caddy_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
ready=0
for _ in {1..30}; do
  if curl --fail --silent --output /dev/null --max-time 1 \
       --header 'Authorization: Bearer credential-header-sentinel' \
       --header 'Cookie: session=credential-cookie-sentinel' \
       --header 'Referer: https://id.example.test/callback?code=credential-referer-sentinel' \
       --header 'X-Api-Key: credential-api-key-sentinel' \
       "http://127.0.0.1:${port}/oauth2/callback?code=credential-query-sentinel&NEWKEY=unknown-secret"; then
    ready=1
    break
  fi
  kill -0 "$caddy_pid" 2>/dev/null || break
  sleep 0.1
done
[ "$ready" -eq 1 ] || { echo 'FAIL: loopback Caddy request failed' >&2; exit 1; }
# The log is emitted synchronously but allow the output pipe a brief flush.
sleep 0.2
python3 - "$tmp/runtime.log" <<'PY'
import json, sys
records = []
for line in open(sys.argv[1]):
    try:
        record = json.loads(line)
    except ValueError:
        continue
    if record.get('logger', '').startswith('http.log.access'): 
        records.append(record)
assert records, 'FAIL: no access record was emitted'
record = records[-1]
assert record['request']['uri'] == '/oauth2/callback', record['request']['uri']
assert 'headers' not in record['request'], 'FAIL: request headers retained in access log'
assert 'resp_headers' not in record, 'FAIL: response headers retained in access log'
encoded = json.dumps(record)
for sentinel in ('credential-query-sentinel', 'unknown-secret',
                 'credential-header-sentinel', 'credential-cookie-sentinel',
                 'credential-referer-sentinel', 'credential-api-key-sentinel'):
    assert sentinel not in encoded, 'FAIL: access record contains ' + sentinel
PY
printf 'ok - access-log query and credential redaction on loopback\n'

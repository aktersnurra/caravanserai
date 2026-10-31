#!/usr/bin/env bash
# Static, offline contract: never installs packages or contacts a log receiver.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
config="$root/edge/syslog-ng-victoria.conf.template"
unit="$root/edge/syslog-ng-victoria.service"
installer="$root/edge/03-logging"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
for file in "$config" "$unit" "$installer"; do
  [ -f "$file" ] || fail "missing ${file##*/}"
done
bash -n "$installer"
grep -Fq 'systemd-journal(' "$config" || fail 'no journal source'
grep -Fq 'read-old-records(no)' "$config" || fail 'historical pre-redaction journal records could be forwarded'
grep -Fq '.journald._SYSTEMD_UNIT' "$config" || fail 'not scoped to systemd unit'
grep -Fq 'caddy.service' "$config" || fail 'Caddy unit not selected'
grep -Fq 'http[.]log[.]access[.]' "$config" || fail 'not scoped to Caddy access records'
grep -Fq 'json-parser(' "$config" || fail 'Caddy JSON not parsed before filtering'
grep -Fq '.caddy.logger' "$config" || fail 'access logger is not matched as structured field'
grep -Fq 'filter(f_no_queries)' "$config" || fail 'query-bearing journal messages are not rejected'
grep -Fq 'filter(f_no_headers)' "$config" || fail 'old header-bearing records are not rejected'
grep -Fq 'oauth2-proxy.service' "$config" || fail 'oauth2-proxy safe events not selected'
grep -Fq 'OAuthProxy configured for OpenID Connect Client ID:' "$config" || fail 'oauth2-proxy event not allowlisted'
grep -Fq 'template("OIDC configured")' "$config" || fail 'oauth2-proxy output must use a static replacement'
grep -Fq 'destination(d_oauth_safe_event)' "$config" || fail 'oauth2-proxy output needs its own static destination'
# Both network destinations share an IP and port; distinct persist identities
# avoid a runtime startup failure that --syntax-only does not catch. Preserve
# the Caddy destination's existing automatic identity for its queued records.
awk '
  /^destination d_victoria_logs/ { caddy = 1 }
  /^destination d_oauth_safe_event/ { caddy = 0; oauth = 1 }
  caddy && /persist-name\(/ { bad = 1 }
  oauth && /persist-name\("vps-oauth-safe-event"\)/ { found = 1 }
  END { exit (bad || !found) }
' "$config" || fail 'distinct oauth persist name missing or Caddy queue identity changed'
# The auth destination must never interpolate a raw journal message.
if grep -F 'template(' "$config" | grep -Fq 'MESSAGE'; then fail 'raw auth message interpolated into syslog'; fi
# infra fills both from the logs app; the installer checks the same receiver.
[ "$(grep -c '^        "__LOGS_IP__"$' "$config")" = 2 ] || fail 'destination not the logs receiver'
[ "$(grep -c '^        port(__LOGS_SYSLOG_PORT__)$' "$config")" = 2 ] || fail 'port not the logs receiver'
grep -Fq 'logging-receiver' "$installer" || fail 'installer does not check the rendered receiver'
if grep -Eq '(^|[^0-9.])(10\.[0-9]|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' "$config" "$installer"; then fail 'edge host sender hard-codes an address'; fi
grep -Fq 'transport("tcp")' "$config" || fail 'not using TCP'
grep -Fq 'flags(syslog-protocol)' "$config" || fail 'octet-counted or legacy framing possible'
grep -Fq 'reliable(yes)' "$config" || fail 'no persistent disk buffer'
grep -Fq 'capacity-bytes(' "$config" || fail 'unbounded disk buffer'
grep -Fq 'time-reopen(' "$config" || fail 'no reconnect delay'
grep -Fq -- '--syntax-only' "$installer" || fail 'candidate configuration is not validated'
if grep -Eq 'pacman -Sy |yay|aur' "$installer"; then fail 'partial upgrade or AUR build'; fi
if grep -Eq '0\.0\.0\.0|network\(ip\(|syslog\(ip\(' "$config"; then fail 'edge host must not listen for syslog'; fi
grep -Fq -- '--persist-file' "$unit" || fail 'separate syslog-ng instance needs private state'
grep -Fq -- '--control' "$unit" || fail 'separate syslog-ng instance needs private control socket'
printf 'ok - edge host forwards Caddy access and static allowlisted auth events over queued private TCP syslog\n'

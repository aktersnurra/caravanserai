#!/usr/bin/env bash
# Does not install packages, access secrets or contact the edge host. The example
# configuration's oauth2-proxy stands for any.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
installer="$root/edge/04-vmui-auth"
config="$root/example/edge/oauth2-proxy/oauth2-proxy.cfg"
unit="$root/example/edge/oauth2-proxy/oauth2-proxy.service"
for file in "$installer" "$config" "$unit"; do
  [ -f "$file" ] || { echo "FAIL: missing ${file##*/}" >&2; exit 1; }
done
bash -n "$installer"
grep -Fq 'https://id.example.org' "$config" || { echo 'FAIL: wrong OIDC issuer' >&2; exit 1; }
grep -Fq 'https://logs.example.org/oauth2/callback' "$config" || { echo 'FAIL: wrong callback' >&2; exit 1; }
grep -Fq '127.0.0.1:4180' "$config" || { echo 'FAIL: auth listener must be loopback' >&2; exit 1; }
grep -Fq 'static://202' "$config" || { echo 'FAIL: auth-only upstream missing' >&2; exit 1; }
grep -Fq 'EnvironmentFile=/etc/oauth2-proxy/secrets.env' "$unit" || { echo 'FAIL: secrets must come from protected runtime file' >&2; exit 1; }
if grep -Eq '^\s*(client_secret|cookie_secret|client_id)\s*=' "$config"; then
  echo 'FAIL: runtime OIDC secrets in repository config' >&2
  exit 1
fi
if grep -Eq '(openssl rand|>.*secrets\.env|tee .*secrets\.env|cat .*secrets\.env)' "$installer"; then
  echo 'FAIL: installer may not generate or overwrite secrets' >&2
  exit 1
fi
printf 'ok - oauth2-proxy runtime secrets remain manual\n'

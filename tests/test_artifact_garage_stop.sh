#!/usr/bin/env bash
# Garage's packaged status_cmd is cluster RPC: exit 1 is not stopped proof.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
a=$(printf 'a%.0s' {1..64}); b=$(printf 'b%.0s' {1..64}); sha=$(printf 'c%.0s' {1..64})
mkdir -p "$TMP/bin" "$TMP/jail/opt/.infra-releases/garage" "$TMP/jail/usr/local/bin"
for id in "$a" "$b"; do
 mkdir -p "$TMP/jail/opt/.infra-releases/garage/$id/bin"
 printf '#!/bin/sh\nexit 0\n' >"$TMP/jail/opt/.infra-releases/garage/$id/bin/garage"
 chmod 755 "$TMP/jail/opt/.infra-releases/garage/$id/bin/garage"
 printf '%s\n' "$sha" >"$TMP/jail/opt/.infra-releases/garage/$id/.infra-sha256"
done
cat >"$TMP/bin/jexec" <<'EOF'
#!/bin/sh
case "$*" in
 *' stop') printf 'stopped\n' >"$STATE" ;;
 *' start') printf 'started\n' >"$STATE" ;;
 *' status') [ "$(cat "$STATE")" = started ] ;;
 *'ps -axo comm=')
  [ "${PS_FAIL:-0}" = 0 ] || exit 2
  [ "${PS_EMPTY:-0}" = 0 ] || exit 0
  [ "${LIVE_GARAGE:-1}" = 0 ] || printf 'garage\n'
  printf 'ps\n' ;;
 *) exit 99 ;;
esac
EOF
cat >"$TMP/bin/mv" <<'EOF'
#!/bin/sh
if [ "$1" = -fh ]; then
 shift
 exec mv -fT "$@"
fi
exec mv "$@"
EOF
cat >"$TMP/bin/stat" <<'EOF'
#!/bin/sh
case "$*" in *'%u:%h'*) printf '0:1\n' ;; *) exec stat "$@" ;; esac
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/bin/sh
printf '403'
EOF
chmod +x "$TMP/bin/"*
export STATE="$TMP/state"
run_helper() {
 JAIL_ROOT="$TMP/jail" JEXEC_BIN="$TMP/bin/jexec" MV_BIN="$TMP/bin/mv" \
 STAT_BIN="$TMP/bin/stat" CURL_BIN="$TMP/bin/curl" SLEEP_BIN=/usr/bin/true INFRA_LOCK_HELD=1 INFRA_ARTIFACT_HTTP_STATUS=403 INFRA_ARTIFACT_SERVICE_STATUS=process \
  sh "$ROOT/compute/apps/_lib/artifact_$1.sh" "${@:2}"
}
failures=0
# The process wait is the declared service_status, keyed by the release's
# name: the engine names no package.
for helper in activate convert_binary; do
 if grep -qi garage "$ROOT/compute/apps/_lib/artifact_$helper.sh"; then
  echo "FAIL - artifact_$helper.sh names Garage"; failures=$((failures + 1))
 fi
done
for helper in activate convert_binary; do
 for condition in live ps-failed ps-empty stopped; do
  rm -f "$TMP/jail/opt/garage" "$TMP/jail/opt/.infra-releases/garage/.previous" "$TMP/jail/usr/local/bin/garage"
  rm -rf "$TMP/jail/opt/.infra-legacy"
  printf 'running\n' >"$STATE"
  export LIVE_GARAGE=0 PS_FAIL=0 PS_EMPTY=0
  case "$condition" in live) LIVE_GARAGE=1 ;; ps-failed) PS_FAIL=1 ;; ps-empty) PS_EMPTY=1 ;; esac
  if [ "$helper" = activate ]; then
   ln -s ".infra-releases/garage/$a" "$TMP/jail/opt/garage"
   args=(garage "$b" "$sha" garage garage http://10.40.0.200:3900/ - garage)
  else
   cp "$TMP/jail/opt/.infra-releases/garage/$b/bin/garage" "$TMP/jail/usr/local/bin/garage"
   args=(garage "$b" "$sha" garage http://10.40.0.200:3900/ /usr/local/bin/garage)
  fi
  if run_helper "$helper" "${args[@]}" >"$TMP/result" 2>&1; then rc=0; else rc=$?; fi
  if [ "$condition" = stopped ]; then
   [ "$rc" = 0 ] || { echo "FAIL - $helper must accept confirmed absence"; failures=$((failures + 1)); continue; }
  else
   [ "$rc" != 0 ] || { echo "FAIL - $helper accepted Garage RPC failure as stopped ($condition)"; failures=$((failures + 1)); continue; }
   if [ "$helper" = activate ]; then
    [ "$(readlink "$TMP/jail/opt/garage")" = ".infra-releases/garage/$a" ]
   else
    [ ! -L "$TMP/jail/usr/local/bin/garage" ] && [ -f "$TMP/jail/usr/local/bin/garage" ]
    [ ! -e "$TMP/jail/opt/.infra-legacy/garage/$b.binary" ]
   fi
  fi
 done
 echo "checked - $helper Garage process absence cases"
done
[ "$failures" = 0 ]

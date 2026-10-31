#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/serai/_build/prepared-builder"
PRIVATE_TMP="$(mktemp -d "$ROOT/serai/_build/prepared-builder/phoenix-XXXXXXXX")"
chmod 700 "$PRIVATE_TMP"
export TMPDIR="$PRIVATE_TMP"
TMP="$(mktemp -d "$TMPDIR/fixture-XXXXXXXX")"
trap 'rm -rf "$PRIVATE_TMP"' EXIT
mkdir -p "$TMP/source" "$TMP/bin"
# The worker passes the recipe-snapshotted asset adapter as a Mix script.
cp "$ROOT/compute/apps/_lib/artifact_build_assets.exs" "$TMP/assets.exs"
cat >"$TMP/bin/mix" <<'EOF'
#!/bin/sh
[ "${MIX_ENV:-}" = prod ] || { echo "ran outside MIX_ENV=prod: $*" >&2; exit 12; }
[ "${npm_config_maxsockets:-}" = 1 ] || exit 8
[ "${NODE_OPTIONS:-}" = --dns-result-order=ipv4first ] || { echo 'missing IPv4-first build client policy' >&2; exit 9; }
printf '%s\n' "$*" >>"$MIX_LOG"
[ "${CHILD_DIAGNOSTIC:-0}" != 1 ] || printf 'original child diagnostic: %s\n' "$1" >&2
[ "${FAIL_MIX_TASK:-}" != "$1" ] || exit 7
if [ "$1" = deps.get ]; then
    [ ! -e deps ] && [ ! -e _build ] || exit 10
    mkdir deps
    printf 'fresh dependency\n' >deps/fetched
fi
if [ "$1" = deps.compile ]; then
    [ -f deps/fetched ] || exit 11
    mkdir -p _build/prod
fi
if [ "$1" = release ]; then
    mkdir -p _build/prod/rel/demo/bin
    printf '#!/bin/sh\nexit 0\n' >_build/prod/rel/demo/bin/demo
    chmod +x _build/prod/rel/demo/bin/demo
    mkdir -p _build/prod/rel/demo/releases
    printf 'fixture-not-a-secret\n' >_build/prod/rel/demo/releases/COOKIE
fi
EOF
cat >"$TMP/bin/sha256" <<'EOF'
#!/bin/sh
[ "$1" = -q ] || exit 1
sha256sum "$2" | awk '{print $1}'
EOF
cat >"$TMP/bin/elixir" <<'EOF'
#!/bin/sh
[ "${MIX_ENV:-}" = prod ] || { echo "ran outside MIX_ENV=prod: $*" >&2; exit 12; }
[ "${npm_config_maxsockets:-}" = 1 ] || exit 8
[ "${NODE_OPTIONS:-}" = --dns-result-order=ipv4first ] || { echo 'missing IPv4-first build client policy' >&2; exit 9; }
printf '%s\n' "$*" >>"$MIX_LOG"
case "${FAIL_ASSETS:-}:$*" in
    prepare:*--prepare-only|build:*infra.assets) exit 7 ;;
esac
EOF
chmod +x "$TMP/bin/mix" "$TMP/bin/sha256" "$TMP/bin/elixir"
cat >"$TMP/bin/time" <<'EOF'
#!/bin/sh
[ "$1" = -p ] || exit 99
shift
status=0
real=${REMOTE_TIME_SECONDS:-2.125}
unset REMOTE_TIME_SECONDS
"$@" || status=$?
printf 'real %s\nuser 0.1\nsys 0.2\n' "$real" >&2
exit "$status"
EOF
chmod +x "$TMP/bin/time"
export TIME_BIN="$TMP/bin/time" SERAI_PROGRESS_JSONL=1
MIX_LOG="$TMP/mix.log" MIX_BIN="$TMP/bin/mix" ELIXIR_BIN="$TMP/bin/elixir" SHA256_BIN="$TMP/bin/sha256" \
    sh "$ROOT/compute/apps/_lib/artifact_build_phoenix.sh" \
    "$TMP/source" demo "$TMP/output" "$TMP/assets.exs" 2>"$TMP/events"

python3 - "$TMP/events" <<'PYTEST'
import json,sys
e=[json.loads(s) for s in open(sys.argv[1]) if s.startswith('{')]
e=[i for i in e if i.get('event')=='serai.phase_duration']
assert [i['phase'] for i in e]==['asset-prepare','tool-prepare','tool-prepare','dependency-fetch','dependency-compile','asset-build','release-archive'],e
assert all(i['parent']=='remote-total' and i['duration_seconds']==2.125 and i['status']=='completed' for i in e)
PYTEST
cat >"$TMP/expected" <<EOF
-r $TMP/assets.exs -S $TMP/bin/mix infra.assets --prepare-only
local.hex --force --if-missing
local.rebar --force --if-missing
deps.get --only prod
deps.compile
-r $TMP/assets.exs -S $TMP/bin/mix infra.assets
release
EOF
cmp "$TMP/expected" "$TMP/mix.log"
test "$(cat "$TMP/output/release.sha256")" = \
    "$(sha256sum "$TMP/output/release.tar" | awk '{print $1}')"
tar -tf "$TMP/output/release.tar" | grep -q '^./bin/demo$'
if tar -tf "$TMP/output/release.tar" | grep -q '^./releases/COOKIE$'; then
    echo 'generated Erlang cookie leaked into artifact' >&2; exit 1
fi

if MIX_LOG="$TMP/mix.log" MIX_BIN="$TMP/bin/mix" ELIXIR_BIN="$TMP/bin/elixir" SHA256_BIN="$TMP/bin/sha256" \
    sh "$ROOT/compute/apps/_lib/artifact_build_phoenix.sh" \
    "$TMP/source" demo "$TMP/output" "$TMP/assets.exs" >/dev/null 2>&1; then
    echo 'overwrote an existing artifact' >&2; exit 1
fi
worker="$ROOT/compute/apps/_lib/artifact_build_phoenix.sh"
export MIX_BIN="$TMP/bin/mix" ELIXIR_BIN="$TMP/bin/elixir" SHA256_BIN="$TMP/bin/sha256"
mkdir "$TMP/refusal-source"
refuse() {
    export MIX_LOG="$TMP/refusal.log"
    rm -f "$MIX_LOG"
    if sh "$worker" "$TMP/refusal-source" demo "$TMP/refusal-output" "$TMP/assets.exs" "$@" >"$TMP/refusal-error" 2>&1; then
        echo "unexpected worker acceptance: $*" >&2; exit 1
    fi
    test ! -e "$MIX_LOG"
    test ! -e "$TMP/refusal-output"
}
refuse excess
for task in deps.get deps.compile release; do
    mkdir "$TMP/fail-$task"
    export MIX_LOG="$TMP/fail-$task.log"
    if FAIL_MIX_TASK="$task" sh "$worker" "$TMP/fail-$task" demo "$TMP/fail-$task-output" "$TMP/assets.exs" >"$TMP/fail-$task-error" 2>&1; then
        echo "ignored $task failure" >&2; exit 1
    fi
    test ! -e "$TMP/fail-$task-output"
done
for phase in prepare build; do
    mkdir "$TMP/fail-assets-$phase"
    export MIX_LOG="$TMP/fail-assets-$phase.log"
    if FAIL_ASSETS="$phase" sh "$worker" "$TMP/fail-assets-$phase" demo "$TMP/fail-assets-$phase-output" "$TMP/assets.exs" >"$TMP/fail-assets-$phase-error" 2>&1; then
        echo "ignored asset $phase failure" >&2; exit 1
    fi
    test ! -e "$TMP/fail-assets-$phase-output"
done
# Diagnostic failures and unavailable timing never retry or change child status.
cat >"$TMP/bin/time-malformed" <<'EOF'
#!/bin/sh
shift
status=0
"$@" || status=$?
printf 'real not-a-number
' >&2
exit "$status"
EOF
chmod +x "$TMP/bin/time-malformed"
for mode in malformed disabled broken; do
    mkdir "$TMP/$mode"
    export MIX_LOG="$TMP/$mode.log"
    case $mode in
        malformed) TIME_BIN="$TMP/bin/time-malformed" sh "$worker" "$TMP/$mode" demo "$TMP/$mode-output" "$TMP/assets.exs" 2>"$TMP/$mode-events" ;;
        disabled) SERAI_PROGRESS_JSONL=0 sh "$worker" "$TMP/$mode" demo "$TMP/$mode-output" "$TMP/assets.exs" 2>"$TMP/$mode-events" ;;
        broken) sh "$worker" "$TMP/$mode" demo "$TMP/$mode-output" "$TMP/assets.exs" 2>/dev/full ;;
    esac
    cmp "$TMP/expected" "$MIX_LOG"
    test -z "$(find "$TMP/$mode" -name '.phase-time.*' -print)"
done
test ! -s "$TMP/disabled-events"
grep -q '"event":"serai.phase_timing_unavailable"' "$TMP/malformed-events"
if grep -q '"event":"serai.phase_duration"' "$TMP/malformed-events"; then
    echo 'malformed time produced a fabricated duration' >&2; exit 1
fi
mkdir "$TMP/exact-exit"
status=0
MIX_LOG="$TMP/exact-exit.log" CHILD_DIAGNOSTIC=1 FAIL_MIX_TASK=deps.compile TIME_BIN="$TMP/bin/time-malformed" \
    sh "$worker" "$TMP/exact-exit" demo "$TMP/exact-exit-output" "$TMP/assets.exs" 2>"$TMP/exact-exit-events" || status=$?
test "$status" = 7
test "$(grep -c '^original child diagnostic: deps.compile$' "$TMP/exact-exit-events")" = 1
test "$(grep -c '^deps.compile$' "$TMP/exact-exit.log")" = 1
# An isolated mocked remote interval contains child worker intervals; no summed total.
mkdir "$TMP/remote"
MIX_LOG="$TMP/remote.log" REMOTE_TIME_SECONDS=162.606 "$TMP/bin/time" -p sh "$worker" "$TMP/remote" demo "$TMP/remote-output" "$TMP/assets.exs" 2>"$TMP/remote-events"
python3 - "$TMP/remote-events" <<'PYTEST'
import json,sys
lines=open(sys.argv[1]).read().splitlines()
children=[json.loads(s) for s in lines if s.startswith('{')]
# The time fake emits its own fixed real interval after worker teardown.
assert lines[-3:]==['real 162.606','user 0.1','sys 0.2']
assert all(0 <= i['duration_seconds'] == 2.125 <= 162.606 for i in children)
assert not any('total_seconds' in i for i in children)
PYTEST
# A closed stderr pipe sends SIGPIPE to writers; only reporting may fail.
python3 - "$worker" "$TMP" <<'PYPIPE'
import os,pathlib,subprocess,sys
worker,tmp=sys.argv[1:]
for label,task,wanted in [('pipe-success','',0),('pipe-failure','deps.compile',7)]:
 source=pathlib.Path(tmp)/label;source.mkdir()
 env=dict(os.environ,MIX_LOG=str(source)+'.log',FAIL_MIX_TASK=task)
 reader,writer=os.pipe();os.close(reader)
 try:
  p=subprocess.run(['sh',worker,str(source),'demo',str(source)+'-output',tmp+'/assets.exs'],
                   stderr=writer,env=env,timeout=30)
 finally:os.close(writer)
 assert p.returncode==wanted,(label,p.returncode)
 assert (pathlib.Path(str(source)+'-output/release.tar').exists()) == (wanted==0)
PYPIPE
# FreeBSD sh does not pass an assignment prefixed to a function call on to
# the commands the function runs (Linux's bash and dash do), so a
# MIX_ENV=prod timed ... line builds in dev there yet passes here.
if grep -nE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+timed[[:space:]]' "$worker"; then
    echo 'assignment prefixed to timed: export it instead' >&2; exit 1
fi
echo 'ok - Phoenix build creates a checked archive in an isolated output directory'

#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() {
 status=$?
 if [ "$status" -ne 0 ] && [ -f "$TMP/output" ]; then tail -n 20 "$TMP/output" >&2; fi
 rm -rf "$TMP"
}
trap cleanup EXIT
# A copy of the example configuration without its topology; compute/apps/_lib
# marks it as its own engine too, so no command reaches this repository's.
TOPOLOGY="$ROOT/example/serai.sexp"
cp -R "$ROOT/example/." "$TMP/"
rm "$TMP/serai.sexp"
mkdir -p "$TMP/compute/apps/_lib"
(cd "$ROOT/infra" && dune build bin/main.exe)
CLI="$ROOT/infra/_build/default/bin/main.exe"
if (cd "$TMP" && "$CLI" validate) >"$TMP/output" 2>&1; then
 echo 'FAIL - missing topology was silently accepted' >&2
 exit 1
fi
grep -q 'serai.sexp' "$TMP/output"
cp "$TOPOLOGY" "$TMP/"
(cd "$TMP" && "$CLI" validate) >"$TMP/output" 2>&1
cp "$TMP/pipelines.sexp" "$TMP/pipelines.sexp.good"
printf '((default ((nonsense))))\n' >"$TMP/pipelines.sexp"
if (cd "$TMP" && "$CLI" validate) >"$TMP/output" 2>&1; then
 echo 'FAIL - an unreadable pipelines.sexp was accepted' >&2
 exit 1
fi
mv "$TMP/pipelines.sexp.good" "$TMP/pipelines.sexp"
echo 'ok - validate reads pipelines.sexp'
# Unknown placement must fail offline, before any host operation.
sed 's/(hello worker)/(hello absent)/' "$TOPOLOGY" >"$TMP/serai.sexp"
if (cd "$TMP" && "$CLI" validate) >"$TMP/output" 2>&1; then exit 1; fi
grep -q 'unknown host absent' "$TMP/output"
echo 'ok - topology is required and validated offline'

cat >"$TMP/ssh" <<'SH'
#!/bin/sh
while [ "$1" = -o ] || [ "$1" = -J ]; do shift 2; done
printf 'target=%s\n' "$1" >>"$TOPOLOGY_LOG"
shift
printf '%s\n' "$*" >>"$TOPOLOGY_LOG"
SH
printf '#!/bin/sh\nexit 0\n' >"$TMP/rsync"
chmod +x "$TMP/ssh" "$TMP/rsync"
export SSH_BIN="$TMP/ssh" RSYNC_BIN="$TMP/rsync" TOPOLOGY_LOG="$TMP/commands"
: >"$TOPOLOGY_LOG"
if (cd "$TMP" && "$CLI" bootstrap hello) >"$TMP/output" 2>&1; then exit 1; fi
[ ! -s "$TOPOLOGY_LOG" ]
sed -e 's|(edge (os linux)|(secondary (os freebsd) (ssh second-box) (network (subnet 10.20.0.0/24) (gateway 10.20.0.1))) (edge (os linux)|' \
    -e 's/(hello worker)/(hello secondary)/' \
    "$TOPOLOGY" >"$TMP/serai.sexp"
(cd "$TMP" && "$CLI" bootstrap hello) >"$TMP/output" 2>&1
[ "$(grep '^target=' "$TOPOLOGY_LOG" | sort -u)" = 'target=second-box' ]
grep -Fq 'mkdir "$lock"' "$TOPOLOGY_LOG"
echo 'ok - executable routes bootstrap and mutation lock to configured second host'
: >"$TOPOLOGY_LOG"
if (cd "$TMP" && COMPUTE_TARGET=old-override "$CLI" bootstrap hello) >"$TMP/output" 2>&1; then exit 1; fi
grep -q 'configure hosts in serai.sexp' "$TMP/output"
[ ! -s "$TOPOLOGY_LOG" ]
echo 'ok - obsolete host overrides are refused before effects'

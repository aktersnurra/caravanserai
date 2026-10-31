#!/usr/bin/env bash
# serai update: argv, its settings file, and what a run prints. A run with
# nothing new prints nothing, so cron mails only when something happened.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
(cd "$ROOT/serai" && dune build bin/main.exe)
CLI="$ROOT/serai/_build/default/bin/main.exe"
# Every outside program fails and leaves a note: the configuration's
# remote is unreachable, and no host may ever be contacted.
printf '#!/bin/sh\necho "$0 $*" >>"%s/contacted"\necho "fake: unreachable" >&2\nexit 1\n' "$TMP" >"$TMP/fake"
chmod +x "$TMP/fake"
mkdir -p "$TMP/home"
run() {
  (cd "$TMP" && HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config" XDG_STATE_HOME="$TMP/home/.local/state" \
    SERAI_CACHE="$TMP/cache" SERAI_STORE="$TMP/store" \
    SSH_BIN="$TMP/fake" RSYNC_BIN="$TMP/fake" CURL_BIN="$TMP/fake" JJ_BIN="$TMP/fake" \
    "$CLI" update "$@") >"$TMP/output" 2>"$TMP/error"
}

if run --bogus; then echo 'FAIL - update accepted an unknown flag' >&2; exit 1; fi
grep -q '^usage:' "$TMP/error"

if run; then echo 'FAIL - update ran without its settings' >&2; exit 1; fi
grep -Fq 'update: ' "$TMP/output"
grep -Fq 'update.sexp' "$TMP/output"

mkdir -p "$TMP/home/.config/serai"
printf '((config (git file:///nowhere)) (signers (A)) (gnupghome /g))\n' >"$TMP/home/.config/serai/update.sexp"
if run; then echo 'FAIL - update ran with malformed settings' >&2; exit 1; fi
grep -Fq 'update: update.sexp' "$TMP/output"
test ! -e "$TMP/contacted"

if run --json; then echo 'FAIL - update --json ran with malformed settings' >&2; exit 1; fi
test "$(wc -l <"$TMP/output")" -eq 1
grep -Fq '"operation":"update"' "$TMP/output"
grep -Fq '"code":"not_applied"' "$TMP/output"

printf '((config (git file:///nowhere) (bookmark master)) (signers (A)) (gnupghome /g))\n' \
  >"$TMP/home/.config/serai/update.sexp"
if run; then echo 'FAIL - update succeeded with an unreachable configuration' >&2; exit 1; fi
grep -q '^configuration: unavailable: ' "$TMP/output"
# What the run printed, its subprocesses included, follows as context.
grep -Fq -- '--- log ---' "$TMP/output"
grep -Fq 'fake: unreachable' "$TMP/output"
test ! -s "$TMP/error"
test "$(stat -c %a "$TMP/home/.local/state/serai/update")" = 700

# The same result again is not news: nothing printed, success.
run
test ! -s "$TMP/output"
test ! -s "$TMP/error"

if run --plan; then echo 'FAIL - update --plan succeeded without its configuration' >&2; exit 1; fi
grep -q '^update: \|^configuration: unavailable' "$TMP/output"
# --plan lists what is; it reports the unavailable configuration every time.
grep -q 'configuration: unavailable' "$TMP/output"

if grep -v '/fake git' "$TMP/contacted" >/dev/null; then
  echo 'FAIL - update contacted something besides the configuration remote' >&2; cat "$TMP/contacted" >&2; exit 1
fi
echo 'ok - serai update checks its settings, prints only news, and contacts no host without a verified configuration'

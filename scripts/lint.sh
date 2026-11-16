#!/usr/bin/env bash
# Lint the engine: shellcheck, serai's build and tests, the example
# configuration's render (shellchecked and, with caddy installed, validated)
# and every tests/*.sh. Set LINT_REQUIRE_CADDY=1 to fail without caddy.
set -euo pipefail

cd "$(dirname "$0")/.."

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

# Runs a check with its output held back: a passing check prints only its
# green summary line, a failing one shows everything it printed.
run_quiet() {
  local log status=0
  log=$(mktemp)
  "$@" >"$log" 2>&1 || status=$?
  if [ "$status" -ne 0 ]; then
    cat "$log"
  fi
  rm -f "$log"
  return "$status"
}

fail=0

# ---------------------------------------------------------------------------
# 1. Shellcheck
# ---------------------------------------------------------------------------
# Every script is found, not listed: a new one cannot be left out. A file
# with a shell shebang is checked in that dialect; the sourced libraries
# without one are named with theirs.
shell_scripts() {
  local file
  while IFS= read -r file; do
    case "$(head -c 64 "$file" | head -n 1)" in
      '#!'*sh*) printf '%s\n' "$file" ;;
    esac
  done < <(find compute edge scripts tests example -type f | LC_ALL=C sort)
  printf '%s\n' compute/apps/_lib/logging/central-logging.rc.template
}
SHELL_LIBS=(
  compute/apps/_lib/check.sh
  compute/apps/_lib/deploy.sh
)
# Artifact helpers run under FreeBSD /bin/sh (or the guest's sh): check them
# all in that dialect.
SHELL_SH_LIBS=(compute/apps/_lib/artifact_*.sh)

echo "→ shellcheck"
if ! command -v shellcheck >/dev/null 2>&1; then
  red "  shellcheck not installed"
  fail=1
else
  while IFS= read -r s; do
    case "$s" in compute/apps/_lib/artifact_*.sh) continue ;; esac
    shellcheck --severity=warning --exclude=SC1091 "$s" || fail=1
  done < <(shell_scripts | LC_ALL=C sort -u)
  for s in "${SHELL_LIBS[@]}"; do
    shellcheck --severity=warning --exclude=SC1091 --shell=bash "$s" || fail=1
  done
  for s in "${SHELL_SH_LIBS[@]}"; do
    shellcheck --severity=warning --exclude=SC1091 --shell=sh --external-sources "$s" || fail=1
  done
  [ "$fail" -eq 0 ] && green "  shellcheck clean"
fi

# ---------------------------------------------------------------------------
# 2. serai's build and tests
# ---------------------------------------------------------------------------
echo "→ serai build and tests"
if run_quiet sh -c 'cd serai && dune build && dune runtest'; then
  green "  serai/ builds and its tests pass"
else
  red "  serai/ build or tests failed"
  fail=1
fi
SERAI="$PWD/serai/_build/default/bin/main.exe"

# ---------------------------------------------------------------------------
# 3. The example configuration's render
# ---------------------------------------------------------------------------
echo "→ serai validate (example/)"
RENDERED="$(mktemp -d)"
trap 'rm -rf "$RENDERED"' EXIT
rendered=0
if [ -x "$SERAI" ] && run_quiet sh -c 'cd example && "$1" validate --out "$2"' sh "$SERAI" "$RENDERED"; then
  rendered=1
  green "  the example validates, agrees with its shell configs and renders"
else
  fail=1
fi

# SC2034: SCRIPT_DIR is part of every script's header but only used by apps
# with extra steps.
echo "→ shellcheck rendered jail scripts"
if [ "$rendered" -eq 0 ]; then
  echo "  skipped (validate failed)"
else
  jails_clean=1
  for s in "$RENDERED"/jails/*.sh; do
    shellcheck --severity=warning --exclude=SC1091,SC2034 --shell=sh "$s" || jails_clean=0
  done
  if [ "$jails_clean" -eq 1 ]; then
    green "  every rendered jail script is shellcheck clean"
  else
    fail=1
  fi
fi

echo "→ caddy validate"
if [ "$rendered" -eq 0 ]; then
  echo "  skipped (validate failed)"
elif ! command -v caddy >/dev/null 2>&1; then
  if [ "${LINT_REQUIRE_CADDY:-0}" = "1" ]; then
    red "  caddy not installed (install: https://caddyserver.com/docs/install)"
    fail=1
  else
    echo "  caddy not installed — skipped (set LINT_REQUIRE_CADDY=1 to enforce)"
  fi
elif run_quiet caddy validate --adapter caddyfile --config "$RENDERED/caddy/Caddyfile"; then
  green "  the example's rendered Caddy tree validates"
else
  red "  caddy validate failed"
  fail=1
fi

# ---------------------------------------------------------------------------
# 4. Every shell test
# ---------------------------------------------------------------------------
echo "→ shell tests"
for shell_test in tests/*.sh; do
  if run_quiet bash "$shell_test"; then
    green "  $shell_test passed"
  else
    red "  $shell_test failed"
    fail=1
  fi
done

exit "$fail"

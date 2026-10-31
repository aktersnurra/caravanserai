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
SHELL_SCRIPTS=(
  compute/01-base
  compute/apps/_lib/logging/bootstrap.sh
  compute/apps/_lib/logging/central-logging.rc.template
  compute/apps/_lib/logging/installed-state.sh
  compute/apps/_lib/logging/target-manifest.sh
  example/apps/logs/check-forwarding
  example/guests/ledger/logging
  edge/00-headscale
  edge/01-tailscale
  edge/02-caddy
  edge/03-logging
  edge/04-vmui-auth
  scripts/install.sh
  scripts/lint.sh
  scripts/push.sh
  tests/test_caddy_lifecycle.sh
  tests/test_hooks.sh
  tests/test_artifact_install.sh
  tests/test_artifact_build_phoenix.sh
  tests/test_artifact_build_jail.sh
  tests/test_artifact_verify_source.sh
  tests/test_artifact_activate.sh
  tests/test_artifact_apply.sh
  tests/test_artifact_apply_cli.sh
  tests/test_artifact_lifecycle.sh
  tests/test_topology_cli.sh
  tests/test_up_cli.sh
  tests/test_agent_cli.sh
  tests/test_artifact_host_runner.sh
  tests/test_logging_policy_contract.sh
  tests/test_logging_retry.sh
  tests/test_logging_recovery.sh
  tests/test_freebsd_forwarding.sh
  tests/test_caddy_access_redaction.sh
  tests/test_vmui_auth_contract.sh
  tests/test_edge_logging_contract.sh
  tests/stat-field
)
SHELL_LIBS=(
  compute/apps/_lib/check.sh
  compute/apps/_lib/deploy.sh
)
# Artifact helpers run under FreeBSD /bin/sh (or the guest's sh): check them
# all in that dialect, so a new helper cannot be left out of the list.
SHELL_SH_LIBS=(compute/apps/_lib/artifact_*.sh)

echo "→ shellcheck"
if ! command -v shellcheck >/dev/null 2>&1; then
  red "  shellcheck not installed"
  fail=1
else
  for s in "${SHELL_SCRIPTS[@]}"; do
    shellcheck --severity=warning --exclude=SC1091 "$s" || fail=1
  done
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

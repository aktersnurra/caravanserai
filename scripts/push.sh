#!/usr/bin/env bash
# scripts/push.sh
# Runs lint before pushing. Passes any args through to `jj git push`.
#   ./scripts/push.sh
#   ./scripts/push.sh --bookmark master
# `jj push` runs this too, via a repo-local alias (not versioned, set once):
#   jj config set --repo aliases.push '["util", "exec", "--", "./scripts/push.sh"]'
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/lint.sh

jj git push "$@"

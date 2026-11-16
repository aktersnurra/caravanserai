#!/usr/bin/env bash
# Every failure that can reach a result names its cause (Run_state.fail),
# so error.cause is never null by omission. The failwith sites below are
# the exceptions: each is caught in its own module and returned as an
# Error, and the cause is given where that Error is unwrapped.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL - $*" >&2; exit 1; }
internal=(
  'app_config.ml:failwith (Env_template.error_message error)'
  'app_scaffold.ml:failwith "unbalanced )"'
  'app_scaffold.ml:failwith "unsupported syntax"'
  'app_scaffold.ml:failwith "unbalanced ("'
  'artifact_recipe.ml:failwith "artifact recipe: builder script must be regular"'
  'artifact_store.ml:failwith "artifact store: source is not regular"'
  'fs.ml:failwith not_regular'
  'run_state.ml:failwith message'
  'source_inventory.ml:failwith "source inventory: '
  'source_snapshot.ml:failwith "jj metadata exceeds 8 MiB"'
  'source_snapshot.ml:failwith "invalid staging directory"'
  'source_snapshot.ml:failwith "jj could not export a tracked file"'
  'source_snapshot.ml:failwith "output already exists"'
  'topology.ml:failwith ("topology: " ^ message)'
  'update.ml:failwith "config needs a git remote and a bookmark"'
  'update.ml:failwith "signers must name at least one key"'
  'update.ml:failwith "gnupghome must be an absolute path"'
)
bare=$(cd "$ROOT/serai" && grep -Hn 'failwith' lib/*.ml bin/*.ml | grep -v 'Run_state.fail ~cause' || true)
while IFS= read -r site; do
  [ -n "$site" ] || continue
  allowed=0
  for entry in "${internal[@]}"; do
    # entry is <file>:<text of the call>; site is <dir>/<file>:<line>:<code>
    if [[ "$site" == */"${entry%%:*}":* && "$site" == *"${entry#*:}"* ]]; then allowed=1; break; fi
  done
  [ "$allowed" = 1 ] || fail "$site: a failure that can reach a result needs Run_state.fail ~cause (or, if its module catches it, an entry here)"
done <<<"$bare"
echo 'ok - every failure that can reach a result names its cause'

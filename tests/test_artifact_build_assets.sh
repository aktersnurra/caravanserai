#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/serai/_build/prepared-builder"
PRIVATE_TMP="$(mktemp -d "$ROOT/serai/_build/prepared-builder/assets-XXXXXXXX")"
chmod 700 "$PRIVATE_TMP"
export TMPDIR="$PRIVATE_TMP"
TMP="$(mktemp -d "$TMPDIR/fixture-XXXXXXXX")"
trap 'rm -rf "$PRIVATE_TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/source/assets/css" "$TMP/source/assets/vendor" "$TMP/source/config" "$TMP/source/lib"
printf 'defmodule Fixture do\n  def public_fixture, do: :ok\nend\n' >"$TMP/source/lib/fixture.ex"
printf '@plugin "../vendor/daisyui" { themes: false; }\n@plugin "../vendor/daisyui-theme" { name: "test"; }\n' >"$TMP/source/assets/css/app.css"
for plugin in daisyui daisyui-theme; do
    printf 'var __toCommonJS = x => x;\nmodule.exports = __toCommonJS({default: Object.assign(options => ({handler() {}, config: options}), {__isOptionsFunction: true})});\n' >"$TMP/source/assets/vendor/$plugin.js"
done
sha256sum "$TMP/source/assets/css/app.css" "$TMP/source/assets/vendor/"*.js >"$TMP/source-before"
cat >"$TMP/bin/npm" <<'EOF'
#!/bin/sh
[ "${FAIL_NPM:-0}" != 1 ] || exit 7
[ "$1" = install ] && [ "$2" = --prefix ] || exit 1
[ "$7" = @tailwindcss/cli@4.1.12 ] || exit 1
mkdir -p "$3/node_modules/.bin" "$3/node_modules/tailwindcss"
printf '#!/bin/sh\nexit 0\n' >"$3/node_modules/.bin/tailwindcss"
chmod +x "$3/node_modules/.bin/tailwindcss"
printf '%s\n' "$*" >>"$ASSETS_LOG"
EOF
chmod +x "$TMP/bin/npm"
cat >"$TMP/source/mix.exs" <<'EOF'
defmodule Fixture.MixProject do
  use Mix.Project
  def project, do: [app: :fixture, version: "0.1.0", deps: [],
    compilers: if(System.get_env("FAIL_PROJECT_COMPILE"), do: [:primary], else: Mix.compilers())]
end
EOF
cat >"$TMP/source/config/config.exs" <<'EOF'
import Config
config :tailwind, version: "4.1.12", path: System.get_env("EXPLICIT_TAILWIND"),
  fixture: [args: ["--input=assets/css/app.css"], cd: Path.expand("..", __DIR__)]
EOF
printf 'raise "RUNTIME_CONFIG_MUST_NOT_BE_READ"\n' >"$TMP/source/config/runtime.exs"
cat >"$TMP/tasks.exs" <<'EOF'
defmodule Mix.Tasks.Compile.Primary do
  use Mix.Task
  def run(_), do: raise("PRIMARY_PROJECT_COMPILE")
end
defmodule Mix.Tasks.Infra.FailProbe do
  use Mix.Task
  def run(_) do
    try do
      Mix.Task.run("infra.assets")
      raise "compiler unexpectedly completed"
    rescue
      error ->
        if Exception.message(error) != "PRIMARY_PROJECT_COMPILE", do: reraise(error, __STACKTRACE__)
        File.write!(System.fetch_env!("EXCEPTION_RECEIPT"), Exception.message(error))
    end
  end
end
defmodule Mix.Tasks.Assets.Setup do
  use Mix.Task
  def run(_) do
    path = Application.fetch_env!(:tailwind, :path)
    unless File.exists?(path), do: raise("Tailwind path missing before setup")
    File.mkdir_p!("assets/node_modules")
    File.write!(System.fetch_env!("ASSETS_LOG"), "setup\n", [:append])
  end
end
defmodule Mix.Tasks.Assets.Deploy do
  use Mix.Task
  def run(_) do
    unless File.exists?("_build/prod/lib/fixture/ebin/Elixir.Fixture.beam"),
      do: raise("project compile must precede assets deploy for colocated hooks")
    unless File.exists?("assets/node_modules/tailwindcss"), do: raise("CSS import cannot resolve Tailwind")
    ["--input=" <> path] = Application.fetch_env!(:tailwind, :fixture)[:args]
    if path == "assets/css/app.css", do: raise("vendored plugin input was not adapted")
    unless String.contains?(File.read!(path), ".infra-daisyui.cjs"), do: raise("missing plugin shim input")
    File.write!(System.fetch_env!("ASSETS_LOG"), "deploy\n", [:append])
  end
end
EOF
# Reproduce the original runtime-config leak with the real Mix implementation.
if (cd "$TMP/source" && MIX_ENV=prod mix run --no-start --no-compile -e ':ok') >"$TMP/legacy-error" 2>&1; then
    echo 'legacy mix run unexpectedly skipped runtime config' >&2; exit 1
fi
grep -q RUNTIME_CONFIG_MUST_NOT_BE_READ "$TMP/legacy-error"
run() {
    local log=$1
    shift
    (cd "$TMP/source" && PATH="$TMP/bin:$PATH" MIX_ENV=prod ASSETS_LOG="$TMP/$log" \
      elixir -r "$TMP/tasks.exs" -r "$ROOT/compute/apps/_lib/artifact_build_assets.exs" -S mix infra.assets "$@")
}
run prepare-log --prepare-only
if grep -Eq '^(setup|deploy)$' "$TMP/prepare-log"; then
    echo 'preflight ran asset tasks' >&2; exit 1
fi
SERAI_PROGRESS_JSONL=1 run log 2>"$TMP/compile-events"
python3 - "$TMP/compile-events" <<'PYTEST'
import json,sys
items=[json.loads(s) for s in open(sys.argv[1]) if s.startswith('{')]
e=[i for i in items if i.get('event')=='serai.phase_duration']
assert len(e)==1,e
assert e[0]['phase']=='project-compile' and e[0]['parent']=='asset-build'
assert e[0]['status']=='completed' and e[0]['duration_seconds']>=0 and e[0]['reason'] is None
PYTEST
test "$(tail -2 "$TMP/log")" = $'setup\ndeploy'
test -L "$TMP/source/assets/node_modules/tailwindcss"
node -e 'for (const name of ["daisyui", "daisyui-theme"]) { const plugin = require(process.argv[1]+"/.infra-"+name+".cjs"); if (typeof plugin !== "function" || !plugin.__isOptionsFunction) throw Error("plugin options export lost"); }' "$TMP/source/assets/vendor"
sha256sum "$TMP/source/assets/css/app.css" "$TMP/source/assets/vendor/"*.js >"$TMP/source-after"
cmp "$TMP/source-before" "$TMP/source-after"
EXPLICIT_TAILWIND="$TMP/source/_build/infra-tailwind/node_modules/.bin/tailwindcss" run explicit-log
test "$(cat "$TMP/explicit-log")" = $'setup\ndeploy'
# Compile raises while diagnostic stderr is unusable: the exact primary survives.
(cd "$TMP/source" && PATH="$TMP/bin:$PATH" MIX_ENV=prod ASSETS_LOG="$TMP/failure-probe-log" \
  FAIL_PROJECT_COMPILE=1 SERAI_PROGRESS_JSONL=1 EXCEPTION_RECEIPT="$TMP/exception-receipt" \
  elixir -r "$TMP/tasks.exs" -r "$ROOT/compute/apps/_lib/artifact_build_assets.exs" -S mix infra.fail_probe) 2>/dev/full
test "$(cat "$TMP/exception-receipt")" = PRIMARY_PROJECT_COMPILE
# A failed project compile emits failed, not completed, when stderr works.
(cd "$TMP/source" && PATH="$TMP/bin:$PATH" MIX_ENV=prod ASSETS_LOG="$TMP/failure-probe-log" \
  FAIL_PROJECT_COMPILE=1 SERAI_PROGRESS_JSONL=1 EXCEPTION_RECEIPT="$TMP/exception-receipt" \
  elixir -r "$TMP/tasks.exs" -r "$ROOT/compute/apps/_lib/artifact_build_assets.exs" -S mix infra.fail_probe) 2>"$TMP/failed-events"
grep -q '"status":"failed"' "$TMP/failed-events"
rm "$TMP/source/_build/infra-tailwind/.infra-package"
if FAIL_NPM=1 run failure-log >"$TMP/error" 2>&1; then
    echo 'Tailwind install failure was ignored' >&2; exit 1
fi
grep -q 'native Tailwind CLI installation failed' "$TMP/error"
test ! -e "$TMP/failure-log"
echo 'ok - real Mix asset task avoids runtime config and uses the pinned native CLI'

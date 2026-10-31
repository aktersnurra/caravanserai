#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Source-only local contract: never invoke a host_artifact executable here.
# dune build @all separately compiles the unchanged runner.
python3 - "$ROOT/infra/test/host_artifact_build_candidate.ml" <<'PYGUARD'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
prefix = '''let run () =
  if Sys.getenv_opt "INFRA_ARTIFACT_HOST_TEST" <> Some "1" then
    failwith "host test: explicit opt-in required (INFRA_ARTIFACT_HOST_TEST=1)";
  if not (Unix.isatty Unix.stdin) then
    failwith "host test: real terminal required for SSH/security-key or doas prompts";
'''
assert text.count('let run () =') == 1
start = text.index('let run () =')
assert text[start:].startswith(prefix), 'opt-in/TTY guards must be the exact run prologue'
end = start + len(prefix)
for entry in ['Array.to_list Sys.argv', 'Layout.discover', 'Declaration.load',
              'In_channel.input_line stdin', 'Proc.live']:
    assert text.index(entry) >= end, f'{entry} must follow both guards'
assert '| _ :: "--app" :: name :: rest -> name, rest' in text, 'the app is always named'
PYGUARD
# Dispatcher commands are algebraic effects. The host runner must install the
# same live handler and Ctrl-C unwinding as the production infra entry point.
grep -Fq 'Proc.live (fun () -> Dispatcher.artifact_build_candidate' \
    "$ROOT/infra/test/host_artifact_build_candidate.ml"
grep -Fq 'Sys.catch_break true' "$ROOT/infra/test/host_artifact_build_candidate.ml"
echo 'ok - host runner source-contract guards/effect handling only; compilation is covered by @all, no dynamic/native execution'

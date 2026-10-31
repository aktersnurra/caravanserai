#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/infra"
dune build bin/main.exe
python3 - "$ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
exe = root / 'infra/_build/default/bin/main.exe'
# Inside this repository, so the copied configuration's engine is the one
# above it.
with tempfile.TemporaryDirectory(prefix='infra-progress-', dir=root / 'infra/_build') as directory:
    temporary = Path(directory)
    # The example configuration plus a package app.
    config = temporary / 'config'
    shutil.copytree(root / 'example', config)
    (config / 'apps/garage').mkdir()
    (config / 'apps/garage/app.sexp').write_text(
        (root / 'infra/test/fixtures/executable_apps/garage/app.sexp').read_text())
    topology = config / 'serai.sexp'
    topology.write_text(topology.read_text()
                        .replace('(logs worker)', '(logs worker) (garage worker)')
                        .replace('(proxy (hello counter logs ledger))', '(proxy (hello counter logs ledger garage))'))
    (config / 'edge/caddy/sites/42-garage.caddy.template').write_text(
        '__GARAGE_HOSTNAME__ {\n    reverse_proxy __GARAGE_IP__:__GARAGE_S3_PORT__\n}\n')
    calls = temporary / 'calls'
    ssh = temporary / 'ssh'
    ssh.write_text('#!/bin/sh\nprintf "ssh\\n" >>"$CALLS"\ncase "$*" in *INFRA_LOCK_HELD=1*) exit 255 ;; esac\nexit 0\n')
    rsync = temporary / 'rsync'
    rsync.write_text('#!/bin/sh\nprintf "rsync\\n" >>"$CALLS"\nexit 0\n')
    ssh.chmod(0o700)
    rsync.chmod(0o700)
    env = dict(os.environ, SSH_BIN=str(ssh), RSYNC_BIN=str(rsync), CALLS=str(calls))

    def run(*args):
        return subprocess.run([str(exe), *args], cwd=config, env=env,
                              capture_output=True, text=True, timeout=15)

    def events(result):
        parsed = []
        for line in result.stderr.splitlines():
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(item, dict) and item.get('event') == 'infra.progress':
                parsed.append(item)
        return parsed

    plain = run('validate')
    reported = run('validate', '--progress=jsonl')
    assert reported.returncode == 0, 'progress flag must not reject an existing command'
    assert reported.stdout == plain.stdout, 'progress must preserve stdout'
    observed = events(reported)
    assert observed, 'progress mode must emit structured events'
    assert observed[0]['status'] == 'running' and observed[-1]['status'] == 'succeeded'
    assert any(item['phase'] == 'validate' for item in observed)
    assert all(item['elapsed_seconds'] >= 0 and item['timestamp'].endswith('Z') for item in observed)
    assert not events(plain), 'default command output must remain unchanged'
    assert not calls.exists(), 'offline validation must not contact a host'

    store = temporary / 'store'
    store.mkdir(mode=0o700)
    rejected = run('artifact', 'upgrade', 'hello', '--identity', 'a' * 64,
                   '--store', str(store), '--yes', '--progress=jsonl')
    assert rejected.returncode == 1
    observed = events(rejected)
    assert observed and observed[-1]['status'] == 'failed', 'local refusal must report failure'
    assert observed[-1]['phase'] == 'verify', 'failure must identify the actual phase'
    assert not calls.exists(), 'missing artifact must refuse before host work'

    base = temporary / 'base.txz'
    base.write_bytes(b'public synthetic base fixture')
    uncertain = run('artifact', 'build', 'garage', '--ip', '10.20.0.200',
                    '--base', str(base), '--sha256', hashlib.sha256(base.read_bytes()).hexdigest(),
                    '--store', str(store), '--yes', '--progress=jsonl')
    assert uncertain.returncode == 1
    observed = events(uncertain)
    assert observed and observed[-1]['status'] == 'unknown', 'uncertain transport must not claim a known outcome'
    assert observed[-1]['phase'] == 'build'
    assert 'lock retained' in uncertain.stderr
    assert not any(item['status'] == 'succeeded' for item in observed)

    # Real committed source fixture, mocked transport: remote-total is one helper
    # invocation including teardown, not a compilation or sum of worker spans.
    # Outside this repository: a checkout nested in it is not its own.
    source = Path(tempfile.mkdtemp(prefix='infra-progress-source-'))
    subprocess.run(['jj', 'git', 'init', str(source)], check=True, capture_output=True, timeout=30)
    (source / 'mix.exs').write_text('public committed source fixture\n')
    subprocess.run(['jj', 'describe', '-m', 'progress source fixture'], cwd=source,
                   check=True, capture_output=True, timeout=30)
    subprocess.run(['jj', 'new'], cwd=source, check=True, capture_output=True, timeout=30)
    hello = config / 'apps/hello/app.sexp'
    hello.write_text(hello.read_text().replace('/home/ops/src/hello', str(source)))
    source_failure = run('artifact', 'build', 'hello', '--revision', '@-', '--ip', '10.20.0.200',
                         '--base', str(base), '--sha256', hashlib.sha256(base.read_bytes()).hexdigest(),
                         '--store', str(store), '--yes', '--progress=jsonl')
    assert source_failure.returncode == 1, source_failure.stderr
    spans = [json.loads(line) for line in source_failure.stderr.splitlines() if line.startswith('{')]
    spans = [item for item in spans if item.get('event') == 'infra.phase_duration']
    assert spans, source_failure.stderr
    assert spans[0]['phase'] == 'source' and spans[0]['status'] == 'completed', source_failure.stderr
    assert any(item['phase'] == 'outbound-transfer' for item in spans), spans
    assert len([item for item in spans if item['phase'] == 'remote-total']) == 1, spans
    assert spans[-1]['phase'] == 'remote-total' and spans[-1]['status'] == 'failed', spans
    for item in spans:
        assert set(item) == {'event','operation','workload','phase','parent','status','duration_seconds','reason'}
        assert item['parent'] is None and item['reason'] is None
        assert isinstance(item['duration_seconds'], (int,float)) and item['duration_seconds'] >= 0
        assert item['operation'] == 'artifact.build' and item['workload'] == 'hello'
    shutil.rmtree(source)

    quoted = 'unknown"\nworkload'
    escaped = run('artifact', 'plan', quoted, '--progress=jsonl')
    assert escaped.returncode == 1
    assert events(escaped)[-1]['workload'] == quoted, 'progress must remain valid JSON for quoted input'
    with open('/dev/full', 'w') as broken:
        result = subprocess.run([str(exe), 'validate', '--progress=jsonl'], cwd=config,
                                env=env, stdout=subprocess.PIPE, stderr=broken, text=True, timeout=15)
    assert result.returncode == 0, 'failed diagnostic writes must not fail the operation'
    assert result.stdout == plain.stdout

    usage = run('--progress=jsonl', 'not-a-command')
    assert usage.returncode == 1 and events(usage)[-1]['status'] == 'failed'
    print('ok - CLI progress streams actual phases/outcomes, preserves output and reports uncertain transport honestly')
PY

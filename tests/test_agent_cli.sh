#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$ROOT/serai" && dune build bin/main.exe)
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
exe = root / 'serai/_build/default/bin/main.exe'
with tempfile.TemporaryDirectory(prefix='serai-agent-cli-') as directory:
    fixture = Path(directory)
    # A copy of the example configuration, plus a pinned binary it does not
    # declare; compute/apps/_lib marks it as its own engine too.
    shutil.copytree(root / 'example', fixture, dirs_exist_ok=True)
    (fixture / 'compute/apps/_lib').mkdir(parents=True)
    binary = (root / 'serai/test/fixtures/executable_apps/idp/app.sexp').read_text()
    (fixture / 'apps/idp').mkdir()
    (fixture / 'apps/idp/app.sexp').write_text(binary)
    topology = fixture / 'serai.sexp'
    topology.write_text(topology.read_text()
                        .replace('(logs worker)', '(logs worker) (idp worker)')
                        .replace('(proxy (hello counter logs ledger))', '(proxy (hello counter logs ledger idp))'))
    (fixture / 'edge/caddy/sites/43-idp.caddy.template').write_text(
        '__IDP_HOSTNAME__ {\n    reverse_proxy __IDP_IP__:__IDP_HTTP_PORT__\n}\n')
    calls = fixture / 'unexpected-calls'
    deny = fixture / 'deny'
    deny.write_text('#!/bin/sh\nprintf "called\\n" >>"$CALLS"\nexit 99\n')
    deny.chmod(0o700)
    env = dict(os.environ, SSH_BIN=str(deny), RSYNC_BIN=str(deny),
               CURL_BIN=str(deny), JJ_BIN=str(deny), CALLS=str(calls))

    def run(*args, cwd=fixture):
        result = subprocess.run([str(exe), *args], cwd=cwd, env=env,
                                capture_output=True, text=True, timeout=15)
        try:
            body = json.loads(result.stdout)
        except json.JSONDecodeError:
            raise AssertionError(f'{args}: expected one JSON result, got exit={result.returncode}, stdout={result.stdout!r}')
        assert body['schema_version'] == 1
        assert body['status'] in ('succeeded', 'refused', 'failed', 'interrupted')
        assert not calls.exists(), 'read-only agent API invoked a remote/build tool'
        return result, body

    result, body = run('validate', '--json')
    assert result.returncode == 0 and body['operation'] == 'validate'
    assert body['status'] == 'succeeded' and body['error'] is None
    assert body['data']['apps'] == 4 and body['data']['guests'] == 1
    assert body['data']['host_inspected'] is False
    assert not (fixture / 'rendered').exists()

    _, inventory = run('inspect', '--json')
    assert inventory['data']['scope'] == 'declaration'
    hosts = {h['id']: h for h in inventory['data']['hosts']}
    assert hosts['worker']['ssh_target'] == 'worker'
    workloads = {w['name']: w for w in inventory['data']['workloads']}
    assert workloads['hello']['host_id'] == 'worker'
    assert workloads['ledger']['kind'] == 'linux_guest'
    assert workloads['ledger']['ssh_jumps'] == ['worker']
    assert inventory['data']['host_inspected'] is False

    _, plan = run('artifact', 'plan', 'hello', '--revision', 'master', '--json')
    assert plan['operation'] == 'artifact.plan'
    assert plan['data']['kind'] == 'design_preview'
    assert plan['data']['artifact_identity'] is None
    assert plan['data']['source_verified'] is False
    assert plan['data']['origin']['requested_revision'] == 'master'
    assert plan['data']['target']['host_id'] == 'worker'
    _, packages = run('artifact', 'plan', 'logs', '--json')
    assert packages['data']['origin']['kind'] == 'freebsd_packages'
    assert packages['data']['artifact_identity'] is None
    for name, kind in [('counter', 'ocaml_source'), ('ledger', 'guest_source')]:
        _, source = run('artifact', 'plan', name, '--revision', 'master', '--json')
        assert source['data']['origin']['kind'] == kind
    _, binary = run('artifact', 'plan', 'idp', '--json')
    assert binary['data']['origin']['kind'] == 'pinned_binary'
    result, unsupported = run('bootstrap', 'hello', '--json', cwd=Path('/'))
    assert result.returncode == 1 and unsupported['error']['code'] == 'unsupported_operation'

    for args, code in [
        (('artifact', 'plan', 'hello', '--json'), 'invalid_plan'),
        (('artifact', 'plan', 'unknown"\nname', '--json'), 'unknown_workload'),
        (('bootstrap', 'hello', '--yes', '--json'), 'unsupported_operation'),
        (('up', 'hello', '--revision', 'master', '--json'), 'unsupported_operation'),
        (('artifact', 'build', 'hello', '--revision', 'master', '--ip', '10.20.0.250',
          '--base', 'missing', '--sha256', 'missing', '--store', 'missing', '--json'), 'unsupported_operation'),
        (('validate', '--out', str(fixture / 'rendered'), '--json'), 'invalid_request'),
        (('inspect', '--json', '--json'), 'invalid_request')]:
        result, body = run(*args)
        assert result.returncode == 1 and body['status'] == 'refused'
        assert body['data'] is None and body['error']['code'] == code, body
    assert not (fixture / 'rendered').exists()
    for args in [('artifact', 'build', 'hello', '--base', 'missing'),
                 ('artifact', 'upgrade', 'hello', '--identity', 'missing')]:
        result, body = run(*args, '--yes', '--json', cwd=Path('/'))
        assert result.returncode == 1 and body['error']['code'] == 'unsupported_operation'
    result, body = run('validate', '--json', '--progress=jsonl')
    assert result.returncode == 0
    events = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{')]
    assert events[-1]['status'] == 'succeeded'
    assert events[-1]['operation'] == 'validate'

    # serai new writes the declaration and touches no host: jj only reads
    # the checkout's origin.
    checkout = fixture / 'greeter-src'
    (checkout / 'lib/greeter').mkdir(parents=True)
    (checkout / 'mix.exs').write_text('defmodule Greeter.MixProject do\n  def project, do: [app: :greeter]\nend\n')
    fake_jj = fixture / 'fake-jj'
    fake_jj.write_text('#!/bin/sh\ncase "$*" in *"git remote list"*) echo "origin git@example.org:greeter.git";; '
                       '*) printf "called\\n" >>"$CALLS"; exit 99;; esac\n')
    fake_jj.chmod(0o700)
    env['JJ_BIN'] = str(fake_jj)
    result, body = run('new', 'greeter', '--kind', 'phoenix', '--repo', str(checkout), '--json')
    assert result.returncode == 0 and body['operation'] == 'new' and body['status'] == 'succeeded', body
    assert body['data']['host_inspected'] is False
    assert all((fixture / path).exists() for path in body['data']['files'])
    assert '(source (git git@example.org:greeter.git))' in (fixture / 'apps/greeter/app.sexp').read_text()
    result, body = run('new', 'greeter', '--kind', 'phoenix', '--repo', str(checkout), '--json')
    assert result.returncode == 1 and body['error']['code'] == 'not_applied', body
    env['JJ_BIN'] = str(deny)
    _, body = run('validate', '--json')
    assert body['status'] == 'succeeded' and body['data']['apps'] == 5

    topology.write_text(topology.read_text().replace('(hello worker)', '(hello missing)'))
    result, body = run('inspect', '--json')
    assert result.returncode == 1 and body['error']['code'] == 'invalid_declaration'
    result, body = run('inspect', '--json', cwd=Path('/'))
    assert result.returncode == 1 and body['error']['code'] == 'input_unavailable'
    topology.write_text(topology.read_text().replace('(hello missing)', '(hello worker)').replace('(ssh worker)', '(ssh second-box)'))
    _, changed = run('inspect', '--json')
    hello = next(w for w in changed['data']['workloads'] if w['name'] == 'hello')
    assert hello['ssh_target'] == 'second-box'
    # A shell config that disagrees with its declaration fails validation.
    config = fixture / 'apps/logs/config'
    original = config.read_text()
    config.write_text(original.replace('PORT="9428"', 'PORT="1"'))
    result, body = run('validate', '--json')
    assert result.returncode == 1 and body['error']['code'] == 'invalid_declaration', body
    assert 'apps/logs/config: PORT is 1 but' in body['error']['message'], body
    plain = subprocess.run([str(exe), 'validate'], cwd=fixture, env=env,
                           capture_output=True, text=True, timeout=15)
    assert plain.returncode != 0 and 'PORT is 1 but' in plain.stderr, plain
    config.write_text(original)
    (fixture / 'edge/caddy/Caddyfile').unlink()
    result, body = run('validate', '--json')
    assert result.returncode == 1 and body['error']['code'] == 'render_failed'
    print('ok - versioned read-only agent contracts, topology, previews and refusals; no remote effects')
PY

#!/usr/bin/env bash
# Offline recovery contract: no guest/edge host access or protected secret reads.
# The example configuration's guest and oauth2-proxy stand for any.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$root" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
guest = (root / 'example/guests/ledger/logging').read_text()
edge = (root / 'edge/03-logging').read_text()
auth = (root / 'edge/04-vmui-auth').read_text()
for name, script, package in [
    ('guest', guest, 'apt-get update'),
    ('edge', edge, 'pacman -S --needed'),
    ('auth', auth, 'curl --fail'),
]:
    assert '--recover-check' in script and '--recover' in script, f'{name}: missing explicit recovery modes'
    assert script.index('cmp -s') < script.index(package), f'{name}: drift guard after install'
    assert script.index('systemctl is-enabled --quiet') < script.index(package), f'{name}: state guard after install'
    assert 'systemctl is-active --quiet' in script, f'{name}: no post-start health check'
assert '/run/rsyslog-victoria.pid' in guest and 'cmp -s - "$UNIT_FILE"' in guest, \
    'guest recovery must compare the known old PID path before replacement'
assert 'cmp -s - "$CONFIG_FILE"' in edge and 'persist-name("vps-oauth-safe-event")' in edge, \
    'edge host recovery must compare the old queue identity without deleting queue files'
assert 'cmp -s "$SCRIPT_DIR/oauth2-proxy/oauth2-proxy.cfg"' in auth, \
    'auth recovery must refuse config drift'
assert 'systemctl start oauth2-proxy' in auth, 'auth recovery must restart only the matching unit'
PY
python3 - "$root" <<'PY'
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
root = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as directory:
    tmp = Path(directory)
    bin_dir = tmp / 'bin'
    bin_dir.mkdir()
    stubs = {
        'id': '#!/bin/sh\necho 0\n',
        'timeout': '#!/bin/sh\nexit 0\n',
        'ip': '#!/bin/sh\necho "10.20.0.20 dev tailscale0"\n',
        'sleep': '#!/bin/sh\nexit 0\n',
        'stat': '#!/bin/sh\ncase "$2" in %u) echo 0;; %a) echo 600;; *) exit 1;; esac\n',
        'systemctl': '''#!/bin/sh
case "$1" in
  is-enabled) exit 0;;
  is-active) test -f "$TEST_STATE_DIR/active";;
  start) touch "$TEST_STATE_DIR/active";;
  daemon-reload) exit 0;;
  *) echo "unexpected systemctl call: $*" >&2; exit 98;;
esac
''',
        'install': '#!/bin/bash\ncp "${@: -2:1}" "${@: -1}"\n',
        'pacman': '#!/bin/sh\nexit 98\n',
        'apt-get': '#!/bin/sh\nexit 98\n',
        'curl': '#!/bin/sh\nexit 98\n',
        'syslog-ng': '#!/bin/sh\nexit 0\n',
        'oauth2-proxy': '#!/bin/sh\necho v7.15.3\n',
    }
    for name, body in stubs.items():
        path = bin_dir / name
        path.write_text(body)
        path.chmod(0o755)
    for name, source, shell in [
        ('guest', root / 'example/guests/ledger', 'sh'),
        ('edge', root / 'edge', 'bash'),
        ('auth', root / 'edge', 'bash'),
    ]:
        case = tmp / name
        stage, live, state = case / 'stage', case / 'live', case / 'state'
        stage.mkdir(parents=True)
        live.mkdir()
        state.mkdir()
        if name == 'guest':
            files = ['logging', 'rsyslog-victoria.conf', 'rsyslog-victoria.service']
            script = stage / 'logging'
            config = live / 'rsyslog-victoria.conf'
            unit = live / 'rsyslog-victoria.service'
            for file in files:
                shutil.copyfile(source / file, stage / file)
            text = script.read_text().replace('/etc/rsyslog-victoria.conf', str(config))
            text = text.replace('/etc/systemd/system/rsyslog-victoria.service', str(unit))
            script.write_text(text)
            shutil.copyfile(stage / 'rsyslog-victoria.conf', config)
            old = (stage / 'rsyslog-victoria.service').read_text().replace(
                '-i /run/rsyslog-victoria/rsyslogd.pid', '-i /run/rsyslog-victoria.pid')
            unit.write_text(old)
        else:
            script_name = '03-logging' if name == 'edge' else '04-vmui-auth'
            script = stage / script_name
            shutil.copyfile(source / script_name, script)
            if name == 'edge':
                # What infra renders and stages beside the installer.
                shutil.copyfile(source / 'syslog-ng-victoria.service', stage / 'syslog-ng-victoria.service')
                (stage / 'syslog-ng-victoria.conf').write_text(
                    (source / 'syslog-ng-victoria.conf.template').read_text()
                    .replace('__LOGS_IP__', '10.20.0.20').replace('__LOGS_SYSLOG_PORT__', '29514'))
                (stage / 'logging-receiver').write_text('10.20.0.20 29514\n')
                config = live / 'victoria-logs.conf'
                unit = live / 'syslog-ng-victoria.service'
                old = (stage / 'syslog-ng-victoria.conf').read_text().replace(
                    '        persist-name("vps-oauth-safe-event")\n', '')
                config.write_text(old)
                shutil.copyfile(stage / 'syslog-ng-victoria.service', unit)
                text = script.read_text().replace('CONFIG_DIR=/etc/syslog-ng', f'CONFIG_DIR={live}')
                text = text.replace('/etc/systemd/system/syslog-ng-victoria.service', str(unit))
                text = text.replace('/usr/bin/syslog-ng', str(bin_dir / 'syslog-ng'))
            else:
                shutil.copytree(root / 'example/edge/oauth2-proxy', stage / 'oauth2-proxy')
                config = live / 'oauth2-proxy.cfg'
                unit = live / 'oauth2-proxy.service'
                shutil.copyfile(stage / 'oauth2-proxy/oauth2-proxy.cfg', config)
                shutil.copyfile(stage / 'oauth2-proxy/oauth2-proxy.service', unit)
                (live / 'secrets.env').write_text('OAUTH2_PROXY_CLIENT_ID=fixture\n'
                    'OAUTH2_PROXY_CLIENT_SECRET=fixture\n'
                    'OAUTH2_PROXY_COOKIE_SECRET=' + 'a' * 32 + '\n')
                text = script.read_text().replace('/etc/oauth2-proxy', str(live))
                text = text.replace('/etc/systemd/system/oauth2-proxy.service', str(unit))
                text = text.replace('/usr/local/bin/oauth2-proxy', str(bin_dir / 'oauth2-proxy'))
            script.write_text(text)
        env = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'],
                   TEST_STATE_DIR=str(state))
        def run(*args):
            result = subprocess.run([shell, str(script), *args], env=env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            return result.returncode
        assert run() != 0, f'{name}: ordinary installer accepted stopped enabled unit'
        assert run('--recover-health') != 0, f'{name}: inactive unit passed final health gate'
        before = (config.read_bytes(), unit.read_bytes())
        assert run('--recover-check') == 0, f'{name}: known failed state rejected in preflight'
        assert (config.read_bytes(), unit.read_bytes()) == before, f'{name}: preflight mutated installed files'
        assert not (state / 'active').exists(), f'{name}: preflight started a unit'
        assert run('--recover') == 0, f'{name}: known failed state did not recover'
        assert (state / 'active').exists(), f'{name}: unit did not start'
        assert run('--recover-health') == 0, f'{name}: recovered unit failed final health gate'
        (state / 'active').unlink()
        config.write_text(config.read_text() + '\n# unexpected drift\n')
        drift = config.read_bytes()
        assert run('--recover') != 0, f'{name}: unexpected installed drift was overwritten'
        assert config.read_bytes() == drift and not (state / 'active').exists(), \
            f'{name}: drift changed files or started a unit'
PY
printf 'ok - logging recovery preflight, repair, drift and health gates are simulated offline\n'

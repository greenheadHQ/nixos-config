#!/usr/bin/env python3
"""Manual Darwin GUI-session test; only temporary labels and fixture PIDs change.

Pass the built maint from this checkout so its Bash and native helpers match
production. This cannot run inside the Nix build sandbox.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import tempfile
import time
import uuid


def run(argv, *, check=True):
    return subprocess.run(argv, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=10, check=check)


def wait_for(predicate, message, seconds=12):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError(message)


def process(pid):
    result = run(['/bin/ps', '-ww', '-p', str(pid), '-o', 'pid=,ppid=,pgid=,lstart=,args='], check=False)
    if not result.stdout.strip():
        return None
    fields = result.stdout.strip().split(None, 8)
    return {'pid': int(fields[0]), 'ppid': int(fields[1]), 'pgid': int(fields[2]),
            'started': ' '.join(fields[3:8]), 'argv': fields[8]}


def is_same(before):
    current = process(before['pid'])
    return bool(current and all(current[key] == before[key] for key in ('pid', 'pgid', 'started', 'argv')))


def stop_exact(before):
    if is_same(before):
        os.kill(before['pid'], signal.SIGKILL)


def lock_free(flock, lock_path):
    return run([flock, '-n', str(lock_path), '/usr/bin/true'], check=False).returncode == 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', required=True)
    parser.add_argument('--maint', required=True)
    args = parser.parse_args()
    source = Path(args.source).resolve()
    installed = Path(args.maint).read_text()
    bash = installed.splitlines()[0][2:]
    runtime = re.search(r'^export PATH="([^"\n]+):\$PATH"', installed, re.M).group(1)
    runtime += ':/usr/bin:/bin:/usr/sbin:/sbin'
    flock = next(str(Path(directory) / 'flock') for directory in runtime.split(':') if (Path(directory) / 'flock').is_file())
    root = Path(tempfile.mkdtemp(prefix='claude-rc-launchd-proof-', dir='/tmp')).resolve()
    os.chmod(root, 0o700)
    report = {'root': str(root), 'source': str(source), 'bash': bash,
              'bash_version': run([bash, '--version']).stdout.splitlines()[0], 'cases': []}
    print(str(root), flush=True)

    for abandon in (True, False):
        case = root / ('abandon-true' if abandon else 'abandon-false')
        case.mkdir(mode=0o700)
        project = case / 'project'
        project.mkdir()
        (case / 'home').mkdir()
        for fifo in ('parent.fifo', 'orphan.fifo', 'bridge.fifo'):
            os.mkfifo(case / fifo, 0o600)
        label = 'dev.nixos-config.claude-rc-lock-test-' + uuid.uuid4().hex
        target = f'gui/{os.getuid()}/{label}'
        bridge_script = case / 'fakebridge.sh'
        bridge_script.write_text('''#!''' + bash + '''
set -eu
printf '%s\\n' "$BASHPID" > "$CASE/bridge.pid"
exec 7<> "$CASE/bridge.fifo"
IFS= read -r -u 7 line
''')
        bridge_script.chmod(0o700)
        job = case / 'ensure-fixture.sh'
        job.write_text('''#!''' + bash + '''
set -euo pipefail
source "$RC_SOURCE/modules/nixos/scripts/claude-rc-lib.sh"
failure() { printf 'lock failure\\n' >&2; return 1; }
fixture_callback() {
    local guard_pid launcher_pid group_pid attempt
    spawn_guarded_server_launch "$CASE/project" worktree "" bypassPermissions "$CASE/fakebridge.sh" \\
        guard_pid launcher_pid group_pid || return 1
    printf '%s\\n' "$launcher_pid" > "$CASE/launcher.pid"
    printf '%s\\n' "$group_pid" > "$CASE/group.pid"
    printf '%s\\n' "$guard_pid" > "$CASE/guardian.pid"
    for ((attempt = 0; attempt < 200; attempt++)); do
        [ ! -s "$CASE/bridge.pid" ] || break
        sleep 0.05
    done
    [ -s "$CASE/bridge.pid" ] || return 1
    handoff_launch_guard "$guard_pid" "$group_pid" || return 1
    (
        printf '%s\\n' "$BASHPID" > "$CASE/orphan.pid"
        exec 7<> "$CASE/orphan.fifo"
        IFS= read -r -u 7 line
    ) &
    printf '%s\\n' "$BASHPID" > "$CASE/parent.pid"
    printf 'ready\\n' > "$CASE/ready"
    exec 7<> "$CASE/parent.fifo"
    IFS= read -r -u 7 line
}
with_lifecycle_lock_fd9 2 "$STATE_DIR/ensure.lock" failure failure failure fixture_callback
''')
        job.chmod(0o700)
        plist = case / 'fixture.plist'
        config = {'Label': label, 'ProgramArguments': [bash, str(job)],
                  'RunAtLoad': True, 'AbandonProcessGroup': abandon,
                  'EnvironmentVariables': {'HOME': str(case / 'home'), 'CASE': str(case),
                        'STATE_DIR': str(case / 'state'), 'VERSIONS_DIR': str(case / 'versions'),
                        'RC_SOURCE': str(source), 'PATH': runtime},
                  'StandardOutPath': str(case / 'job.log'), 'StandardErrorPath': str(case / 'job.log')}
        plist.write_bytes(plistlib.dumps(config))
        plist.chmod(0o600)
        result = {'abandon_process_group': abandon, 'label': label}
        tracked = []
        bootstrapped = False
        try:
            run(['/bin/launchctl', 'bootstrap', f'gui/{os.getuid()}', str(plist)])
            bootstrapped = True
            wait_for(lambda: (case / 'ready').exists() and all((case / f'{role}.pid').exists() for role in ('parent', 'orphan', 'bridge', 'launcher')),
                     f'fixture not ready: {case}', seconds=20)
            for role in ('parent', 'orphan', 'bridge', 'launcher'):
                identity = process(int((case / f'{role}.pid').read_text()))
                assert identity and str(case) in identity['argv'], (role, identity)
                result[role + '_before'] = identity
                tracked.append(identity)
            parent, orphan, bridge = [result[role + '_before'] for role in ('parent', 'orphan', 'bridge')]
            assert parent['pgid'] == parent['pid'], parent
            assert orphan['pgid'] == parent['pgid'], (parent, orphan)
            assert bridge['pgid'] != parent['pgid'], (parent, bridge)
            lock_path = case / 'state' / 'ensure.lock'
            fd_evidence = run(['/usr/sbin/lsof', '-a', '-p', str(orphan['pid']), '-F', 'fpn', '--', str(lock_path)], check=False)
            assert fd_evidence.returncode == 0 and str(lock_path) in fd_evidence.stdout, fd_evidence.stdout
            result['orphan_fd_before'] = fd_evidence.stdout
            assert not lock_free(flock, lock_path), 'parent must hold lifecycle lock before death'
            stop_exact(parent)
            wait_for(lambda: process(parent['pid']) is None, 'parent did not terminate')
            if abandon:
                time.sleep(0.5)
                assert is_same(orphan), 'red control orphan unexpectedly cleaned'
                assert not lock_free(flock, lock_path), 'red control lock unexpectedly free'
                result['outcome'] = 'RED: inherited lock remains held after parent death'
            else:
                wait_for(lambda: process(orphan['pid']) is None, 'launchd did not clean same-group orphan')
                wait_for(lambda: lock_free(flock, lock_path), 'lifecycle lock not released')
                result['outcome'] = 'GREEN: orphan reaped and lifecycle lock free'
            assert is_same(bridge), 'detached bridge PID changed or exited'
            result['bridge_after'] = process(bridge['pid'])
            result['bridge_same_pid_survived'] = True
            result['lock_free_after_parent_death'] = lock_free(flock, lock_path)
            result['orphan_after'] = process(orphan['pid'])
        finally:
            if bootstrapped:
                run(['/bin/launchctl', 'bootout', target], check=False)
            for identity in reversed(tracked):
                stop_exact(identity)
            # If setup failed before identity capture, only touch PID files whose
            # current argv contains this fixture's private directory.
            for pid_file in case.glob('*.pid'):
                identity = process(int(pid_file.read_text().strip()))
                if identity and str(case) in identity['argv']:
                    stop_exact(identity)
            wait_for(lambda: all(process(identity['pid']) is None for identity in tracked),
                     'fixture processes remain after cleanup')
            listing = run(['/bin/launchctl', 'print', target], check=False)
            assert listing.returncode != 0, 'fixture launchd label remains loaded'
            result['cleanup_verified'] = True
            report['cases'].append(result)
            (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(result, indent=2), flush=True)
    report['passed'] = all(case['cleanup_verified'] and case['bridge_same_pid_survived'] for case in report['cases'])
    (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print('REPORT=' + str(root / 'report.json'), flush=True)


if __name__ == '__main__':
    main()

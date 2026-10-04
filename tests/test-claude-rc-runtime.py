"""Exercise the shipped shell and actual metadata/lock path under pipe pressure."""

import argparse
import os
from pathlib import Path
import signal
import subprocess
import tempfile


def probe(bash, maint, interposer, flock, action, expected, *, vulnerable=False):
    with tempfile.TemporaryDirectory(prefix="claude-rc-pipe-") as tmp:
        root = Path(tmp)
        evidence = root / "evidence"
        lock = root / "ensure.lock"
        env = os.environ | {
            "HOME": tmp,
            "STATE_DIR": tmp,
            "DYLD_INSERT_LIBRARIES": interposer,
            "CLAUDE_RC_PIPE_EVIDENCE": str(evidence),
        }
        command = [
            bash, "-c",
            'source "$1"; unavailable() { return 1; }; '
            'with_lifecycle_lock_fd9 1 "$2" unavailable unavailable unavailable '
            'instance_action_metadata "$3"',
            "_", maint, str(lock), action,
        ]
        child = subprocess.Popen(
            command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        )
        timed_out = False
        try:
            try:
                stdout, stderr = child.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                timed_out = True
        finally:
            # A timed-out Bash may have shell descendants holding the lock and
            # output pipes. Clean only this fixture's freshly created group.
            if timed_out or child.poll() is None:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            stdout, stderr = child.communicate(timeout=5)
        trace = evidence.read_text() if evidence.exists() else ""
        free = subprocess.run([flock, "-n", str(lock), "/usr/bin/true"], check=False)
        assert free.returncode == 0, "fixture leaked the lifecycle lock"
        if vulnerable:
            assert timed_out and "blocking-stall" in trace, (timed_out, trace, stderr)
            print("PASS: unpatched Bash reproduces the metadata hang (negative control)")
        else:
            assert not timed_out, "metadata lookup hung while holding the lifecycle lock"
            assert child.returncode == 0, stderr.decode()
            assert stdout == expected, (action, stdout, stderr)
            assert "nonblocking-eagain" in trace, "fault injection did not reach the heredoc"
            assert "blocking-stall" not in trace, trace
            print(f"PASS: {action} completes with exact metadata and releases its lock")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bash", required=True)
    parser.add_argument("--maint", required=True)
    parser.add_argument("--wrapper", required=True)
    parser.add_argument("--flock", required=True)
    parser.add_argument("--interposer", required=True)
    parser.add_argument("--vulnerable-bash")
    args = parser.parse_args()
    for script in (args.maint, args.wrapper):
        assert Path(script).read_text().splitlines()[0] == f"#!{args.bash}", script
    print("PASS: both shipped CLI shebangs use the selected runtime")
    if args.vulnerable_bash:
        probe(args.vulnerable_bash, args.maint, args.interposer, args.flock,
              "healthy", b"running\tfalse\n", vulnerable=True)
    for action, expected in (
        ("healthy", b"running\tfalse\n"),
        ("deferred-restart-confirmation", b"running\tfalse\n"),
        ("restart-version-mismatch-cleanup-failed", b"unknown\ttrue\n"),
    ):
        probe(args.bash, args.maint, args.interposer, args.flock, action, expected)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Hermetic behavioral tests for the launcher-scoped SSH dispatcher."""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


REPO = Path(__file__).resolve().parents[1]
CORE = REPO / "modules/darwin/programs/ssh/files/headless-ssh-dispatcher.py"
FAKE = REPO / "tests/fixtures/headless-ssh/fake-ssh.py"
MANIFEST = REPO / "tests/fixtures/headless-ssh/compatible-manifest.json"


def load_dispatcher_module():
    spec = importlib.util.spec_from_file_location("headless_ssh_dispatcher", CORE)
    if spec is None or spec.loader is None:
        raise RuntimeError("dispatcher module could not be loaded")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class DispatcherFixture(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="headless-ssh-test-")
        self.root = Path(self._tmp.name)
        self.state = self.root / "state"
        self.state.mkdir()
        self.fake = self.root / "fake-ssh"
        shutil.copyfile(FAKE, self.fake)
        os.chmod(self.fake, 0o755)
        self.timeout_bin = shutil.which("timeout")
        if self.timeout_bin is None:
            self.fail("GNU timeout is required by the hermetic dispatcher fixture")
        self.key = self.root / "minipc-headless"
        self.key.write_text("fixture-not-a-private-key", encoding="utf-8")
        os.chmod(self.key, 0o400)
        self.runtime = self.root / "runtime"
        self.scenario = self.root / "scenario.json"
        self.write_scenario()

    def tearDown(self) -> None:
        for record_path in self.state.glob("master-*.json"):
            try:
                pid = int(json.loads(record_path.read_text(encoding="utf-8"))["pid"])
                os.kill(pid, signal.SIGTERM)
            except (OSError, ValueError, KeyError, json.JSONDecodeError):
                pass
        self._tmp.cleanup()

    def write_scenario(self, **values: object) -> None:
        scenario = {
            "hostname": "100.64.0.2",
            "user": "greenhead",
            "port": 22,
            "controlpath": "none",
            "auth": "ready",
        }
        scenario.update(values)
        self.scenario.write_text(json.dumps(scenario), encoding="utf-8")

    def env(self) -> dict[str, str]:
        environment = os.environ.copy()
        environment.update(
            FAKE_SSH_STATE=str(self.state),
            FAKE_SSH_SCENARIO=str(self.scenario),
        )
        return environment

    def command(
        self,
        *ssh_argv: str,
        auth_deadline: float = 0.25,
        real_ssh: Path | None = None,
        timeout_bin: str | None = None,
    ) -> list[str]:
        return [
            sys.executable,
            str(CORE),
            "--real-ssh",
            str(real_ssh or self.fake),
            "--timeout-bin",
            timeout_bin or str(self.timeout_bin),
            "--manifest",
            str(MANIFEST),
            "--headless-key",
            str(self.key),
            "--runtime-dir",
            str(self.runtime),
            "--target-host",
            "100.64.0.2",
            "--target-user",
            "greenhead",
            "--target-port",
            "22",
            "--managed-destination",
            "minipc",
            "--managed-destination",
            "minipc-headless",
            "--managed-destination",
            "100.64.0.2",
            "--raw-destination",
            "minipc-emergency",
            "--auth-deadline",
            str(auth_deadline),
            "--control-deadline",
            "0.8",
            "--cleanup-grace",
            "0.15",
            "--",
            *ssh_argv,
        ]

    def run_dispatch(self, *ssh_argv: str, **kwargs: object) -> subprocess.CompletedProcess[str]:
        command_keys = {"auth_deadline", "real_ssh", "timeout_bin"}
        command_kwargs = {key: kwargs.pop(key) for key in list(kwargs) if key in command_keys}
        return subprocess.run(
            self.command(*ssh_argv, **command_kwargs),
            env=self.env(),
            text=True,
            capture_output=True,
            timeout=float(kwargs.pop("timeout", 6)),
            check=False,
            **kwargs,
        )

    def calls(self) -> list[dict[str, object]]:
        log = self.state / "calls.jsonl"
        if not log.exists():
            return []
        return [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]

    def events(self) -> list[str]:
        return [str(call["event"]) for call in self.calls()]

    def clear_calls(self) -> None:
        (self.state / "calls.jsonl").unlink(missing_ok=True)

    def wait_for_event(self, event: str, timeout: float = 3) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if event in self.events():
                return
            time.sleep(0.01)
        self.fail(f"event not observed: {event}")

    def start_external_master(self, control_path: Path) -> None:
        result = subprocess.run(
            [
                str(self.fake),
                "-F",
                "none",
                "-fN",
                "-M",
                "-o",
                f"ControlPath={control_path}",
                "greenhead@100.64.0.2",
            ],
            env=self.env(),
            text=True,
            capture_output=True,
            check=False,
            timeout=3,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(control_path.exists())


class CoreContractTests(DispatcherFixture):
    def test_success_preserves_stdout_stderr_and_exit_zero(self) -> None:
        self.write_scenario(stdout="out", stderr="err")
        result = self.run_dispatch("minipc", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "out")
        self.assertEqual(result.stderr, "err")
        self.assertIn("auth", self.events())
        self.assertIn("data", self.events())

    def test_immediate_auth_255_and_stderr_are_preserved(self) -> None:
        self.write_scenario(auth="exit255", auth_stderr="public fixture failure")
        result = self.run_dispatch("minipc", "true")
        self.assertEqual(result.returncode, 255, result.stderr)
        self.assertIn("public fixture failure", result.stderr)
        self.assertNotIn("HEADLESS_SSH_AUTH_TIMEOUT", result.stderr)

    def test_auth_stall_is_bounded_and_diagnosed(self) -> None:
        self.write_scenario(auth="stall")
        started = time.monotonic()
        result = self.run_dispatch("minipc", "true", auth_deadline=0.25)
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertLess(elapsed, 2.25)
        self.assertIn("HEADLESS_SSH_AUTH_TIMEOUT", result.stderr)
        self.assertIn("never waits for a 1Password GUI", result.stderr)

    def test_auth_stall_that_ignores_term_is_still_124_and_diagnosed(self) -> None:
        self.write_scenario(auth="stall-ignore-term")
        started = time.monotonic()
        result = self.run_dispatch("minipc", "true", auth_deadline=0.25)
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertLess(elapsed, 2.25)
        self.assertIn("HEADLESS_SSH_AUTH_TIMEOUT", result.stderr)

    def test_post_auth_long_command_outlives_auth_deadline(self) -> None:
        self.write_scenario(remote_delay=0.7, stdout="long-ok")
        started = time.monotonic()
        result = self.run_dispatch("minipc", "long", auth_deadline=0.2)
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "long-ok")
        self.assertGreaterEqual(elapsed, 0.65)

    def test_remote_124_is_not_mislabeled_as_auth_timeout(self) -> None:
        self.write_scenario(remote_exit=124, stderr="remote-124")
        result = self.run_dispatch("minipc", "remote")
        self.assertEqual(result.returncode, 124)
        self.assertEqual(result.stderr, "remote-124")

    def test_signal_received_during_spawn_is_forwarded_to_the_new_child(self) -> None:
        dispatcher = load_dispatcher_module()
        delivered: list[int] = []

        class SignalDuringSpawn:
            def __init__(self, _command: list[str]):
                self.returncode: int | None = None
                os.kill(os.getpid(), signal.SIGTERM)

            def poll(self) -> int | None:
                return self.returncode

            def send_signal(self, signum: int) -> None:
                delivered.append(signum)
                self.returncode = -signum

            def wait(self) -> int:
                return self.returncode if self.returncode is not None else 0

        with mock.patch.object(dispatcher.subprocess, "Popen", SignalDuringSpawn):
            result = dispatcher.run_data(["unused"])

        self.assertEqual(delivered, [signal.SIGTERM])
        self.assertEqual(result, -signal.SIGTERM)

    def test_sigkill_exit_is_reproduced_without_changing_its_disposition(self) -> None:
        dispatcher = load_dispatcher_module()
        parsed = mock.Mock(ssh_argv=[])
        contract = mock.Mock()

        with (
            mock.patch.object(dispatcher, "parser") as parser_mock,
            mock.patch.object(dispatcher.Contract, "from_args", return_value=contract),
            mock.patch.object(dispatcher, "dispatch", return_value=-signal.SIGKILL),
            mock.patch.object(dispatcher.signal, "signal") as disposition,
            mock.patch.object(dispatcher.os, "kill") as self_kill,
        ):
            parser_mock.return_value.parse_args.return_value = parsed
            result = dispatcher.main()

        disposition.assert_not_called()
        self_kill.assert_called_once_with(os.getpid(), signal.SIGKILL)
        self.assertEqual(result, -signal.SIGKILL)


class ScopeTests(DispatcherFixture):
    def test_emergency_and_other_host_are_raw_exact_once(self) -> None:
        for destination in ("minipc-emergency", "github.com"):
            with self.subTest(destination=destination):
                self.clear_calls()
                result = self.run_dispatch(destination, "true")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.events(), ["data"])

    def test_meta_modes_are_raw_and_do_not_authenticate(self) -> None:
        for argv in (("-V",), ("-Q", "cipher"), ("-G", "minipc"), ("-O", "check", "minipc")):
            with self.subTest(argv=argv):
                self.clear_calls()
                self.run_dispatch(*argv)
                self.assertNotIn("auth", self.events())

    def test_user_target_custom_config_W_and_tty_are_preserved(self) -> None:
        custom = self.root / "custom.conf"
        custom.write_text("Host minipc\n  HostName 100.64.0.2\n", encoding="utf-8")
        invocations = (
            ("greenhead@minipc", "true"),
            ("-F", str(custom), "minipc", "true"),
            ("-W", "127.0.0.1:22", "minipc"),
            ("-tt", "minipc", "true"),
        )
        for argv in invocations:
            with self.subTest(argv=argv):
                self.clear_calls()
                result = self.run_dispatch(*argv)
                self.assertEqual(result.returncode, 0, result.stderr)
                data = next(call for call in self.calls() if call["event"] == "data")
                for token in argv:
                    self.assertIn(token, data["argv"])

    def test_custom_config_and_host_verification_options_reach_auth_master(self) -> None:
        custom = self.root / "custom.conf"
        custom.write_text("Host minipc\n  HostName 100.64.0.2\n", encoding="utf-8")
        known_hosts = self.root / "known-hosts"
        operator_key = self.root / "operator-key"
        self.write_scenario(
            userknownhostsfile=str(known_hosts),
            stricthostkeychecking="yes",
            identityfile=["~/.ssh/id_ed25519", str(operator_key)],
        )
        result = self.run_dispatch(
            "-F",
            str(custom),
            "-o",
            f"UserKnownHostsFile={known_hosts}",
            "-o",
            "StrictHostKeyChecking=yes",
            "minipc",
            "true",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        auth = next(call for call in self.calls() if call["event"] == "auth")
        self.assertNotIn(str(custom), auth["argv"])
        self.assertNotIn(str(operator_key), auth["argv"])
        self.assertIn(str(self.key), auth["argv"])
        self.assertIn(f"userknownhostsfile={known_hosts}", auth["argv"])
        self.assertIn("stricthostkeychecking=yes", auth["argv"])

    def test_auth_master_does_not_enable_confirmation_mode(self) -> None:
        result = self.run_dispatch("minipc", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        auth = next(call for call in self.calls() if call["event"] == "auth")
        self.assertEqual(auth["argv"].count("-M"), 1)
        self.assertNotIn("ControlMaster=yes", auth["argv"])

    def test_custom_config_alias_to_minipc_is_managed_and_bounded(self) -> None:
        custom = self.root / "custom-alias.conf"
        custom.write_text(
            "Host lab-box\n  HostName 100.64.0.2\n  User greenhead\n",
            encoding="utf-8",
        )
        result = self.run_dispatch("-F", str(custom), "lab-box", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events()[:2], ["config", "auth"])
        data = next(call for call in self.calls() if call["event"] == "data")
        self.assertIn("lab-box", data["argv"])

    def test_explicit_hostname_retarget_to_minipc_is_managed(self) -> None:
        result = self.run_dispatch(
            "-o", "HostName=100.64.0.2", "lab-box", "true"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("auth", self.events())

    def test_effective_retarget_to_other_host_returns_to_raw_path(self) -> None:
        self.write_scenario(hostname="example.test", user="alice")
        result = self.run_dispatch("minipc", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), ["config", "data"])

    def test_managed_identity_override_fails_before_authentication(self) -> None:
        result = self.run_dispatch("-i", "/tmp/other-key", "minipc", "true")
        self.assertEqual(result.returncode, 125, result.stderr)
        self.assertIn("HEADLESS_SSH_MANAGED_OPTION_UNSUPPORTED", result.stderr)
        self.assertNotIn("auth", self.events())

    def test_managed_control_ownership_override_fails_before_authentication(self) -> None:
        for option in (
            "ControlMaster=yes",
            f"ControlPath={self.root / 'operator-master'}",
            "ControlPersist=30",
        ):
            with self.subTest(option=option):
                self.clear_calls()
                result = self.run_dispatch("-o", option, "minipc", "true")
                self.assertEqual(result.returncode, 125, result.stderr)
                self.assertIn("HEADLESS_SSH_MANAGED_OPTION_UNSUPPORTED", result.stderr)
                self.assertNotIn("auth", self.events())


class LifecycleTests(DispatcherFixture):
    def test_active_control_master_reuses_transport_without_new_auth(self) -> None:
        control_path = self.root / "external-master"
        self.start_external_master(control_path)
        self.clear_calls()
        self.write_scenario(controlpath=str(control_path), stdout="reuse")
        result = self.run_dispatch("minipc", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "reuse")
        self.assertNotIn("auth", self.events())
        self.assertIn("control-check", self.events())

    def test_stale_control_master_uses_bounded_dedicated_auth(self) -> None:
        self.write_scenario(controlpath=str(self.root / "stale"), stdout="fresh")
        result = self.run_dispatch("minipc", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "fresh")
        self.assertIn("auth", self.events())

    def test_background_data_does_not_cancel_its_live_session_master(self) -> None:
        self.write_scenario(forkafterauthentication="yes", master_lifetime=0.4)
        result = self.run_dispatch("-f", "minipc", "background")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("control-exit", self.events())
        self.assertEqual(list(self.runtime.glob("call-*")), [])
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and list(self.state.glob("master-*.json")):
            time.sleep(0.02)
        self.assertEqual(list(self.state.glob("master-*.json")), [])

    def test_concurrent_calls_use_unique_ephemeral_masters(self) -> None:
        self.write_scenario(remote_delay=0.15, stdout="ok")
        processes = [
            subprocess.Popen(
                self.command("minipc", f"call-{index}"),
                env=self.env(),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            for index in range(2)
        ]
        results = [process.communicate(timeout=6) for process in processes]
        self.assertEqual([process.returncode for process in processes], [0, 0], results)
        data_paths = {
            str(call["argv"][call["argv"].index("-S") + 1])
            for call in self.calls()
            if call["event"] == "data" and "-S" in call["argv"]
        }
        self.assertEqual(len(data_paths), 2)
        self.assertEqual(list(self.runtime.glob("call-*")), [])

    def test_term_is_forwarded_and_reproduced_after_cleanup(self) -> None:
        self.write_scenario(remote_delay=10)
        process = subprocess.Popen(
            self.command("minipc", "long"),
            env=self.env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.wait_for_event("data")
        process.send_signal(signal.SIGTERM)
        process.communicate(timeout=5)
        self.assertEqual(process.returncode, -signal.SIGTERM)
        self.assertEqual(list(self.runtime.glob("call-*")), [])


class DependencyTests(DispatcherFixture):
    def test_missing_real_ssh_or_timeout_fails_closed_before_network(self) -> None:
        missing = self.root / "missing"
        for kwargs in ({"real_ssh": missing}, {"timeout_bin": str(missing)}):
            with self.subTest(kwargs=kwargs):
                self.clear_calls()
                result = self.run_dispatch("minipc", "true", **kwargs)
                self.assertEqual(result.returncode, 125, result.stderr)
                self.assertEqual(self.events(), [])

    def test_wrong_key_mode_fails_before_authentication(self) -> None:
        os.chmod(self.key, 0o600)
        result = self.run_dispatch("minipc", "true")
        self.assertEqual(result.returncode, 125, result.stderr)
        self.assertIn("HEADLESS_SSH_KEY_INVALID", result.stderr)
        self.assertNotIn("auth", self.events())


if __name__ == "__main__":
    unittest.main(verbosity=2)

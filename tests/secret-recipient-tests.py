#!/usr/bin/env python3
"""처음부터 만든 합성 키·암호문만 사용하며 키·표식은 실패 출력에도 넣지 않는다."""

import base64
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/secrets/check-recipients.py"
spec = importlib.util.spec_from_file_location("recipient_check", SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class RecipientTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory(prefix="recipient-fixture-")
        cls.root = Path(cls.fixture.name)
        cls.keys = []
        for index in range(2):
            private = cls.root / f"synthetic-{index}"
            result = subprocess.run(
                ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "fixture", "-f", str(private)],
                capture_output=True, check=False,
            )
            if result.returncode:
                raise AssertionError("합성 키 생성 실패")
            cls.keys.append(private.with_suffix(".pub").read_text().strip())
        cls.single = cls.encrypt(cls.keys[:1])
        cls.both = cls.encrypt(cls.keys)

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    @classmethod
    def encrypt(cls, keys):
        recipients = cls.root / "recipients.pub"
        recipients.write_text("\n".join(keys) + "\n")
        result = subprocess.run(
            ["age", "-R", str(recipients)], input=b"synthetic fixture only\n",
            capture_output=True, check=False,
        )
        if result.returncode:
            raise AssertionError("합성 암호문 생성 실패")
        return result.stdout

    def test_real_age_header_matches_ssh_wire(self):
        actual = checker.header_tags(io.BytesIO(self.single))
        self.assertTrue(actual == {checker.recipient_tag(self.keys[0])})

    def test_added_and_missing_recipient_are_not_equal(self):
        one = {checker.recipient_tag(self.keys[0])}
        two = {checker.recipient_tag(key) for key in self.keys}
        self.assertTrue(checker.header_tags(io.BytesIO(self.both)) != one)
        self.assertTrue(checker.header_tags(io.BytesIO(self.single)) != two)
        self.assertTrue(checker.header_tags(io.BytesIO(self.both)) == two)

    def test_unknown_recipient_is_not_ignored(self):
        malformed = self.both.replace(b"-> ssh-ed25519 ", b"-> unknown ", 1)
        with self.assertRaises(checker.CheckError):
            checker.header_tags(io.BytesIO(malformed))

    def test_header_and_minimum_payload_must_be_complete(self):
        header_end = self.single.index(b"\n", self.single.index(b"--- ")) + 1
        for end in (0, 10, 21, header_end - 1, header_end, header_end + 31):
            with self.subTest(end=end), self.assertRaises(checker.CheckError):
                checker.header_tags(io.BytesIO(self.single[:end]))

    def test_malformed_header_fields_are_rejected(self):
        lines = self.single.split(b"\n", 4)
        recipient = lines[1].split(b" ")
        variations = [
            b"age-encryption.org/v2\n" + b"\n".join(lines[1:]),
            self.single.replace(b"\n", b"\r\n", 1),
            self.single.replace(recipient[2], recipient[2] + b"=", 1),
            self.single.replace(recipient[3], base64.b64encode(b"a" * 31).rstrip(b"="), 1),
            self.single.replace(lines[2], base64.b64encode(b"a" * 31).rstrip(b"="), 1),
            self.single.replace(lines[3][4:], b"!" * 43, 1),
            b"age-encryption.org/v1\n" + lines[3] + b"\n" + b"p" * 32,
            b"age-encryption.org/v1\n" + b"x" * 257 + b"\n",
        ]
        for index, value in enumerate(variations):
            with self.subTest(case=index), self.assertRaises(checker.CheckError):
                checker.header_tags(io.BytesIO(value))

    def test_excessive_header_is_rejected(self):
        lines = self.single.split(b"\n", 3)
        value = lines[0] + b"\n" + (lines[1] + b"\n" + lines[2] + b"\n") * 1024
        with self.assertRaises(checker.CheckError):
            checker.header_tags(io.BytesIO(value))

    def test_malformed_public_keys_fail_closed(self):
        for value in (None, 3, "", "ssh-rsa AAAA", "ssh-ed25519 !", "ssh-ed25519 AAAA",
                      self.keys[0] + "\n" + self.keys[1]):
            with self.assertRaises(checker.CheckError):
                checker.recipient_tag(value)

    def test_header_parser_does_not_claim_authentication(self):
        # MAC를 검증하지 않는 헤더 비교라는 경계를 고정한다.
        start = self.single.index(b"--- ") + 4
        end = self.single.index(b"\n", start)
        value = self.single[:start] + base64.b64encode(b"a" * 32).rstrip(b"=") + self.single[end:]
        self.assertTrue(checker.header_tags(io.BytesIO(value)) == {checker.recipient_tag(self.keys[0])})

    def run_check(self, mapping, files=None, declaration_error=None):
        with tempfile.TemporaryDirectory(prefix="recipient-check-") as directory:
            root = Path(directory)
            (root / "secrets").mkdir()
            for name in checker.TARGETS:
                (root / "secrets" / name).write_bytes((files or {}).get(name, self.single))
            if declaration_error:
                result = patch.object(checker, "declared_tags", side_effect=declaration_error)
            else:
                result = patch.object(checker, "declared_tags", return_value=mapping)
            output = io.StringIO()
            with result, contextlib.redirect_stdout(output):
                code = checker.check(root)
            return code, output.getvalue()

    def test_exit_codes_and_safe_output(self):
        expected = {name: {checker.recipient_tag(self.keys[0])} for name in checker.TARGETS}
        cases = [
            ({}, None, 0, "일치"),
            ({checker.TARGETS[0]: self.both}, None, 1, "불일치"),
            ({checker.TARGETS[0]: b"broken"}, None, 2, "검사 실패"),
            ({}, checker.CheckError(), 2, "검사 실패"),
        ]
        for files, error, code, verdict in cases:
            with self.subTest(code=code, verdict=verdict):
                actual, output = self.run_check(expected, files, error)
                self.assertEqual(actual, code)
                self.assertIn(f"secrets/{checker.TARGETS[0]}: {verdict}\n", output)
                self.assertEqual(len(output.splitlines()), 6)
                for key in self.keys:
                    self.assertFalse(key in output, "공개키가 출력에 포함됨")
                    self.assertFalse(checker.recipient_tag(key).decode() in output, "표식이 출력에 포함됨")
                self.assertNotIn(str(self.root), output)

    def test_nix_failure_and_bad_declarations_do_not_print_diagnostics(self):
        valid = {name: [self.keys[0]] for name in checker.TARGETS}
        broken = [None, {}, {**valid, checker.TARGETS[0]: []},
                  {**valid, checker.TARGETS[0]: "not a list"},
                  {**valid, checker.TARGETS[0]: ["malformed"]}]
        for value in broken:
            response = subprocess.CompletedProcess([], 0, json.dumps(value), "")
            with patch.object(checker.subprocess, "run", return_value=response):
                with self.assertRaises(checker.CheckError):
                    checker.declared_tags(self.root)
        for error in (FileNotFoundError("synthetic tool path"),
                      subprocess.CalledProcessError(1, "nix", stderr=self.keys[0]),
                      subprocess.TimeoutExpired("nix", 60, output=self.keys[0])):
            with patch.object(checker.subprocess, "run", side_effect=error):
                with self.assertRaises(checker.CheckError) as result:
                    checker.declared_tags(self.root)
                self.assertEqual(str(result.exception), "")

    def test_declaration_evaluation_is_limited_to_target_names(self):
        response = subprocess.CompletedProcess([], 0, json.dumps({name: [self.keys[0]] for name in checker.TARGETS}), "")
        with patch.object(checker.subprocess, "run", return_value=response) as run:
            expected = checker.declared_tags(self.root)
        self.assertTrue(set(expected) == set(checker.TARGETS))
        args, kwargs = run.call_args
        self.assertEqual(args[0][:5], ["nix", "eval", "--json", "--impure", "--expr"])
        self.assertTrue(kwargs["capture_output"])
        self.assertEqual(kwargs["cwd"], self.root)
        for name in checker.TARGETS:
            self.assertIn(json.dumps(name), args[0][5])

    def test_symlink_directory_and_missing_file_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="recipient-path-") as directory:
            root = Path(directory)
            (root / "ciphertext").write_bytes(self.single)
            (root / "link").symlink_to(root / "ciphertext")
            for path in (root / "link", root, root / "absent"):
                with self.assertRaises(checker.CheckError):
                    checker.file_tags(path)
            self.assertTrue(checker.file_tags(root / "ciphertext") == {checker.recipient_tag(self.keys[0])})


if __name__ == "__main__":
    unittest.main(verbosity=2)

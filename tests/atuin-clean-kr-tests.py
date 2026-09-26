#!/usr/bin/env python3
"""실제 atuin-clean-kr 실행 경계에서 삭제 전 SQLite 백업 계약을 검사한다 (합성 DB만 사용)."""
from datetime import datetime
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "modules/shared/scripts/atuin-clean-kr.py"

BASE_ROW = ("base-1", "git status --short")
KOREAN_ROW = ("kr-1", "git commit -m '합성 한글 메시지'")
EXISTING_BACKUP_WINDOW_SECONDS = 30
# 잠금 테스트는 백업 상한을 줄여 실행한다. 원본 연결의 busy handler(5초)가 진행 콜백을 막으면
# 상한 확인이 그만큼 늦어지므로, 상한 뒤 5초보다 짧은 시간 안에 멈춰야 한다.
LOCKED_SOURCE_BACKUP_TIMEOUT_SECONDS = 0.5
LOCKED_SOURCE_MAX_STOP_SECONDS = 4
# 이 시간 안에 끝나지 않으면 멈춘 것으로 본다.
LOCKED_SOURCE_TEST_TIMEOUT_SECONDS = 15

# 실제 스크립트를 그대로 실행하되 sqlite3.connect 경계에서만 백업 실패를 주입한다.
#   target-write-failure: 원본이 아닌 경로(백업 대상)를 읽기 전용으로 열어 대상 쓰기를 막는다.
#   backup-api-error: 원본 연결의 backup()이 첫 페이지를 복사한 뒤 오류를 내게 한다.
FAULT_RUNNER = r"""
import os
import runpy
import sqlite3
import sys

mode, script = sys.argv[1], sys.argv[2]
source = os.path.realpath(os.environ["ATUIN_DB_PATH"])
real_connect = sqlite3.connect


class FailingBackupConnection(sqlite3.Connection):
    def backup(self, target, **kwargs):
        def fail(status, remaining, total):
            raise sqlite3.OperationalError("injected backup API failure")

        return super().backup(target, pages=1, progress=fail)


def connect(database, *args, **kwargs):
    is_source = os.path.realpath(database) == source
    if mode == "target-write-failure" and not is_source:
        return real_connect(f"file:{database}?mode=ro", *args, uri=True, **kwargs)
    if mode == "backup-api-error" and is_source:
        kwargs["factory"] = FailingBackupConnection
    return real_connect(database, *args, **kwargs)


sqlite3.connect = connect
sys.argv = [script, *sys.argv[3:]]
runpy.run_path(script, run_name="__main__")
"""


def read_rows(db_path):
    conn = sqlite3.connect(db_path)
    try:
        return conn.execute("SELECT id, command FROM history ORDER BY id").fetchall()
    finally:
        conn.close()


class BackupContractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.data_dir = self.root / "atuin"
        self.data_dir.mkdir()
        self.db = self.data_dir / "history.db"
        # ATUIN_DB_PATH 처리가 회귀해도 실제 사용자 DB에 닿지 않도록 HOME도 격리한다.
        self.home = self.root / "home"
        self.home.mkdir()

    def make_db(self, journal_mode):
        """기준 행과 삭제 대상 한글 행을 커밋하고, writer 연결을 열린 채 돌려준다.

        WAL이면 기준 행만 본체로 checkpoint하고 한글 행은 WAL에만 남긴다. writer가 열려 있어야
        마지막 연결 종료 시의 자동 checkpoint가 일어나지 않는다.
        """
        writer = sqlite3.connect(self.db, isolation_level=None)
        self.addCleanup(writer.close)
        self.assertEqual(
            writer.execute(f"PRAGMA journal_mode={journal_mode}").fetchone()[0], journal_mode
        )
        writer.execute("PRAGMA wal_autocheckpoint=0")
        writer.execute("CREATE TABLE history(id TEXT PRIMARY KEY, command TEXT)")
        writer.execute("INSERT INTO history VALUES (?, ?)", BASE_ROW)
        if journal_mode == "wal":
            busy, _, _ = writer.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
            self.assertEqual(busy, 0)
        writer.execute("INSERT INTO history VALUES (?, ?)", KOREAN_ROW)
        return writer

    def assert_korean_row_only_in_wal(self):
        # fixture 전제: 본체 파일만 떼어 읽으면 한글 행이 없어야 WAL 전용 행을 검증하는 것이다.
        probe_dir = self.root / "probe"
        probe_dir.mkdir()
        shutil.copyfile(self.db, probe_dir / "history.db")
        self.assertEqual(read_rows(probe_dir / "history.db"), [BASE_ROW])

    def script_env(self):
        return {**os.environ, "ATUIN_DB_PATH": str(self.db), "HOME": str(self.home)}

    def run_script(self, *args, answer="y\n", fault=None):
        env = self.script_env()
        command = [sys.executable, str(SCRIPT), *args]
        if fault is not None:
            command = [sys.executable, "-c", FAULT_RUNNER, fault, str(SCRIPT), *args]
        return subprocess.run(
            command,
            input=answer,
            text=True,
            capture_output=True,
            env=env,
            timeout=60,
        )

    def new_files(self, before):
        sidecars = {f"{self.db.name}{suffix}" for suffix in ("-wal", "-shm", "-journal")}
        return sorted(set(os.listdir(self.data_dir)) - set(before) - sidecars)

    def assert_backed_up_then_deleted(self, result, before):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("삭제 완료: 1개", result.stdout)
        self.assertEqual(read_rows(self.db), [BASE_ROW])

        created = self.new_files(before)
        self.assertEqual(len(created), 1, created)
        backup = self.data_dir / created[0]
        self.assertTrue(backup.name.startswith(f"{self.db.name}.bak."), backup.name)
        self.assertIn(f"백업 완료: {backup}", result.stdout)

        # 백업은 동반 파일 없이 단독으로 복원 가능한 사본이어야 하므로 별도 경로로 옮겨 연다.
        restore_dir = self.root / "restore"
        restore_dir.mkdir()
        restored = restore_dir / "history.db"
        shutil.copyfile(backup, restored)
        self.assertEqual(read_rows(restored), [BASE_ROW, KOREAN_ROW])
        conn = sqlite3.connect(restored)
        try:
            self.assertEqual(conn.execute("PRAGMA integrity_check").fetchall(), [("ok",)])
        finally:
            conn.close()

    def assert_aborted_before_delete(self, result, before):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("백업 실패", result.stderr)
        self.assertNotIn("백업 완료", result.stdout)
        self.assertNotIn("삭제 완료", result.stdout)
        self.assertEqual(read_rows(self.db), [BASE_ROW, KOREAN_ROW])
        # 실패 중 생긴 불완전 사본이 복원점처럼 남으면 안 된다.
        self.assertEqual(self.new_files(before), [])

    def run_without_delete(self, *args, answer):
        """기존 백업이 있는 WAL fixture에서 실행하고, 원본·기존 백업이 그대로인지 확인한다."""
        self.make_db("wal")
        existing = self.data_dir / f"{self.db.name}.bak.20000101-000000"
        existing.write_bytes(b"existing backup")
        before = os.listdir(self.data_dir)

        result = self.run_script(*args, answer=answer)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("백업 완료", result.stdout)
        self.assertNotIn("삭제 완료", result.stdout)
        self.assertEqual(read_rows(self.db), [BASE_ROW, KOREAN_ROW])
        self.assertEqual(existing.read_bytes(), b"existing backup")
        self.assertEqual(self.new_files(before), [])
        return result

    def test_wal_only_committed_row_is_in_backup(self):
        self.make_db("wal")
        self.assert_korean_row_only_in_wal()
        before = os.listdir(self.data_dir)

        result = self.run_script()

        self.assert_backed_up_then_deleted(result, before)

    def test_rollback_journal_backup_keeps_all_rows(self):
        self.make_db("delete")
        before = os.listdir(self.data_dir)

        result = self.run_script()

        self.assert_backed_up_then_deleted(result, before)

    def test_same_second_rerun_keeps_existing_backups(self):
        self.make_db("wal")
        start = time.time()
        # 실행이 어느 초에 백업 이름을 정하든 같은 이름의 기존 백업이 이미 있게 한다.
        existing = {}
        for offset in range(-1, EXISTING_BACKUP_WINDOW_SECONDS):
            stamp = datetime.fromtimestamp(start + offset).strftime("%Y%m%d-%H%M%S")
            path = self.data_dir / f"{self.db.name}.bak.{stamp}"
            path.write_bytes(f"existing backup {stamp}".encode())
            existing[path] = path.read_bytes()
        before = os.listdir(self.data_dir)

        result = self.run_script()

        # 실행이 이 구간을 넘기면 이름 충돌 경로를 검증하지 못한 것이므로 실패로 본다.
        self.assertLess(time.time() - start, EXISTING_BACKUP_WINDOW_SECONDS - 1)
        for path, data in existing.items():
            self.assertTrue(path.exists(), path.name)
            self.assertEqual(path.read_bytes(), data, path.name)
        self.assert_backed_up_then_deleted(result, before)

    def test_backup_target_write_failure_aborts_before_delete(self):
        self.make_db("wal")
        before = os.listdir(self.data_dir)

        result = self.run_script(fault="target-write-failure")

        self.assert_aborted_before_delete(result, before)

    def test_backup_api_error_aborts_before_delete(self):
        self.make_db("wal")
        before = os.listdir(self.data_dir)

        result = self.run_script(fault="backup-api-error")

        self.assert_aborted_before_delete(result, before)

    def test_locked_rollback_journal_source_aborts_before_delete(self):
        self.make_db("delete")
        before = os.listdir(self.data_dir)
        locker = sqlite3.connect(self.db, isolation_level=None)
        self.addCleanup(locker.close)
        env = {
            **self.script_env(),
            "ATUIN_CLEAN_KR_BACKUP_TIMEOUT": str(LOCKED_SOURCE_BACKUP_TIMEOUT_SECONDS),
        }
        proc = subprocess.Popen(
            [sys.executable, str(SCRIPT)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            bufsize=0,
        )
        self.addCleanup(proc.__exit__, None, None, None)
        self.addCleanup(proc.kill)

        # 삭제 대상을 조회하고 확인 프롬프트에서 기다리는 동안 다른 연결이 쓰기 잠금을 잡는다.
        prompt = b""
        while not prompt.endswith(b"[y/N] "):
            chunk = proc.stdout.read(1)
            if not chunk:
                self.fail(f"확인 프롬프트 전에 종료했다: {prompt.decode(errors='replace')}")
            prompt += chunk
        locker.execute("BEGIN EXCLUSIVE")
        started = time.monotonic()
        try:
            stdout, stderr = proc.communicate(b"y\n", timeout=LOCKED_SOURCE_TEST_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            self.fail("원본 잠금이 풀리지 않는 동안 백업이 상한 안에 끝나지 않았다")
        finally:
            locker.execute("ROLLBACK")
        self.assertLess(time.monotonic() - started, LOCKED_SOURCE_MAX_STOP_SECONDS)

        result = subprocess.CompletedProcess(
            proc.args, proc.returncode, (prompt + stdout).decode(), stderr.decode()
        )
        self.assert_aborted_before_delete(result, before)

    def test_cancel_leaves_db_and_existing_backup_unchanged(self):
        result = self.run_without_delete(answer="n\n")

        self.assertIn("취소되었습니다.", result.stdout)

    def test_dry_run_leaves_db_and_existing_backup_unchanged(self):
        result = self.run_without_delete("--dry-run", answer="y\n")

        self.assertIn("삭제 대상: 1개", result.stdout)
        self.assertIn(KOREAN_ROW[1], result.stdout)


if __name__ == "__main__":
    unittest.main()

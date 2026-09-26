#!/usr/bin/env python3
# TODO: atuin에 history delete 서브커맨드가 추가되면 CLI 래퍼로 전환
"""
atuin-clean-kr: Atuin 히스토리에서 한글 포함 항목을 일괄 삭제

zsh-autosuggestions (0.7.1)가 한글 포함 명령어를 제안할 때
TUI 렌더링이 깨지는 문제의 워크어라운드.
"""

import argparse
import itertools
import os
import re
import sqlite3
import sys
import time
from datetime import datetime

# 한글 유니코드 범위
# AC00-D7AF: 한글 음절 (가~힣)
# 1100-11FF: 한글 자모 (초성·중성·종성)
# 3130-318F: 한글 호환 자모 (ㄱ~ㅎ, ㅏ~ㅣ)
KOREAN_PATTERN = re.compile(r"[\uAC00-\uD7AF\u1100-\u11FF\u3130-\u318F]")

DEFAULT_DB_PATH = os.path.expanduser("~/.local/share/atuin/history.db")
PREVIEW_LIMIT = 20
BUSY_TIMEOUT_MS = 5000
# 명령 한 줄을 기록하는 atuin 쓰기는 순간이므로, 이만큼 백업이 끝나지 않으면 다른 프로세스가
# 잠금을 오래 쥐고 있다고 보고 삭제 전에 멈춘다. 테스트는 ATUIN_CLEAN_KR_BACKUP_TIMEOUT으로 줄인다.
DEFAULT_BACKUP_TIMEOUT_SECONDS = 30
# 한 step(기본 4KiB 페이지면 4MiB)마다 원본 잠금을 놓아 atuin 기록을 오래 막지 않고,
# 진행 콜백이 상한과 Ctrl-C를 확인할 틈을 둔다.
BACKUP_STEP_PAGES = 1024


def get_db_path():
    return os.environ.get("ATUIN_DB_PATH", DEFAULT_DB_PATH)


def get_backup_timeout():
    return float(os.environ.get("ATUIN_CLEAN_KR_BACKUP_TIMEOUT", DEFAULT_BACKUP_TIMEOUT_SECONDS))


def find_korean_entries(cursor):
    cursor.execute("SELECT id, command FROM history")
    return [(row[0], row[1]) for row in cursor.fetchall() if row[1] and KOREAN_PATTERN.search(row[1])]


def reserve_backup_path(db_path):
    # 같은 초에 다시 실행해도 기존 백업을 덮어쓰지 않도록 O_EXCL로 새 이름을 선점한다.
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    base = f"{db_path}.bak.{timestamp}"
    for n in itertools.count():
        candidate = base if n == 0 else f"{base}-{n}"
        try:
            fd = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            continue
        os.close(fd)
        return candidate


def backup_db(conn, db_path):
    # 본체 파일 복사는 WAL에만 커밋된 행을 놓치므로, 열린 연결의 온라인 백업 API로
    # SQLite가 확정한 상태 전체를 동반 파일 없이 열 수 있는 단독 사본에 담는다.
    timeout = get_backup_timeout()
    deadline = time.monotonic() + timeout

    def stop_after_deadline(status, remaining, total):
        if status != sqlite3.SQLITE_DONE and time.monotonic() > deadline:
            raise sqlite3.OperationalError(
                f"{timeout:g}초 안에 끝나지 않았습니다 (다른 프로세스가 DB를 잠그고 있을 수 있습니다)"
            )

    backup_path = None
    completed = False
    try:
        backup_path = reserve_backup_path(db_path)
        target = sqlite3.connect(backup_path)
        # busy handler가 잠금을 기다리는 동안에는 진행 콜백이 불리지 않으므로 백업 중에는 끄고,
        # 잠금 대기를 콜백을 거치는 CPython backup 루프의 짧은 재시도에 맡긴다.
        conn.execute("PRAGMA busy_timeout = 0")
        try:
            conn.backup(target, pages=BACKUP_STEP_PAGES, progress=stop_after_deadline)
        finally:
            conn.execute(f"PRAGMA busy_timeout = {BUSY_TIMEOUT_MS}")
            target.close()
        completed = True
    except (OSError, sqlite3.Error) as e:
        print(f"백업 실패: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        # 실패·중단 시 남은 불완전 사본이 정상 복원점처럼 보이지 않게 지운다.
        if not completed and backup_path is not None:
            for suffix in ("", "-journal", "-wal", "-shm"):
                try:
                    os.unlink(backup_path + suffix)
                except FileNotFoundError:
                    pass
    return backup_path


def main():
    parser = argparse.ArgumentParser(
        prog="atuin-clean-kr",
        description="Atuin 히스토리에서 한글 포함 항목을 일괄 삭제합니다.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="삭제하지 않고 대상 항목만 미리보기",
    )
    args = parser.parse_args()

    db_path = get_db_path()

    if not os.path.exists(db_path):
        print(f"DB 파일을 찾을 수 없습니다: {db_path}", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(db_path)
    conn.execute(f"PRAGMA busy_timeout = {BUSY_TIMEOUT_MS}")
    cursor = conn.cursor()

    entries = find_korean_entries(cursor)

    if not entries:
        print("한글 포함 항목이 없습니다.")
        conn.close()
        return

    total = len(entries)

    if args.dry_run:
        print(f"삭제 대상: {total}개")
        print()
        for _, command in entries[:PREVIEW_LIMIT]:
            print(f"  {command}")
        if total > PREVIEW_LIMIT:
            print(f"  ... 외 {total - PREVIEW_LIMIT}개")
        conn.close()
        return

    # 기본 모드: 확인 프롬프트
    print(f"삭제 대상: {total}개")
    try:
        answer = input("삭제하시겠습니까? [y/N] ")
    except (EOFError, KeyboardInterrupt):
        print("\n취소되었습니다.")
        conn.close()
        return

    if answer.strip().lower() != "y":
        print("취소되었습니다.")
        conn.close()
        return

    # 백업
    backup_path = backup_db(conn, db_path)
    print(f"백업 완료: {backup_path}")

    # 삭제
    ids = [entry[0] for entry in entries]
    for entry_id in ids:
        cursor.execute("DELETE FROM history WHERE id = ?", (entry_id,))
    conn.commit()
    conn.close()

    print(f"삭제 완료: {total}개")
    print()
    print("⚠️  로컬 DB에서만 삭제됩니다. 새 기기 연동 시 서버에서 복원될 수 있습니다.")


if __name__ == "__main__":
    main()

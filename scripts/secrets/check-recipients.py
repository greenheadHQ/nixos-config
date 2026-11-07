#!/usr/bin/env python3
"""B04 대상의 공개 헤더 표식을 선언과 비교한다. 복호화·무결성 검사는 하지 않는다."""

import argparse
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess


TARGETS = (
    "cloudflare-dns-api-token.age",
    "copyparty-password.age",
    "immich-db-password.age",
    "pushover-copyparty.age",
    "pushover-system-monitor.age",
    "pushover-uptime-kuma.age",
)
REPO_ROOT = Path(__file__).resolve().parents[2]
MAX_HEADER_BYTES = 64 * 1024
MAX_LINE_BYTES = 256


class CheckError(Exception):
    """입력·도구 원문을 포함하지 않는 검사 실패."""


def decode_base64(value: bytes, length: int) -> bytes:
    """age의 padding 없는 canonical base64만 받는다."""
    try:
        decoded = base64.b64decode(value + b"=" * (-len(value) % 4), validate=True)
    except (ValueError, binascii.Error):
        raise CheckError from None
    if len(decoded) != length or base64.b64encode(decoded).rstrip(b"=") != value:
        raise CheckError
    return decoded


def recipient_tag(public_key: str) -> bytes:
    # 공식 agessh의 sshFingerprint와 같은 SSH wire 바이트 기준이다.
    # https://github.com/FiloSottile/age/blob/main/agessh/agessh.go
    # 32비트 표식은 충돌할 수 있으므로 일치가 실제 복호화 가능의 증거는 아니다.
    if not isinstance(public_key, str) or any(c in public_key for c in "\r\n\x00"):
        raise CheckError
    fields = public_key.split()
    if len(fields) < 2 or fields[0] != "ssh-ed25519":
        raise CheckError
    try:
        wire = base64.b64decode(fields[1], validate=True)
    except (ValueError, binascii.Error):
        raise CheckError from None
    prefix = b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"
    if (not wire.startswith(prefix) or len(wire) != len(prefix) + 32
            or base64.b64encode(wire).decode("ascii") != fields[1]):
        raise CheckError
    return base64.b64encode(hashlib.sha256(wire).digest()[:4]).rstrip(b"=")


def declared_tags(repo_root: Path) -> dict[str, set[bytes]]:
    # 대상 여섯 항목만 평가한다. 공개키와 Nix 오류 출력은 메모리에서만 취급한다.
    names = " ".join(json.dumps(name) for name in TARGETS)
    expression = (
        "let rules = import ./secrets/secrets.nix; in "
        "builtins.listToAttrs (map (name: { inherit name; "
        f"value = rules.${{name}}.publicKeys; }}) [ {names} ])"
    )
    try:
        result = subprocess.run(
            ["nix", "eval", "--json", "--impure", "--expr", expression],
            cwd=repo_root, capture_output=True, text=True, check=True, timeout=60,
        )
        declarations = json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, ValueError):
        raise CheckError from None
    if not isinstance(declarations, dict) or set(declarations) != set(TARGETS):
        raise CheckError
    expected = {}
    for name in TARGETS:
        keys = declarations[name]
        if not isinstance(keys, list) or not keys:
            raise CheckError
        tags = {}
        for key in keys:
            tag = recipient_tag(key)
            # 서로 다른 선언 키가 짧은 표식에서 충돌하면 판정하지 않는다.
            wire = key.split()[1]
            if tag in tags and tags[tag] != wire:
                raise CheckError
            tags[tag] = wire
        expected[name] = set(tags)
    return expected


def header_tags(stream) -> set[bytes]:
    # 지원 범위는 현재 대상이 사용하는 binary age v1 / ssh-ed25519이다.
    # 미지 recipient/armor는 무시하지 않고 검사 실패로 남긴다.
    # https://age-encryption.org/v1 (header와 canonical base64 형식)
    consumed = 0

    def line() -> bytes:
        nonlocal consumed
        value = stream.readline(MAX_LINE_BYTES + 1)
        consumed += len(value)
        if (not value.endswith(b"\n") or len(value) > MAX_LINE_BYTES
                or consumed > MAX_HEADER_BYTES):
            raise CheckError
        return value[:-1]

    if line() != b"age-encryption.org/v1":
        raise CheckError
    tags = set()
    while True:
        entry = line()
        if entry.startswith(b"--- "):
            if not tags:
                raise CheckError
            decode_base64(entry[4:], 32)
            # 최소 payload(nonce + 빈 평문의 AEAD tag)도 없는 잘린 파일은 거절한다.
            if len(stream.read(32)) != 32:
                raise CheckError
            return tags
        fields = entry.split(b" ")
        if len(fields) != 4 or fields[:2] != [b"->", b"ssh-ed25519"]:
            raise CheckError
        decode_base64(fields[2], 4)
        decode_base64(fields[3], 32)
        decode_base64(line(), 32)
        tags.add(fields[2])


def file_tags(path: Path) -> set[bytes]:
    # 링크나 특수 파일을 통해 대상 밖의 데이터를 읽거나 대기하지 않는다.
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise CheckError
            return header_tags(stream)
    except OSError:
        raise CheckError from None


def check(repo_root: Path) -> int:
    try:
        expected = declared_tags(repo_root)
    except CheckError:
        for name in TARGETS:
            print(f"secrets/{name}: 검사 실패")
        return 2
    exit_code = 0
    for name in TARGETS:
        try:
            matches = file_tags(repo_root / "secrets" / name) == expected[name]
            verdict = "일치" if matches else "불일치"
            exit_code = max(exit_code, 0 if matches else 1)
        except CheckError:
            verdict = "검사 실패"
            exit_code = 2
        print(f"secrets/{name}: {verdict}")
    return exit_code


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="B04 여섯 암호문의 공개 헤더 표식과 현재 선언을 비교합니다.",
        epilog=("binary age v1의 ssh-ed25519만 지원하며 다른 형식은 검사 실패입니다. "
                "표식 일치는 복호화·무결성·실제 배포 성공을 증명하지 않습니다. "
                "종료 코드: 0 일치, 1 불일치, 2 검사 실패. nix develop 환경에서 실행하세요."),
    )
    parser.parse_args()
    raise SystemExit(check(REPO_ROOT))

# 사전 게이트·마스킹 게이트

업로드 전 검사의 정본이다. 모든 업로드 대상은 아래 두 게이트를 전부 통과해야 하며, 하나라도 통과하지 못한 후보는 업로드하지 않는다. branch 라우팅과 안전 불변식은 [../SKILL.md](../SKILL.md)를 따른다.

## 1. 사전 게이트

1. 실제 실행할 `gh` executable 또는 실행 가능한 wrapper 하나를 확정한다. shell alias나 shell builtin을 실행기로 사용하지 않는다.
2. 같은 실행기로 `api user`, `extension list`, `attach`를 모두 수행한다. 허용 공급 원점은 저장소 Nix 선언에 고정된 `greenheadHQ/gh-attach`뿐이다. runtime 목록만으로 원점을 확인할 수 없으면 Nix 패키지 선언(`modules/shared/programs/git/gh-attach-package.nix`)의 owner, repo, rev를 확인한다. `gh attach`가 없으면 모든 후보를 `SKIPPED(NO_EXTENSION)`으로 기록하고 설치 상태 확인 방법만 안내한다. 명령형 자동 설치는 하지 않는다.
3. 각 후보가 읽을 수 있는 일반 파일인지 확인한다. 읽기 실패나 검사 중 오류는 `FAILED(PREUPLOAD)`으로 기록한다.
4. 파일 크기를 byte 단위로 측정한다. `10,485,760` bytes(= `10 * 1024 * 1024`, GitHub 첨부 이미지 10MB 제한에 대한 보수적 결정 상한 — [Attaching files](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files)) 이상이면 `SKIPPED(TOO_LARGE)`로 기록한다.
5. 확장자를 신뢰하지 않고 다음 명령의 magic MIME 결과를 사용한다.

```bash
file --brief --mime-type "$FILE"
```

허용 MIME은 `image/jpeg`와 `image/png`뿐이다. 그 외 MIME은 `SKIPPED(UNSUPPORTED_FORMAT)`으로 기록한다.

6. PNG는 chunk 구조를 파싱하여 `acTL` chunk 존재 여부를 확인한다. `acTL`이 있으면 APNG이므로 `SKIPPED(UNSUPPORTED_FORMAT)`으로 기록한다. 파일 전체에서 문자열만 검색하는 방식은 압축 데이터의 우연한 일치를 오판할 수 있으므로 사용하지 않는다. 기준 구현:

```bash
python3 -c '
import os, struct, sys
# fail-closed PNG 판정: exit 0=완결된 static PNG, 1=APNG, 2=파싱 오류(시그니처 불일치·truncation·위조 length·trailing data 포함)
# assert를 쓰지 않는다 — python3 -O에서 제거되어 검사가 사라진다.
try:
    with open(sys.argv[1], "rb") as f:
        file_size = os.fstat(f.fileno()).st_size
        if f.read(8) != b"\x89PNG\r\n\x1a\n":
            sys.exit(2)
        while True:
            head = f.read(8)
            if len(head) < 8:
                sys.exit(2)  # IEND 전에 끝남 — 잘린 파일
            length, ctype = struct.unpack(">I4s", head)
            if length + 4 > file_size - f.tell():
                sys.exit(2)  # 선언 length가 남은 바이트 초과 — 위조 length의 거대 할당(OOM)을 read 전에 차단
            if ctype == b"acTL":
                sys.exit(1)  # APNG
            if ctype == b"IEND":
                # IEND는 빈 chunk — 길이 0, 고정 CRC, 직후 EOF까지 확인해야 완결로 본다.
                # IEND 뒤에 붙은 데이터는 마스킹 게이트가 보지 못하는 미검사 바이트이므로 거부한다.
                if length != 0 or f.read(4) != b"\xaeB`\x82" or f.read(1) != b"":
                    sys.exit(2)
                sys.exit(0)  # 완결된 static PNG
            body = f.read(length + 4)  # data + CRC
            if len(body) < length + 4:
                sys.exit(2)  # chunk 잘림
except OSError:
    sys.exit(2)
' "$FILE"
```

exit code를 상태에 그대로 매핑한다 — `0`: 통과, `1`(APNG): `SKIPPED(UNSUPPORTED_FORMAT)`, 그 외(시그니처 불일치·truncation·IEND 훼손·trailing data·읽기 오류): `FAILED(PREUPLOAD)`.
7. 통과한 후보를 staging에 고정한다 — `umask 077` 아래 `mktemp -d`로 만든 staging 디렉터리에 복사하고, 복사본의 SHA-256·byte 크기·magic MIME·(PNG면) `acTL` 부재를 원본 기록과 대조한다. 하나라도 다르면 그 후보를 `FAILED(PREUPLOAD)`로 기록한다. 이후 마스킹 게이트 열람과 업로드는 전부 staging 사본 경로만 사용하고 원본 경로를 다시 읽지 않는다 — 검사와 업로드 사이에 원본이 교체되어 미검사 바이트가 업로드되는 것(TOCTOU)을 staging 사본이 구조적으로 막는다.

## 2. 마스킹 게이트

업로드 전 실제 이미지를 직접 열어 픽셀에 노출된 내용을 검사한다. 파일명이나 사용자의 설명만으로 통과시키지 않는다.

직접 검사의 판정 기준은 단 하나다 — "이 파일의 렌더링 결과(픽셀)를 시각적으로 확인했는가". 파일 경로·메타데이터·바이트 검사만으로는 이 기준을 충족하지 않는다. 런타임별 1차 수단은 아래 표를 따르되(호출 스킬들의 런타임 도구 매핑 표와 같은 관례), 표에 없는 수단이라도 렌더링 결과를 시각적으로 확인했으면 기준을 충족한다. 현재 런타임에서 기준을 충족할 수단이 없거나 파일을 렌더링할 수 없으면 검사 불가로 판정한다.

| 런타임 | 1차 검사 수단 |
|--------|---------------|
| Claude Code 세션 | 파일 읽기 도구로 이미지 파일을 열어 렌더링 확인 |
| Codex 세션 | 이미지 열람 도구(`view_image`)로 렌더링 확인 |
| headless/기타 | 렌더링 수단 부재 시 검사 불가 판정 |

다음을 포함한 회사·개인 식별 정보, credential, API key·token, 내부 URL·호스트명, 공개하면 안 되는 경로·계정·세션 정보가 보이면 원본을 수정하지 않고 해당 후보를 `SKIPPED(SENSITIVE_CONTENT)`으로 기록한다. 이미지 편집이나 자동 마스킹은 이 절차의 범위가 아니다.

이미지를 실제로 검사할 수 없는 런타임에서는 사용자에게 대신 확인을 요구하지 않고 `SKIPPED(NO_IMAGE_INSPECTION)`으로 기록한다. 통과한 후보는 별도 blocking 확인 없이 자동으로 다음 단계로 진행한다.

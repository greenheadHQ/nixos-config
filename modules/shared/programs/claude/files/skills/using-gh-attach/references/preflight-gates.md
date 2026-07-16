# 사전 게이트·마스킹 게이트

업로드 전 검사의 정본이다. 모든 업로드 대상은 아래 두 게이트를 전부 통과해야 하며, 하나라도 통과하지 못한 후보는 업로드하지 않는다. branch 라우팅과 안전 불변식은 [../SKILL.md](../SKILL.md)를 따른다.

## 1. 사전 게이트

1. 실제 실행할 `gh` executable 또는 실행 가능한 wrapper 하나를 확정한다. shell alias나 shell builtin을 실행기로 사용하지 않는다.
2. 같은 실행기로 `api user`, `extension list`, `attach`를 모두 수행한다. 허용 공급 원점은 저장소 Nix 선언에 고정된 `greenheadHQ/gh-attach`뿐이다. runtime 목록만으로 원점을 확인할 수 없으면 Nix 패키지 선언(`modules/shared/programs/git/gh-attach-package.nix`)의 owner, repo, rev를 확인한다. `gh attach`가 없으면 모든 후보를 `SKIPPED(NO_EXTENSION)`으로 기록하고 설치 상태 확인 방법만 안내한다. 명령형 자동 설치는 하지 않는다.
3. 각 후보가 읽을 수 있는 일반 파일인지 확인한다. 읽기 실패나 검사 중 오류는 `FAILED(PREUPLOAD)`으로 기록한다.
4. 파일 크기를 byte 단위로 측정한다. 크기는 차단 기준이 아니다 — 측정값은 7단계 staging 무결성 대조의 앵커로 사용한다. GitHub 상한은 파일 종류·플랜별로 달라([Attaching files](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files)) 스킬이 결정적으로 판정할 수 없으므로 서버 판정에 위임하고, 서버가 크기로 거부하면 `FAILED(PREUPLOAD)`로 기록한다.
5. 확장자를 신뢰하지 않고 다음 명령의 magic MIME 결과를 사용한다.

```bash
file --brief --mime-type "$FILE"
```

측정한 MIME은 차단 기준이 아니라 마스킹 게이트의 검사 방식 라우팅(직접 검사 수단 선택, 수단이 없으면 사용자 확인 경로)에 사용한다. 포맷 지원 여부 판정은 GitHub 서버에 위임하며, 서버가 거부한 포맷은 `FAILED(PREUPLOAD)`로 기록한다.

6. magic MIME이 `image/png`인 파일은 chunk 구조를 파싱하여 `acTL` chunk 존재 여부를 확인한다. `acTL`이 있으면 APNG이므로 차단이 아니라 "첫 프레임만 렌더링되어 뒷 프레임을 검사할 수 없는 파일"로 분류해 마스킹 게이트의 사용자 확인 경로로 라우팅한다. 파일 전체에서 문자열만 검색하는 방식은 압축 데이터의 우연한 일치를 오판할 수 있으므로 사용하지 않는다. 기준 구현:

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

exit code를 검사 경로에 그대로 매핑한다 — `0`(정적 PNG): 직접 검사 경로, `1`(APNG): 검사 불가 분류 → 사용자 확인 경로, 그 외(시그니처 불일치·truncation·위조 length·IEND 훼손·trailing data·읽기 오류): `FAILED(PREUPLOAD)` (구조가 훼손된 파일은 분류 자체가 불가능하므로 fail-closed).
7. 통과한 후보를 staging에 고정한다 — `umask 077` 아래 `mktemp -d`로 만든 staging 디렉터리에 복사하고, 복사본의 SHA-256·byte 크기·magic MIME·(PNG면) `acTL` 판정 결과를 원본 기록과 대조한다. 하나라도 다르면 그 후보를 `FAILED(PREUPLOAD)`로 기록한다. 이후 마스킹 게이트 열람과 업로드는 전부 staging 사본 경로만 사용하고 원본 경로를 다시 읽지 않는다 — 검사와 업로드 사이에 원본이 교체되어 미검사 바이트가 업로드되는 것(TOCTOU)을 staging 사본이 구조적으로 막는다.

## 2. 마스킹 게이트

업로드 전 파일의 실제 내용을 직접 열어 노출된 정보를 검사한다. 파일명이나 사용자의 설명만으로 통과시키지 않는다.

직접 검사의 판정 기준은 단 하나다 — "이 파일의 전체 내용을 직접 열람해 확인했는가". 파일 경로·메타데이터·바이트 존재 검사만으로는 이 기준을 충족하지 않는다. 검사 수단은 magic MIME과 (PNG의 경우) 사전 게이트 6단계 파서 판정을 입력으로 다음 분류를 따른다.

| 분류 | 검사 수단 | 통과 기준 |
|------|-----------|----------|
| 정적 이미지 (JPEG, 6단계 파서로 `acTL` 부재가 확인된 정적 PNG) | 이미지 렌더링 열람 | 픽셀 시각 확인 |
| 플레인 텍스트 (코드·로그·CSV·JSON 등 — 렌더링 없는 텍스트 한정) | 내용 읽기 | 전체 내용 확인 |
| PDF | 페이지 읽기 (수단이 있는 런타임) | 전체 페이지 확인 |
| 애니메이션 가능 이미지 (GIF·WebP)·렌더링 마크업 (SVG·마크다운·HTML)·동영상·오디오·압축·기타 바이너리·APNG | 없음 — 직접 검사 불가 | 아래 사용자 확인 게이트 |

검사 불가 분류의 근거와 경계:

- GIF·WebP는 정적 파일이라도 검사 불가로 분류한다 — magic MIME은 애니메이션 여부를 알려주지 않고, 렌더링 열람은 첫 프레임만 보여주므로 "전체 내용 확인"을 보장할 수 없다 (APNG와 같은 뒷 프레임 위험, 판별 파서가 확립될 때까지 fail-closed).
- SVG·마크다운·HTML처럼 렌더링을 가진 마크업 포맷은 텍스트 소스여도 검사 불가로 분류한다 — embedded base64 이미지·외부 리소스처럼 소스 읽기가 렌더링 결과를 대변하지 못하는 내용을 담을 수 있다 (소스만 읽으면 base64 blob은 불투명 텍스트로 보이지만 GitHub 렌더러는 픽셀로 그린다). 소스와 렌더링이 괴리되는 마크업 포맷 일반에 같은 원칙을 적용한다.
- 압축 파일은 내부를 추출해 재귀 검사하지 않는다 — 검사 불가로 취급한다.

직접 검사의 통과 요건:

- 직접 검사는 파일 전체를 덮어야 통과다. 읽기 수단이 내용을 잘라 보여주면(줄 수·페이지 수 상한 등) 남은 범위를 끝까지 반복 열람한다.
- 열람한 범위가 전체임을 파일의 총 줄 수·페이지 수와 대조해 확인한다. 전체 커버리지를 확인할 수 없으면 그 후보는 통과가 아니라 검사 불가로 분류한다 (fail-closed — 미열람 뒷부분의 민감정보가 비가역 업로드되는 것을 막는다).
- 분류와 무관하게, 현재 런타임에서 해당 검사 수단을 쓸 수 없는 후보(예: PDF 페이지 읽기 수단이 없는 런타임의 PDF)도 검사 불가로 판정한다. 런타임별 1차 수단은 아래 표를 따르되(호출 스킬들의 런타임 도구 매핑 표와 같은 관례), 표에 없는 수단이라도 전체 내용을 직접 확인했으면 기준을 충족한다.

| 런타임 | 1차 검사 수단 |
|--------|---------------|
| Claude Code 세션 | 파일 읽기 도구 (이미지 렌더링·텍스트 내용·PDF 페이지) |
| Codex 세션 | 이미지는 이미지 열람 도구(`view_image`), 텍스트는 내용 읽기 |
| headless/기타 | 수단 부재 시 검사 불가 판정 |

다음을 포함한 회사·개인 식별 정보, credential, API key·token, 내부 URL·호스트명, 공개하면 안 되는 경로·계정·세션 정보가 보이면 원본을 수정하지 않고 해당 후보를 `SKIPPED(SENSITIVE_CONTENT)`으로 기록한다. 파일 편집이나 자동 마스킹은 이 절차의 범위가 아니다.

검사를 통과한 후보는 별도 blocking 확인 없이 자동으로 다음 단계로 진행한다. 검사 수단이 있는 파일을 검사하지 않고 사용자에게 확인을 미루지 않는다.

### 검사 불가 파일의 사용자 확인 게이트

직접 검사 수단이 확보되지 않은 모든 후보 — 분류상 검사 불가인 파일(GIF·WebP·렌더링 마크업(SVG·마크다운·HTML)·동영상·오디오·압축·기타 바이너리·APNG)과, 분류상 검사 가능하지만 현재 런타임에 수단이 없거나 전체 커버리지를 확인할 수 없는 파일 — 는 업로드 직전, "이 파일은 내용 검사를 하지 못했으니 민감정보가 없음을 직접 확인해달라"는 별도 명시 확인을 사용자에게 1회 받는다. 첨부 요청 자체("이 동영상 올려줘")는 이 확인으로 간주하지 않는다 — 첨부 의사와 민감정보 검토 완료는 다른 판단이다.

- 사용자가 확인하면 해당 후보는 다음 단계로 진행한다.
- 사용자가 거부하거나 보류하면 `SKIPPED(USER_DECLINED)`으로 기록한다.
- 확인을 받을 수 없는 맥락(headless 등)에서는 `SKIPPED(NO_INSPECTION)`으로 기록한다.

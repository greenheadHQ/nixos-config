# 시각 증빙 첨부 절차

`create-pr`와 `create-issue`에서 명시적으로 제공된 시각 증빙 후보를 GitHub user-attachments로 첨부할 때 사용하는 정본이다. 업로드된 asset에는 삭제 UI가 없으므로 업로드는 비가역 작업으로 취급한다.

첨부는 부가 기능이다. 이 절차의 검사·업로드·본문 삽입이 실패해도 PR 또는 이슈의 본 작업은 원래 본문으로 계속한다. 후보가 없으면 이 절차를 실행하지 않고 `ATTACH_STATUS`도 출력하지 않는다.

## 실행 시점과 공통 계약

- 본문 작성 단계에서는 후보를 식별하고 삽입 슬롯만 준비한다.
- 업로드는 게시 의사가 확정된 뒤, `--body-file` 게시 직전에만 실행한다. 사용자 확인 게이트가 있으면 확인 통과 전에는 업로드하지 않는다.
- 모든 업로드 대상의 사전 게이트와 마스킹 게이트를 먼저 완료한다. 최종 재확인까지 모두 통과하기 전에는 어떤 파일도 업로드하지 않는다.
- 각 후보는 독립 상태를 갖는다. 한 후보의 탈락이나 실패 때문에 다른 후보 또는 본 작업을 차단하지 않는다.
- `create-pr update`에서는 기존 `user-attachments` 링크를 그대로 보존한다. 명시적으로 새로 제공된 후보만 검사하며 기존 링크나 동일 파일을 재업로드하지 않는다.

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

6. PNG는 chunk 구조를 파싱하여 `acTL` chunk 존재 여부를 확인한다. `acTL`이 있으면 APNG이므로 `SKIPPED(UNSUPPORTED_FORMAT)`으로 기록한다. 파일 전체에서 문자열만 검색하는 방식은 압축 데이터의 우연한 일치를 오판할 수 있으므로 사용하지 않는다.
7. 통과한 후보마다 SHA-256, byte 크기, magic MIME을 기록한다. 게시 직전 첫 업로드를 시작하기 전에 전체 업로드 대상의 세 값을 다시 계산하고 PNG의 `acTL` 부재도 다시 확인한다. 하나라도 바뀌었으면 그 후보를 업로드 집합에서 제외하고 1단계부터 재검사한다. 재검사가 끝나기 전에는 나머지 파일도 업로드하지 않는다.

## 2. 마스킹 게이트

업로드 전 실제 이미지를 직접 열어 픽셀에 노출된 내용을 검사한다. 파일명이나 사용자의 설명만으로 통과시키지 않는다.

직접 검사의 판정 기준은 단 하나다 — "이 파일의 렌더링 결과(픽셀)를 시각적으로 확인했는가". 수단은 무엇이든 좋다: 런타임의 이미지 파일 읽기(파일 읽기 도구의 이미지 렌더링), 브라우저·스크린샷 도구의 열람 등. 반대로 파일 경로·메타데이터·바이트 검사만으로는 이 기준을 충족하지 않는다. 현재 런타임에서 위 기준을 충족할 수단이 하나도 없거나 파일을 렌더링할 수 없으면 검사 불가로 판정한다.

다음을 포함한 회사·개인 식별 정보, credential, API key·token, 내부 URL·호스트명, 공개하면 안 되는 경로·계정·세션 정보가 보이면 원본을 수정하지 않고 해당 후보를 `SKIPPED(SENSITIVE_CONTENT)`으로 기록한다. 이미지 편집이나 자동 마스킹은 이 절차의 범위가 아니다.

이미지를 실제로 검사할 수 없는 런타임에서는 사용자에게 대신 확인을 요구하지 않고 `SKIPPED(NO_IMAGE_INSPECTION)`으로 기록한다. 통과한 후보는 별도 blocking 확인 없이 자동으로 다음 단계로 진행한다.

## 3. 실행기와 repo 고정

현재 작업 디렉터리 기준 canonical repo를 같은 실행기로 다시 조회하고 모든 업로드에 `-R "$OWNER_REPO"`를 명시한다. ambient 환경변수나 이전 명령의 repo 값을 재사용하지 않는다.

```bash
GH_EXEC="<실제로 사용할 executable 경로>"
OWNER_REPO=$("$GH_EXEC" repo view --json nameWithOwner -q .nameWithOwner)
LOGIN=$("$GH_EXEC" api user --jq .login)
"$GH_EXEC" extension list
```

- `GH_EXEC`에는 `timeout`이 직접 실행할 수 있는 실제 파일 경로를 사용한다.
- 계정 확인과 업로드에 서로 다른 raw `gh`, wrapper, alias를 섞지 않는다.
- 브라우저 쿠키 자동 탐색이 명시적으로 실패하면 업로드가 발생하지 않은 것을 확인한 뒤 `attach.yml` 또는 환경에 맞는 `--browser`·`--profile` 인자로 로그인된 프로필을 지정할 수 있다. 로컬 프로필 이름이나 cookie 경로를 본문·로그·저장소에 박제하지 않는다.
- 계정, repo, 확장 공급 원점 또는 무결성 상태가 불명확하면 업로드하지 않고 `FAILED(PREUPLOAD)`으로 기록한다.

## 4. 업로드와 본문 삽입

각 파일을 30초 timeout으로 한 번만 업로드한다. `command`는 shell builtin이므로 `timeout 30 command gh ...` 형태를 사용하지 않는다.

```bash
timeout 30 "$GH_EXEC" attach "$FILE" \
  -R "$OWNER_REPO" \
  --json id,href,name
```

필요한 브라우저·프로필 선택은 `attach.yml` 또는 같은 `attach` 호출의 옵션으로 추가하되, 사전 확인과 업로드의 실행기는 바꾸지 않는다.

성공 실측 출력과 필드 타입은 다음과 같다. Nix로 선언한 fork 소스 빌드 바이너리도 2026-07-16에 30초 timeout 내 동일 schema로 재확인했다. UUID, 정수, 파일명은 실행마다 달라진다.

```json
{"href":"https://github.com/user-attachments/assets/26d485fc-4f52-4428-9243-a68d6792a8b2","id":622195517,"name":"attach-test.png"}
```

- `href`: string, prefix가 `https://github.com/user-attachments/assets/`
- `id`: integer
- `name`: string

exit code, JSON object shape, 필드 타입, `href` prefix를 모두 검증한다.

- timeout, 프로세스 종료, 응답 유실, 성공 여부를 판정할 수 없는 출력은 `FAILED(UNKNOWN_REMOTE_STATE)`이다. 원격 asset이 생성됐을 수 있으므로 자동 재업로드하지 않는다.
- 서버가 요청을 명시적으로 거부했거나 cookie 탐색 단계에서 실패하는 등 원격 asset 미생성이 확실하면 `FAILED(PREUPLOAD)`이다.
- 유효한 `href`를 확보하면 원본 본문 파일을 보존한 채 사본에 `![<설명>](<href>)`를 준비된 슬롯에 삽입한다.
- `href` 확보 후 검증이나 로컬 삽입이 실패하면 `FAILED(LOCAL_INSERT)`로 기록하고 원래 본문으로 게시한다. 보고에 확보한 `href`를 포함하며 재업로드하지 않는다.
- 본문 게시 자체가 실패하면 확보한 `href`와 수정된 본문 파일을 보존하여 동일 asset으로 재시도한다. 새 asset을 업로드하지 않는다.

## 5. fail-open 상태 보고

파일별 상태와 본 작업 진행 규칙은 다음과 같다.

| 상황 | 파일 상태 | 본 작업 | 보고 의무 |
|------|-----------|---------|-----------|
| 업로드, `href` 검증, 본문 삽입 성공 | `UPLOADED` | 진행 | 성공 로그 |
| 확장 부재 | `SKIPPED(NO_EXTENSION)` | 진행 | 설치 상태 확인 안내 |
| 지원하지 않는 MIME 또는 APNG | `SKIPPED(UNSUPPORTED_FORMAT)` | 진행 | 판정 근거 |
| 크기 제한 초과 | `SKIPPED(TOO_LARGE)` | 진행 | byte 크기 |
| 민감정보 발견 | `SKIPPED(SENSITIVE_CONTENT)` | 진행 | 민감 값은 노출하지 않고 사유만 명시 |
| 이미지 검사 능력 부재 | `SKIPPED(NO_IMAGE_INSPECTION)` | 진행 | 검사 불가 사실 |
| 원격 미생성이 확실한 실패 | `FAILED(PREUPLOAD)` | 진행 | 사유와 안전한 수동 재시도 안내 |
| timeout 또는 응답 유실 | `FAILED(UNKNOWN_REMOTE_STATE)` | 진행 | 자동 재업로드 금지, 수동 판단 안내 |
| `href` 확보 후 검증·삽입 실패 | `FAILED(LOCAL_INSERT)` | 진행 | 확보한 `href`와 재사용 안내 |

최종 응답에는 후보별 파일명, 상태, 민감하지 않은 사유를 포함한다. `href`를 확보한 상태에서는 그 값도 포함한다.

집계에서 `m`은 후보 수, `u`는 업로드 성공 수, `s`는 skip 수, `f`는 failed 수다. 모든 집계 표기는 명명형 `key=값` 필드로 통일한다 — 위치 기반 축약(`u/s/0` 등)은 필드 의미를 드러내지 못하므로 쓰지 않는다.

- 전부 `UPLOADED`: `ATTACH_STATUS=UPLOADED(uploaded=m/m)`
- 하나 이상 `FAILED`: `ATTACH_STATUS=FAILED(failed=f, total=m)`
- failed 없이 전부 skipped: `ATTACH_STATUS=SKIPPED(skipped=m/m)`
- failed 없이 uploaded와 skipped 혼합: `ATTACH_STATUS=PARTIAL(uploaded=u, skipped=s, total=m)`
- 후보 0개: `ATTACH_STATUS`를 출력하지 않음

`FAILED(PREUPLOAD)`만 원격 미생성이 확실할 때 수동 재시도를 안내할 수 있다. `FAILED(UNKNOWN_REMOTE_STATE)`는 blind retry로 orphan asset을 만들 수 있으므로 자동·수동 명령형 재업로드를 제안하지 말고 GitHub 본문 편집기의 최근 업로드와 로컬 로그를 사람이 대조하도록 안내한다.

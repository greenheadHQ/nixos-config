# 실행기 고정·업로드·상태 보고

업로드 실행과 결과 보고의 정본이다. [preflight-gates.md](preflight-gates.md)의 두 게이트를 전부 통과한 후보만 이 절차에 진입한다. branch 라우팅과 안전 불변식은 [../SKILL.md](../SKILL.md)를 따른다.

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
- 브라우저 쿠키 자동 탐색이 명시적으로 실패하면 업로드가 발생하지 않은 것을 확인한 뒤 [cookie-discovery.md](cookie-discovery.md)의 절차로 로그인 프로필을 특정해 재시도한다 (auto 탐색이 실패하는 구조적 사유는 그 문서 1절 참조). 조사의 자율 경계(메타데이터 한정)와 박제 금지 원칙도 그 문서를 따른다.
- 계정, repo, 확장 공급 원점 또는 무결성 상태가 불명확하면 업로드하지 않고 `FAILED(PREUPLOAD)`으로 기록한다.

`OWNER_REPO`를 고정한 뒤의 모든 조회·게시·업로드 명령은 대상 repo를 명령 자체에 명시한다. 명시 문법은 명령마다 다르므로(플래그로 받는 명령과 positional 인자로 받는 명령이 섞여 있다) 아래 표 밖의 명령은 실행 전 `--help`로 확인한다.

| 명령 | repo 명시 문법 |
|------|----------------|
| `gh issue view`·`gh issue edit`·`gh issue comment` | `-R "$OWNER_REPO"` |
| `gh pr view`·`gh pr edit`·`gh pr comment` | `-R "$OWNER_REPO"` |
| `gh attach` | `-R "$OWNER_REPO"` |
| `gh repo view` | positional — `gh repo view "$OWNER_REPO"` (`-R`을 받지 않는다) |

`gh repo view`는 이 스킬에서 두 용도로 쓰이고 인자 유무가 서로 다르다 — 뒤섞으면 검증이 무력화된다.

- cwd canonical repo를 탐지할 때는 위 코드블록처럼 인자 없이 호출한다. 여기에 `"$OWNER_REPO"`를 넣으면 "추출한 repo가 cwd canonical repo와 같은가"라는 검증이 자기 입력을 되돌려받는 순환이 되어 cross-repo 거부([../SKILL.md](../SKILL.md))가 무력화된다.
- 이미 고정된 대상 repo를 조회할 때는(visibility 판정 등) `"$OWNER_REPO"`를 positional로 명시한다.

표는 gh 2.96.0 실측이다 — 재검증은 `gh <명령> --help`의 `-R, --repo` 유무와 `USAGE` 줄의 positional 자리를 대조한다. `gh attach`는 gh CLI가 아니라 fork한 확장(`greenheadHQ/gh-attach`)이 제공하므로 gh 버전과 무관하게 `gh attach --help`로 따로 확인한다.

## 4. 업로드와 본문 삽입

각 파일을 30초 timeout으로 한 번만 업로드한다. 업로드 대상은 사전 게이트 7단계([preflight-gates.md](preflight-gates.md))에서 고정한 staging 사본 경로다 — 원본 경로를 다시 읽지 않는다. `command`는 shell builtin이므로 `timeout 30 command gh ...` 형태를 사용하지 않는다.

```bash
timeout 30 "$GH_EXEC" attach "$STAGED_FILE" \
  -R "$OWNER_REPO" \
  --json id,href,name
```

필요한 브라우저·프로필 선택은 `attach.yml` 또는 같은 `attach` 호출의 옵션으로 추가하되, 사전 확인과 업로드의 실행기는 바꾸지 않는다.

성공 실측 출력과 필드 타입은 다음과 같다. Nix로 선언한 fork 소스 빌드 바이너리도 2026-07-16에 30초 timeout 내 동일 schema로 재확인했다 (재검증: 무해한 테스트 이미지로 `timeout 30 "$GH_EXEC" attach <테스트 이미지> -R greenheadHQ/attach-sandbox --json id,href,name` — private 샌드박스 전용, 업로드는 비가역). UUID, 정수, 파일명은 실행마다 달라진다.

```json
{"href":"https://github.com/user-attachments/assets/26d485fc-4f52-4428-9243-a68d6792a8b2","id":622195517,"name":"attach-test.png"}
```

- `href`: string, prefix가 `https://github.com/user-attachments/assets/`
- `id`: integer
- `name`: string

exit code, JSON object shape, 필드 타입, `href` prefix를 모두 검증한다.

- timeout, 프로세스 종료, 응답 유실, 성공 여부를 판정할 수 없는 출력은 `FAILED(UNKNOWN_REMOTE_STATE)`이다. 원격 asset이 생성됐을 수 있으므로 자동 재업로드하지 않는다.
- 서버가 요청을 명시적으로 거부했거나 cookie 탐색 단계에서 실패하는 등 원격 asset 미생성이 확실하면 `FAILED(PREUPLOAD)`이다.
- 유효한 `href`를 확보하면 원본 본문 파일을 보존한 채 사본의 준비된 슬롯에 파일 종류별 문법으로 삽입한다. 종류 판정은 사전 게이트 5단계에서 측정한 magic MIME을 재사용한다 (확장자·사용자 진술로 판정하지 않는다) — `image/*`: `![<설명>](<href>)`. `video/*`: `<href>`를 단독 라인 bare URL로 삽입한다 (GitHub이 인라인 플레이어로 렌더링하는 유일한 형태 — `![<설명>](<href>)`로 감싸면 깨진 이미지로 표시된다). 그 외(로그·압축·문서 등): `[<파일명>](<href>)` 링크로 삽입한다. 라벨(`<설명>`·`<파일명>`)은 삽입 전에 정규화한다 — Markdown 링크 문법을 깨는 메타문자(`[`·`]`·`(`·`)`)와 개행을 제거하거나 치환한 안전한 텍스트만 라벨로 쓴다 (파일명은 사용자 제공 값이므로 그대로 신뢰하지 않는다).
- `href` 확보 후 검증이나 로컬 삽입이 실패하면 `FAILED(LOCAL_INSERT)`로 기록한다. 소비자 호출에서는 원래 본문으로 게시한다 (게시 자체가 본 작업이므로 첨부 없이 진행). 단독 호출에서는 게시를 중단한다 — 기존 본문은 서버에 그대로 있고, 보존해 둔 사본을 재게시하면 조회 이후 제3자의 본문 수정을 덮어쓸 수 있다. 양쪽 모두 보고에 확보한 `href`를 포함하며 재업로드하지 않는다.
- 본문 게시 자체가 실패하면 확보한 `href`와 수정된 본문 파일을 보존하여 동일 asset으로 재시도한다. 새 asset을 업로드하지 않는다.

## 5. fail-open 상태 보고

파일별 상태와 본 작업 진행 규칙은 다음과 같다.

| 상황 | 파일 상태 | 본 작업 | 보고 의무 |
|------|-----------|---------|-----------|
| 업로드, `href` 검증, 본문 삽입 성공 | `UPLOADED` | 진행 | 성공 로그 |
| 확장 부재 | `SKIPPED(NO_EXTENSION)` | 진행 | 설치 상태 확인 안내 |
| 민감정보 발견 | `SKIPPED(SENSITIVE_CONTENT)` | 진행 | 민감 값은 노출하지 않고 사유만 명시 |
| 검사 수단 부재이고 사용자 확인도 받을 수 없는 맥락 (headless 등 — 확인 가능 맥락이면 이 상태 대신 사용자 확인 게이트로, 비-PUBLIC 완화가 적용되면 확인 없이 업로드 진행) | `SKIPPED(NO_INSPECTION)` | 진행 | 검사·확인 불가 사실 |
| 검사 불가 파일의 확인 요청을 사용자가 거부·보류 | `SKIPPED(USER_DECLINED)` | 진행 | 거부 사실 (민감 값 추정 금지) |
| 원격 미생성이 확실한 실패 (서버의 포맷·크기 거부 포함) | `FAILED(PREUPLOAD)` | 진행 | 사유와 안전한 수동 재시도 안내 |
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

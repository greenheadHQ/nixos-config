# 브라우저 쿠키 프로필 탐색

`gh attach`가 `failed to resolve usable cookie source` 류로 실패했을 때 로그인 프로필을 특정해 재시도하는 절차의 정본이다. 이 실패는 원격 asset 미생성이 확실한 `FAILED(PREUPLOAD)` 경로이므로([upload-and-reporting.md](upload-and-reporting.md) 4절), 아래 절차로 프로필을 특정한 뒤 같은 실행기로 재시도한다.

## 1. 도구의 탐색 모델 — 왜 auto가 실패하는가

gh-attach v0.3.0 (rev `b138347`) 소스에서 확인한 동작 계약이다. 도구를 업그레이드하면 아래 재검증 명령으로 계약이 유지되는지 확인한다.

- 매칭 로직: 브라우저 쿠키의 `dotcom_user` 값이 `gh` CLI 로그인 계정과 일치하는 세션을 찾는다 (`internal/attach/cookie_resolver.go`). 따라서 "GitHub에 로그인된 프로필"의 판정 기준 쿠키는 `dotcom_user`다.
- auto 모드는 브라우저 목록만 순회하고 프로필은 열거하지 않는다 (`internal/cookies/source.go`의 `ExpandSource`). 프로필 미지정 Chromium 계열에는 `"Default"` 프로필이 고정 적용된다 (`ApplyDefaultProfile`).
- 귀결: 멀티 프로필 환경에서 `Default`가 아닌 프로필에만 GitHub 로그인이 있으면 auto 탐색은 구조적으로 실패한다. `failed to resolve usable cookie source from N attempt(s)`는 "로그인이 없다"가 아니라 "로그인된 프로필이 시도되지 않았다"일 수 있다. `--browser <이름>`만 지정한 재시도도 같은 이유로 실패한다 — 프로필 지정 없이는 여전히 `Default`만 본다.

재검증 (auto 탐색 계약은 `source.go`, `dotcom_user` 매칭 계약은 `cookie_resolver.go`):

```bash
gh api "repos/greenheadHQ/gh-attach/contents/internal/cookies/source.go?ref=<rev>" -q '.content' | base64 -d
gh api "repos/greenheadHQ/gh-attach/contents/internal/attach/cookie_resolver.go?ref=<rev>" -q '.content' | base64 -d
```

## 2. 진단·재시도 순서

1. 같은 실행기·같은 인자에 `--verbose`만 더해 재실행한다. `source[N]: browser=… profile=… provider=… error=…` 라인이 어떤 브라우저·프로필이 시도됐고 왜 탈락했는지 알려준다. `skipped (dotcom_user missing)`은 쿠키는 있으나 로그인 흔적이 없는 프로필, `skipped (dotcom_user=… != gh_login=…)`은 다른 계정으로 로그인된 프로필, `selected source: …`가 매칭 성공이다.
2. verbose가 `Default` 프로필 실패만 보여주면 3절 경계 안에서 4절 레시피로 프로필을 열거해 후보를 압축한다.
3. `--browser <이름> --profile "<프로필 디렉터리명>"`으로 재시도한다 (`--verbose` 유지). 후보가 여럿이면 도구의 `dotcom_user` 대조가 오매칭을 걸러주므로 순서대로 시도해도 안전하다.
4. 성공한 프로필은 5절대로 `attach.yml`에 지속화해 재탐색을 없앤다.

## 3. 프로필 조사의 자율 경계

자동 탐색 실패 시 아래 메타데이터 한정 조사는 사용자 승인 없이 자율 수행한다. 조사 범위는 최종 보고에 명시한다.

허용 (메타데이터):

- 프로필 디렉터리 목록과 각 프로필의 표시 이름 매핑 조회
- 쿠키 store에서 특정 host의 쿠키 개수와 쿠키 이름의 존재 여부 조회 (`dotcom_user` 존재 확인)

금지 (내용):

- 쿠키 `value`·`encrypted_value` 컬럼 조회, OS keystore 복호화 시도
- 쿠키 DB·프로필 파일의 덤프·복사·반출
- 발견한 프로필 이름·경로를 게시물 본문이나 저장소에 박제 (세션 내 보고와 로컬 `attach.yml` 기록은 허용)

쿠키 값을 읽는 것은 도구(gh-attach)의 일이고, 이 절차의 몫은 후보 프로필을 좁히는 것까지다.

## 4. Chromium 계열 레시피 (macOS)

검증된 구체 절차는 Chrome 기준이다 (gh-attach의 쿠키 전제가 macOS 전용 — `modules/shared/programs/git/gh-attach-package.nix`의 `platforms` 선언 참조). 다른 Chromium 계열은 base 경로만 다르고, Firefox 등 비Chromium 브라우저는 이 레시피를 그대로 적용하지 말고 2절의 verbose 진단과 3절의 경계 원칙만 적용한다 — 미검증 절차를 추정으로 실행하지 않는다.

프로필 열거와 표시 이름 매핑 (`Local State`는 Chrome이 프로필 메타데이터를 담는 JSON이다):

```bash
python3 -c '
import json, os
base = os.path.expanduser("~/Library/Application Support/Google/Chrome")
info = json.load(open(os.path.join(base, "Local State")))["profile"]["info_cache"]
for key, v in sorted(info.items()):
    print(f"{key}\t{v.get(\"name\", \"?\")}")
'
```

`Default` 프로필이 목록에 없을 수 있다 — 그 환경이 바로 auto 탐색이 구조적으로 실패하는 환경이다.

프로필별 로그인 흔적 확인 (메타데이터만 — `name`·`host_key`는 평문 컬럼이고 값 컬럼은 조회하지 않는다):

```bash
DB="$HOME/Library/Application Support/Google/Chrome/<프로필 디렉터리명>/Cookies"
sqlite3 "file:$DB?immutable=1" \
  "select count(*) from cookies where host_key like '%github.com' and name='dotcom_user';"
```

`immutable=1`은 실행 중인 Chrome이 잠근 DB를 읽기 전용으로 열기 위한 것이며 쓰기 시도가 없음을 함께 보장한다. 결과가 `1` 이상인 프로필이 재시도 후보다.

## 5. attach.yml 지속화

성공한 프로필은 설정 파일에 기록해 이후 세션의 재탐색을 없앤다. 경로와 스키마는 v0.3.0 소스 `internal/config/config.go`에서 확인했다 (재검증은 1절과 같은 방식으로 해당 파일 조회).

- 경로: `$XDG_CONFIG_HOME/gh/attach.yml`, 미설정 시 `~/.config/gh/attach.yml`
- 스키마: `browsers` 배열, 항목 필드는 `browser`·`profile`·`cookie_store_path` (미사용 필드 생략 가능)

```yaml
browsers:
  - browser: chrome
    profile: "<확인된 프로필 디렉터리명>"
```

지속화 규칙:

- 재시도 성공으로 프로필이 확정되면 승인 없이 기록해도 된다. 단 기록·수정 사실과 내용을 최종 보고에 명시한다.
- 기존 `attach.yml`이 있으면 덮어쓰지 않고 파싱해 항목을 보존한 채 추가한다. 동일 항목이 이미 있으면 기록하지 않는다.
- 대상 경로가 symlink(선언적 dotfile 관리 등)이면 직접 쓰지 않고 사용자에게 선언 위치 반영을 안내한다.

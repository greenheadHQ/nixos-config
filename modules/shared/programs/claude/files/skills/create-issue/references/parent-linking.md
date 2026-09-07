# Parent 파싱과 sub-issue 연결

`--parent` 지정 시 이슈 생성 전에 파싱과 pre-check를 완료한다. 게시 성공 및 URL 검증 후에만 연결하며, 연결 실패만으로 이슈를 재생성하지 않는다.

## 용어 / 변수 계약

Sub-Issues API는 GitHub visible issue number와 database id를 서로 다른 위치에서 요구한다. parent는 REST path의 `{issue_number}`(= visible number)만 사용하고, child의 database id만 POST body의 `sub_issue_id`로 전달한다. `_NUM`과 `_ID`를 바꿔 쓰면 Sub-Issues API 호출이 404 또는 422로 실패한다.

| 변수 | 의미 | 예시 |
|------|------|------|
| `OWNER_REPO` | 현재 cwd의 GitHub repo canonical `nameWithOwner` (= `gh repo view --json nameWithOwner -q .nameWithOwner` 결과) | `greenheadHQ/nixos-config` |
| `OWNER` | `OWNER_REPO`에서 분리한 owner (case-preserved canonical 값) | `greenheadHQ` |
| `REPO` | `OWNER_REPO`에서 분리한 repo 이름 | `nixos-config` |
| `PARENT_NUM` | parent의 GitHub visible issue number (integer). REST path의 `{issue_number}` | `539` |
| `ISSUE_URL` | `gh issue create`가 반환하는 HTML URL | `https://github.com/OWNER/REPO/issues/540` |
| `ISSUE_NUM` | `ISSUE_URL`에서 추출한 child의 visible number | `540` |
| `ISSUE_ID` | 새로 생성된 child 이슈의 database id. Sub-Issues POST body의 `sub_issue_id` | `4313342653` |

### 공통 repo 컨텍스트 초기화 스니펫

Step 0(`--parent` pre-check)과 Step 5-B(sub-issue 연결) 양쪽에서 `OWNER_REPO`/`OWNER`/`REPO`를 필요로 한다. 두 위치 모두 아래 스니펫을 호출한다 — 기존 환경변수 오염을 막기 위해 항상 `gh repo view`로 재조회한다 (cwd 기준 canonical `nameWithOwner`). `gh repo view` 비용은 경미하고, ambient `OWNER_REPO`에 의존하면 다른 repo로 작업이 조용히 흘러갈 위험이 있다. resolution 규칙을 바꿀 경우 이 스니펫만 수정한다.

```bash
# ensure-repo-context — 항상 cwd 기준 재조회 (ambient env 오염 방지)
OWNER_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
OWNER="${OWNER_REPO%%/*}"
REPO="${OWNER_REPO##*/}"
```

### Step 0 — `--parent` 파싱 + pre-check (옵션 지정 시)

수신한 인자를 shell-like tokenize한 뒤 첫 standalone `--` 이전에 `--parent`, `--parent=<값>`, `—parent`, 또는 `—parent=<값>` 토큰이 있으면 Step 1 본문에 진입하기 전에 이 단계를 수행한다. 이 범위에 네 형태가 모두 없으면 이 단계를 건너뛰고 기존 동작을 유지한다.

파싱 규칙 (fail-closed):

- 토큰 스캔 순서: 수신한 인자를 왼쪽부터 shell-like tokenize 후 스캔한다. 첫 standalone `--` 토큰을 만나면 그 이후 토큰은 모두 옵션 검색 대상에서 제외하고 제목/본문으로 취급한다 (escape). 이 규칙은 아래 `--parent` 옵션 검색보다 먼저 적용된다.
- 옵션 검색 범위에서 U+2014 em dash `—`를 쓴 토큰이 정확히 `—parent`이거나 `—parent=<값>` 형식이면 `ERROR: —parent는 모바일 자동 치환 가능성이 있습니다. ASCII --parent를 사용하세요` 출력 후 `exit 1`. `foo—parent` 같은 부분 문자열, en dash `–parent`, 일반 산문은 감지하지 않는다.
- `--parent=<값>` 또는 `--parent <값>` 형식만 옵션으로 인식한다. 위치는 자유(standalone `--` 앞이라면 어디든).
- `--parent` 또는 `--parent=` 를 옵션 토큰으로 만난 뒤 값이 아래 값 패턴 중 어디에도 매칭되지 않거나 값이 없으면 `ERROR: --parent 값 누락 또는 유효하지 않음` 출력 후 `exit 1`. 사용자 오타로 인한 silent parent 연결 누락을 막기 위한 fail-closed 경계.
- `--parent` 옵션은 최대 1회만 허용한다. 2회 이상 발견되면 `ERROR: --parent 중복 지정` 출력 후 `exit 1`. first-wins/last-wins 해석 모호성 제거.

값 패턴 (둘 중 하나에만 매칭 허용):

1. 숫자: `^[0-9]+$` — `PARENT_NUM`으로 직접 사용.
2. anchored URL: `^https://github\.com/([^/]+)/([^/]+)/issues/([0-9]+)/?([?#].*)?$`
   - suffix는 선택적 trailing slash(`/?`)와 query/fragment(`[?#].*`)만 허용한다. `/issues/539/evil` 같은 추가 path segment는 거부된다.
   - owner/repo를 lowercase 정규화하여 `gh repo view --json nameWithOwner -q .nameWithOwner` 결과(lowercase 정규화)와 비교한다. 불일치 시 `"ERROR: cross-repo sub-issue는 미지원"` 출력 후 `exit 1`.
   - GitHub owner/repo는 case-insensitive이므로 raw 비교 금지.
   - `.git`, 추가 slash 경로, percent-encoding이 섞인 비정상 입력은 URL regex에 anchor가 있으므로 거부된다.
   - 매칭된 숫자 그룹을 `PARENT_NUM`으로 추출한다.

파싱 결과 표 (기준 알고리즘 재현용):

| 입력 인자 | `PARENT_NUM` | Step 1로 전달될 자유 텍스트 | 비고 |
|-------------------|--------------|-----------------------------|------|
| `"버그 제목"` | (unset) | `"버그 제목"` | 기존 동작 (Step 0 skip) |
| `"제목" --parent 539` | `539` | `"제목"` | 숫자 값 매칭 |
| `--parent=539 "제목"` | `539` | `"제목"` | `--parent=` 형식 |
| `"제목" --parent https://github.com/OWNER/REPO/issues/539` | `539` | `"제목"` | URL 값 매칭 (same-repo) |
| `--parent 539abc "제목"` | — | — | exit 1 (값 패턴 불일치, 오타 방지) |
| `"제목" --parent` | — | — | exit 1 (값 누락) |
| `--parent 539 --parent 540 "제목"` | — | — | exit 1 (중복 지정) |
| `—parent 539` | — | — | exit 1 (em dash 자동 치환 감지, ASCII `--parent` 안내) |
| `—parent=539` | — | — | exit 1 (em dash 자동 치환 감지, ASCII `--parent` 안내) |
| `-- "--parent 문서화 이슈"` | (unset) | `"--parent 문서화 이슈"` | escape로 literal 보존 |
| `"제목" -- --parent 539` | (unset) | `"제목" --parent 539` | standalone `--` 이후는 옵션 검색 제외 |
| `-- —parent 539` | (unset) | `—parent 539` | escape로 literal 보존, 옵션 검색 없음 |

Pre-check (존재 확인 + object shape 검증, PR 배제):

```bash
# 공통 repo 컨텍스트 초기화 스니펫 실행 (위 "공통 repo 컨텍스트 초기화 스니펫" 섹션 참조).

# GitHub REST GET /repos/{owner}/{repo}/issues/{n}은 PR도 issue object로 반환하며 pull_request 키로 식별된다.
# PR 번호를 parent로 지정하면 Sub-Issues POST 단계에서야 실패하므로, 여기서 사전 차단한다.
if ! PARENT_META=$(gh api "/repos/$OWNER/$REPO/issues/$PARENT_NUM" \
     --jq 'select((.number|type=="number") and (.id|type=="number") and (has("pull_request")|not)) | {number,state}') \
     || [ -z "$PARENT_META" ]; then
  echo "ERROR: parent #$PARENT_NUM 조회 실패, 이슈가 아님, 또는 PR 번호"
  exit 1
fi
```

성공 시 `PARENT_NUM`을 Step 5-B에서 재사용한다. parent가 `closed` 상태여도 차단하지 않는다 (v1 YAGNI 범위).

Step 0 완료 후, `--parent`/값 토큰을 제거한 나머지 자유 텍스트가 Step 1 본문의 title/description 경로로 흐른다.

#### Step 5-B — sub-issue 연결 (`--parent` 지정 시만)

`--parent` 미지정 시 이 단계를 완전히 건너뛴다. 지정 시 child의 database id를 조회한 뒤 Sub-Issues API로 parent에 연결한다. 실패는 fail-open(이슈 본체는 이미 생성됨) — 상세 진행/보고 규칙은 [publishing.md](publishing.md)의 진행 상태 매트릭스 참조. `SUBISSUE_STATUS` 토큰을 항상 출력해 운영자가 최종 응답에서 부분 실패를 인지할 수 있게 한다.

```bash
if [ -n "$PARENT_NUM" ]; then
  # 공통 repo 컨텍스트 초기화 스니펫 실행 (Step 0에서 호출됐어도 idempotent).
  ISSUE_NUM="${ISSUE_URL##*/}"

  # Branch 1: child database id 조회
  # Sub-Issues API는 visible issue number가 아니라 child의 database id(sub_issue_id)를 요구한다.
  # -q '.id'는 필드 부재 시 "null" 문자열을 반환할 수 있으므로 numeric 형식도 검증한다.
  ISSUE_ID=$(gh api "/repos/$OWNER/$REPO/issues/$ISSUE_NUM" -q '.id' 2>/dev/null || true)

  if [ -z "$ISSUE_ID" ] || ! [[ "$ISSUE_ID" =~ ^[0-9]+$ ]]; then
    # Branch 1 failure: child id 조회 실패 → POST 스킵
    echo "WARN: ISSUE_ID 조회 실패 — sub-issue 연결 스킵, 수동 재시도 필요"
    echo "SUBISSUE_STATUS=FAILED_ID_LOOKUP  # ISSUE_URL=$ISSUE_URL (이슈는 생성됨, parent 미연결)"
    echo "재시도 (ISSUE_ID 재조회 포함):"
    echo "  ISSUE_ID=\$(gh api /repos/$OWNER/$REPO/issues/$ISSUE_NUM -q .id)"
    echo "  gh api -X POST /repos/$OWNER/$REPO/issues/$PARENT_NUM/sub_issues -F sub_issue_id=\$ISSUE_ID"
  else
    # ISSUE_ID 확보됨 → Branch 2 또는 Branch 3 선택
    if gh api -X POST "/repos/$OWNER/$REPO/issues/$PARENT_NUM/sub_issues" \
         -F "sub_issue_id=$ISSUE_ID" >/dev/null; then
      # Branch 2: 연결 성공
      echo "SUBISSUE_STATUS=LINKED"
      echo "SUBISSUE_LINKED=#$ISSUE_NUM -> parent #$PARENT_NUM"
    else
      # Branch 3: Sub-Issues POST 실패
      rc=$?
      echo "WARN: sub-issue 연결 실패 (exit $rc)"
      echo "SUBISSUE_STATUS=FAILED_POST  # ISSUE_URL=$ISSUE_URL (이슈는 생성됨, parent 미연결)"
      echo "재시도: gh api -X POST /repos/$OWNER/$REPO/issues/$PARENT_NUM/sub_issues -F sub_issue_id=$ISSUE_ID"
    fi
  fi
fi
```

SUBISSUE_STATUS 값 (`--parent` 지정 시에만 출력): `LINKED` / `FAILED_ID_LOOKUP` / `FAILED_POST` (세부 의미는 [publishing.md](publishing.md)의 진행 상태 매트릭스 참조). 이 토큰이 출력된 경우 `/create-issue` 최종 응답에 반드시 포함해 운영자가 재시도 여부를 판단할 수 있게 한다. `--parent` 미지정 경로에서는 Step 5-B 자체가 실행되지 않으므로 토큰이 출력되지 않고 최종 응답에도 포함하지 않는다 — 별도 `SKIPPED_NO_PARENT` 토큰은 도입하지 않는다(단일 이슈 등록 경로의 기존 출력 형태 유지, YAGNI).

Epic/Umbrella 패턴 예시:
- `refactor(skills): X 단순화 (epic)`
- `feat(codex): Y 캠페인 (epic, Wave 1)`

Epic 제목에 자식 이슈 번호(`#A/#B/#C`)를 박지 않는다 — 자식 이슈가 close/rename되면 제목이 즉시 stale. 자식 관계는 GitHub Sub-Issues API(`gh api graphql ... addSubIssue`) 또는 children 등록 시 `--parent <NUM|URL>` 옵션으로 표현한다.

Umbrella를 사용할 때는 먼저 `/create-issue`로 umbrella를 등록한 뒤, 반환된 umbrella issue의 번호 또는 URL을 children 등록 시 `--parent <NUM|URL>`로 전달한다 (frontmatter argument-hint와 동일 표기). `/create-issue` 자체는 단일 등록만 수행한다 — 복수 이슈 순서 유도나 umbrella 선생성 판단은 이 스킬의 책임이 아니다.

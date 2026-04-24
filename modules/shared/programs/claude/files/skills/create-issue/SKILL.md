---
name: create-issue
argument-hint: "[issue title or description (optional)] [--parent <NUM|URL>]"
description: |
  Create a structured GitHub issue with auto-enriched labels.
  Trigger: '이슈 등록', '이슈 만들어', 'todo 등록', '버그 등록', '이슈 추가'.
  NOT for CIR/ADR (use documenting-intent). NOT for PR 본문 (use create-pr).
---

# 이슈 등록

`$ARGUMENTS`를 이슈 제목, 설명, 또는 작업 내용으로 수신한다.
텍스트가 제공되면 이슈 제목/설명으로 사용하고,
비어있으면 대화 컨텍스트에서 이슈 내용을 추출한다.

## 빠른 참조

| 항목 | 설명 |
|------|------|
| 입력 | 이슈 제목 또는 설명 (선택). 비어있으면 대화 컨텍스트에서 추출 |
| 출력 | 구조적 이슈 등록 + URL 반환 |
| 핵심 도구 | 코드베이스 검색, `gh` CLI |
| 범위 | 등록 전용. 조회/감사/라이프사이클은 `gh` CLI를 직접 사용 |

## 런타임 도구 매핑

이 스킬은 Claude Code 세션과 direct Codex 세션 모두에서 동작한다.
사용자에게 질문하는 행동은 런타임에 해당하는 도구로 수행한다.

| 행동 | Claude Code 세션 | Codex 세션 |
|------|------------------|------------|
| 사용자에게 질문 | `AskUserQuestion` 도구 | plain-text 번호 질문 |

본문에서 "질문 도구"는 위 표의 런타임별 실제 도구를 가리킨다.

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

Step 0(`--parent` pre-check)과 Step 5-B(sub-issue 연결) 양쪽에서 `OWNER_REPO`/`OWNER`/`REPO`를 필요로 한다. 두 위치 모두 아래 스니펫을 호출한다 — **기존 환경변수 오염을 막기 위해 항상 `gh repo view`로 재조회**한다 (cwd 기준 canonical `nameWithOwner`). `gh repo view` 비용은 경미하고, ambient `OWNER_REPO`에 의존하면 다른 repo로 작업이 조용히 흘러갈 위험이 있다. resolution 규칙을 바꿀 경우 이 스니펫만 수정한다.

```bash
# ensure-repo-context — 항상 cwd 기준 재조회 (ambient env 오염 방지)
OWNER_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
OWNER="${OWNER_REPO%%/*}"
REPO="${OWNER_REPO##*/}"
```

## 절차

### Step 0 — `--parent` 파싱 + pre-check (옵션 지정 시)

`$ARGUMENTS`가 `--parent` 또는 `--parent=<값>` 토큰을 포함하면 Step 1 본문에 진입하기 전에 이 단계를 수행한다. 두 토큰 모두 없으면 이 단계를 건너뛰고 기존 동작을 유지한다.

**파싱 규칙** (fail-closed):

- **토큰 스캔 순서**: `$ARGUMENTS`를 왼쪽부터 shell-like tokenize 후 스캔한다. 첫 standalone `--` 토큰을 만나면 **그 이후 토큰은 모두 옵션 검색 대상에서 제외**하고 제목/본문으로 취급한다 (escape). 이 규칙은 아래 `--parent` 옵션 검색보다 **먼저** 적용된다.
- `--parent=<값>` 또는 `--parent <값>` 형식만 옵션으로 인식한다. 위치는 자유(standalone `--` 앞이라면 어디든).
- `--parent` 또는 `--parent=` 를 옵션 토큰으로 만난 뒤 값이 아래 값 패턴 중 어디에도 매칭되지 않거나 값이 없으면 **`ERROR: --parent 값 누락 또는 유효하지 않음` 출력 후 `exit 1`**. 사용자 오타로 인한 silent parent 연결 누락을 막기 위한 fail-closed 경계.
- `--parent` 옵션은 **최대 1회**만 허용한다. 2회 이상 발견되면 **`ERROR: --parent 중복 지정` 출력 후 `exit 1`**. first-wins/last-wins 해석 모호성 제거.

**값 패턴** (둘 중 하나에만 매칭 허용):

1. 숫자: `^[0-9]+$` — `PARENT_NUM`으로 직접 사용.
2. anchored URL: `^https://github\.com/([^/]+)/([^/]+)/issues/([0-9]+)/?([?#].*)?$`
   - suffix는 선택적 trailing slash(`/?`)와 query/fragment(`[?#].*`)만 허용한다. `/issues/539/evil` 같은 추가 path segment는 거부된다.
   - owner/repo를 lowercase 정규화하여 `gh repo view --json nameWithOwner -q .nameWithOwner` 결과(lowercase 정규화)와 비교한다. 불일치 시 `"ERROR: cross-repo sub-issue는 미지원"` 출력 후 `exit 1`.
   - GitHub owner/repo는 case-insensitive이므로 raw 비교 금지.
   - `.git`, 추가 slash 경로, percent-encoding이 섞인 비정상 입력은 URL regex에 anchor가 있으므로 거부된다.
   - 매칭된 숫자 그룹을 `PARENT_NUM`으로 추출한다.

**파싱 결과 표** (기준 알고리즘 재현용):

| 입력 `$ARGUMENTS` | `PARENT_NUM` | Step 1로 전달될 자유 텍스트 | 비고 |
|-------------------|--------------|-----------------------------|------|
| `"버그 제목"` | (unset) | `"버그 제목"` | 기존 동작 (Step 0 skip) |
| `"제목" --parent 539` | `539` | `"제목"` | 숫자 값 매칭 |
| `--parent=539 "제목"` | `539` | `"제목"` | `--parent=` 형식 |
| `"제목" --parent https://github.com/OWNER/REPO/issues/539` | `539` | `"제목"` | URL 값 매칭 (same-repo) |
| `--parent 539abc "제목"` | — | — | exit 1 (값 패턴 불일치, 오타 방지) |
| `"제목" --parent` | — | — | exit 1 (값 누락) |
| `--parent 539 --parent 540 "제목"` | — | — | exit 1 (중복 지정) |
| `-- "--parent 문서화 이슈"` | (unset) | `"--parent 문서화 이슈"` | escape로 literal 보존 |
| `"제목" -- --parent 539` | (unset) | `"제목" --parent 539` | standalone `--` 이후는 옵션 검색 제외 |

**Pre-check** (존재 확인 + object shape 검증, PR 배제):

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

Step 0 완료 후 나머지 `$ARGUMENTS`(=`--parent`/값 토큰 제거 후의 자유 텍스트)가 Step 1 본문의 title/description 경로로 흐른다.

### Step 1 — 코드베이스 탐색

이슈 내용을 기반으로 관련 컨텍스트를 수집한다 (Summary A1/Context A2 작성에 필요). LLM 친화성 체크리스트 A 섹션 참조 ([../write-handoff/references/llm-friendly-checklist.md](../write-handoff/references/llm-friendly-checklist.md)).

- **(a) 관련 파일 탐색**: 이슈에 언급된 경로는 `Read`로, 모듈/키워드는 `Glob`/`Grep`으로 탐색.
  예: `Glob "**/*.nix"`, `Grep -n "<키워드>" modules/`, `find . -name "*.nix" -path "*<모듈>*"`.
- **(b) 관련 이슈 검색**: `gh issue list --search "<키워드>" --state all --limit 20`으로 중복/관련 이슈 확인.
- **(c) 관련 커밋 확인**: `git log --oneline -20 -- <관련 경로>` 또는 `git log --grep="<키워드>"`.

### Step 2 — 템플릿 작성

`references/issue-template.md`를 참조하여 이슈 본문을 작성한다.

**필수 섹션** (항상 작성):
- **Summary**: 1-2 문장으로 what + why 요약 (체크리스트 A1)
- **Context**: 현 상태 → 문제점 → 필요성 순으로 서술 (체크리스트 A2)
- **References**: 비자명 주장의 출처 링크 최소 1개 이상 (체크리스트 B1/B4). 공식 docs URL, repo 내부 파일 경로(`path/to/file.nix:LINE`), 관련 이슈/커밋(`#NNN`/`abc1234`). 근거 부재 시 `[UNVERIFIED]` 라벨로 대체.
- **Proposed Changes**: 체크박스(`- [ ]`) 형태의 구체적 변경 계획

**선택 섹션** (판단 기준에 따라 포함):
- **PoC / Reproduction**: 재현이 중요한 주장(버그 리포트 등)에 6필드 포함 — `환경 / 입력 / 절차 / 기대 결과 / 실제 결과 / 성공 기준` (체크리스트 C1)
- **Related Commits**: `$ARGUMENTS` 또는 대화 컨텍스트에 커밋 해시가 언급되었거나, Step 1(c)에서 직접 관련 커밋을 발견한 경우
- **Affected Files**: 변경 대상 파일이 여러 개인 경우 (테이블 형식)
- **Notes**: 추가 참고사항(제약사항, 관련 이슈 번호, YAGNI 판단 근거 등)이 있는 경우

### Step 3 — Anti-hallucination 자체 검증

작성된 이슈 본문에 체크리스트 E1/E2를 적용한다 (규칙 상세 정의와 출처는 [`../write-handoff/references/llm-friendly-checklist.md`](../write-handoff/references/llm-friendly-checklist.md) Normative E1/E2 참조).

- **E1**: 근거 없거나 확신 낮은 주장은 `[UNVERIFIED]` 라벨 또는 삭제 (라벨 체계 상세는 [체크리스트 라벨 체계](../write-handoff/references/llm-friendly-checklist.md#라벨-체계-anti-hallucination) 참조).
- **E2**: 비자명 주장을 검증 질문으로 변환 → `Read`/`Grep`/`gh` 재실행으로 독립 확인 → 불일치/근거 부재 시 라벨 또는 삭제.

### Step 4 — 라벨 자동 결정

`references/label-taxonomy.md`를 참조하여 라벨을 결정한다.

1. `gh label list`로 기존 area 라벨 목록을 조회한다.
2. 이슈 내용에서 적합한 area를 자동 매칭한다 (기존 area에서만 선택).
3. 매칭되는 area가 없으면 **area 없이 등록하고 사용자에게 알린다** (자동 생성 금지).
4. priority는 이슈 내용의 긴급도/영향도를 기반으로 자동 판단한다 (high/medium/low).
5. GitHub 기본 라벨(enhancement/bug/documentation 등)을 이슈 유형에 맞게 선택한다.

### Step 5 — 등록 및 확인

Step 5는 두 하위 단계로 진행한다. 진행/차단 규칙은 아래 매트릭스 하나로 통합한다 — 각 세부 단계의 실패 처리는 이 표를 참조한다.

**진행 상태 매트릭스**

| 상태 (Step 5 출력) | Step 5-B 진행 | Step 6 진행 | 사용자/운영자 보고 의무 |
|--------------------|---------------|-------------|--------------------------|
| Step 5-A `gh issue create` 실패 (`ERROR:` + `ISSUE_URL` 미반환) | 차단 | 차단 | 재시도 명령 출력 후 `exit 1` |
| Step 5-A URL validation 실패 (반환값이 `https://github.com/.../issues/N` 형식 아님) | 차단 | 차단 | `ERROR:` + 재시도 유도 |
| Step 5-A 성공 + `--parent` 미지정 | Skip (실행 안 됨) | 진행 | `ISSUE_URL`만 출력 (기존 경로, `SUBISSUE_STATUS` 토큰 없음) |
| Step 5-B `SUBISSUE_STATUS=LINKED` | — | 진행 | 성공 로그 |
| Step 5-B `SUBISSUE_STATUS=FAILED_ID_LOOKUP` | — | 진행 | `SUBISSUE_STATUS` 토큰을 최종 응답에 포함, 재시도 명령 명시 |
| Step 5-B `SUBISSUE_STATUS=FAILED_POST` | — | 진행 | 동일 |

`SUBISSUE_STATUS`의 전달 경로는 `/create-issue`의 **최종 응답(사용자에게 출력되는 마지막 메시지)** 에 명시하는 것으로 scope을 닫는다. `/write-handoff` 계약은 `[issue-number or URL]`만 받으므로 `SUBISSUE_STATUS`는 handoff body에 전달되지 않는다 — 운영자는 `/create-issue` 최종 응답의 토큰을 보고 재시도 여부를 판단한다.

#### Step 5-A — 이슈 등록

실패 시 진행 차단 정책은 위 진행 상태 매트릭스 참조.

1. 등록 전 **제목, 라벨 조합을 사용자에게 보여주고 확인**을 받는다.
2. 확인 후 `gh issue create`를 **`--body-file`로 실행**한다. 본문은 임시 파일에 저장 후 전달.
   ```bash
   # BSD/macOS mktemp는 템플릿 끝(trailing)에 XXXXXX가 와야 랜덤 치환함.
   # 확장자 없이 랜덤 파일 생성 — gh issue create --body-file은 확장자 무관.
   umask 077
   ISSUE_BODY=$(mktemp -t issue-body.XXXXXX) || { echo "ERROR: mktemp 실패"; exit 1; }
   # <작성된 본문>을 $ISSUE_BODY에 기록 (Write 도구)

   # gh issue create — 성공 시 URL 캡처, 실패 시 본문 경로/미리보기 출력 후 exit 1
   if ISSUE_URL=$(gh issue create --title "<제목>" --label "<라벨>" --body-file "$ISSUE_BODY"); then
     echo "ISSUE_URL=$ISSUE_URL"
     rm -f "$ISSUE_BODY"
   else
     rc=$?
     echo "ERROR: gh issue create 실패 (exit $rc)"
     echo "ISSUE_BODY_PATH=$ISSUE_BODY  # 본문 보존됨 (재시도 시 재사용)"
     # 본문은 stdout으로 덤프하지 않는다 — 사용자가 실수로 시크릿을 포함한 경우 세션/운영 로그에 남을 위험.
     # 필요 시 로컬 shell에서 직접 확인: `sed -n '1,20p' "$ISSUE_BODY_PATH"` 또는 에디터로 열기.
     echo "본문 미리보기는 보안상 stdout 덤프하지 않음. 확인 명령: sed -n '1,20p' \"\$ISSUE_BODY_PATH\""
     echo "재시도 명령 (동일 shell 세션 또는 ISSUE_BODY_PATH 값을 직접 입력):"
     echo "  gh issue create --title '<제목>' --label '<라벨>' --body-file \"\$ISSUE_BODY_PATH\""
     echo "**Step 5-B와 Step 6은 이슈 등록 완료 전에는 진행하지 않는다.**"
     exit 1
   fi
   ```
3. 반환된 `ISSUE_URL`이 실제 GitHub URL(`https://github.com/.../issues/N`)인지 확인한다. 형식 불일치는 매트릭스의 "URL validation 실패" 행을 따른다.

#### Step 5-B — sub-issue 연결 (`--parent` 지정 시만)

`--parent` 미지정 시 이 단계를 완전히 건너뛴다. 지정 시 child의 database id를 조회한 뒤 Sub-Issues API로 parent에 연결한다. 실패는 fail-open(이슈 본체는 이미 생성됨) — 상세 진행/보고 규칙은 위 매트릭스 참조. `SUBISSUE_STATUS` 토큰을 항상 출력해 운영자가 최종 응답에서 부분 실패를 인지할 수 있게 한다.

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

**SUBISSUE_STATUS 값 (`--parent` 지정 시에만 출력)**: `LINKED` / `FAILED_ID_LOOKUP` / `FAILED_POST` (세부 의미는 위 Step 5 매트릭스 참조). 이 토큰이 출력된 경우 `/create-issue` 최종 응답에 반드시 포함해 운영자가 재시도 여부를 판단할 수 있게 한다. `--parent` 미지정 경로에서는 Step 5-B 자체가 실행되지 않으므로 토큰이 출력되지 않고 최종 응답에도 포함하지 않는다 — 별도 `SKIPPED_NO_PARENT` 토큰은 도입하지 않는다(단일 이슈 등록 경로의 기존 출력 형태 유지, YAGNI).

### Step 6 — LLM 이행 가이드 연계

**진입 가드**: 위 Step 5 진행 상태 매트릭스의 "Step 6 진행" 열을 따른다. 요약하면 Step 5-A 실패(create 실패 또는 URL validation 실패)는 Step 6 차단, Step 5-B `SUBISSUE_STATUS` 부분 실패는 Step 6 진행 허용. 존재하지 않는 이슈 번호로 `/write-handoff`를 호출하면 handoff comment가 엉뚱한 곳에 게시되거나 오류로 중단되므로 전자의 차단이 필수다.

**호출 맥락 확인**: plan-with-questions에서 호출된 경우(Step I-5), 이 Step을 건너뛴다.
(plan-with-questions Step I-6에서 통합 선택지로 제안하므로 중복 방지.)

이슈 생성이 완료되면, 질문 도구로 사용자에게 묻는다:

"LLM 이행 가이드를 작성할까요?"

- 사용자가 승인 → `/write-handoff <생성된 ISSUE_URL>` 스킬을 실행한다 (bare 번호 대신 Step 5의 `ISSUE_URL`을 전달해 write-handoff 헬퍼의 cwd 의존성을 회피한다, #486).
- 사용자가 거부 → 이슈 URL 반환 후 종료한다.

## Title Conventions

| Prefix | Use |
|--------|-----|
| `feat:` | 새 기능, 개선 |
| `fix:` | 버그 수정 |
| `refactor:` | 구조 변경 (동작 불변) |
| `test:` | 테스트 추가/수정 |
| `docs:` | 문서 |
| `chore:` | 기타 유지보수 |

**Epic/Umbrella 패턴 예시**:
- `refactor(skills): X 단순화 (epic, #A/#B/#C)`
- `feat(codex): Y 캠페인 (epic, Wave 1)`

Umbrella를 사용할 때는 먼저 `/create-issue`로 umbrella를 등록한 뒤, 반환된 umbrella issue의 번호 또는 URL을 children 등록 시 `--parent <NUM|URL>`로 전달한다 (frontmatter argument-hint와 동일 표기). `/create-issue` 자체는 단일 등록만 수행한다 — 복수 이슈 순서 유도나 umbrella 선생성 판단은 이 스킬의 책임이 아니다.

## 주의사항

- 이슈 본문에 시크릿/credential/API 키를 포함하지 않는다. `.age` 복호화 값, `.env` 내용은 파일 경로만 참조한다.
- 조회(`gh issue list`), 감사(audit), 라이프사이클(close/reopen/edit), 라벨 관리(CRUD)는 이 스킬의 범위 밖이다. `gh` CLI를 직접 사용한다.
- `gh issue create` 실행 시 본문은 **`--body-file`로 전달**한다. HEREDOC(`$(cat <<'EOF' ... EOF)`) 방식은 본문 내부에 PoC/Reproduction 섹션의 nested `cat <<'EOF'` 예시나 독립 `EOF` 라인이 포함될 때 outer heredoc가 조기 종료되어 등록이 실패하거나 본문이 잘린다. `PoC / Reproduction` 섹션(issue-template)의 shell 재현 스니펫이 기본 기능이므로 HEREDOC 전달은 금지.
## 참조 자료

- **[references/issue-template.md](references/issue-template.md)** -- 이슈 템플릿 (필수 섹션: Summary/Context/References/Proposed Changes + 선택 섹션: PoC/Related Commits/Affected Files/Notes) + 섹션별 작성 가이드 + 작성 예시
- **[references/label-taxonomy.md](references/label-taxonomy.md)** -- 라벨 체계 상세 (색상 코드, 판단 기준, 설계 근거)
- **[LLM 친화성 체크리스트](../write-handoff/references/llm-friendly-checklist.md)** -- `create-issue`/`write-handoff` 공유. Normative(스킬 강제) + Informational(권장) 분리. 라벨 체계(`[UNVERIFIED]`/`[INFERRED]`/`[CONFLICTING]`). 공식 docs/학술 출처 링크 포함

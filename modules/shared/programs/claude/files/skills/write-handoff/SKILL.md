---
name: write-handoff
argument-hint: "[issue-number or URL]"
description: |
  Write LLM migration guide comment on GitHub issue.
  Trigger: 'LLM 이행', '이행 가이드', '인수인계', '세션 인수인계', 'write-handoff', 'handoff'.
  NOT for PR 본문 (use create-pr). NOT for 이슈 생성 (use create-issue).
---

# LLM 이행 가이드 작성

`$ARGUMENTS`로 이슈 번호(예: `#123`, `123`) 또는 이슈 URL을 수신한다.
해당 이슈를 분석하여 LLM이 자율적으로 처음부터 끝까지 작업을 수행할 수 있는
Phase 기반 이행 가이드를 작성하고, 이슈 코멘트로 게시한다.

## 빠른 참조

| 항목 | 위치 |
|------|------|
| 이행 가이드 마크다운 템플릿 | [references/guide-template.md](references/guide-template.md) |

## 런타임 도구 매핑

이 스킬은 Claude Code 세션과 direct Codex 세션 모두에서 동작한다.
아래 행동은 런타임에 해당하는 도구로 수행한다.

| 행동 | Claude Code 세션 | Codex 세션 |
|------|------------------|------------|
| 사용자에게 질문 | `AskUserQuestion` 도구 | `request_user_input` |
| helper 스크립트 경로 | `~/.claude/scripts/write-handoff-repo-and-issue.sh` | `~/.codex/scripts/write-handoff-repo-and-issue.sh` |

본문의 "질문 도구"는 위 표의 런타임별 질문 도구를 가리킨다.
helper 스크립트는 양 런타임에서 동일 source를 공유한다 (Home Manager로 각 경로에 프로비저닝).

**프로비저닝 전제**: 위 helper 경로는 `nrs` (`nixos-rebuild`/`darwin-rebuild` 래퍼)로 Home Manager symlink가 생성된 후에만 유효하다. repo 코드를 `git pull`했지만 `nrs`를 아직 실행하지 않은 환경에서는 새 helper 경로가 존재하지 않을 수 있다. 그 경우 (1) `nrs` 실행 후 재시도하거나, (2) legacy 경로 `~/.{claude,codex}/scripts/write-handoff-repo-slug.sh`(이미 프로비저닝된 shim이 자기완결 fallback 포함)를 임시 호출한다. legacy 경로는 slug 1-line만 반환하므로 ISSUE_NUM은 별도 파싱 필요. **단, 이 임시 경로는 ERR_ 진단 코드 출력을 보장하지 않는다 — 새 helper가 프로비저닝된 환경에서 shim이 새 helper로 위임할 때만 stderr ERR_가 통과하며, 새 helper가 부재할 때 동작하는 legacy의 inline fallback은 stderr를 그대로 버린다. 진단성이 필요하면 `nrs` 실행 후 새 helper 경로로 재시도하라.**

## Handoff branch convention

NSS 블록이 재개 시 자동 `git switch`할 작업 branch 규약. 이 섹션이 **단일 진실 원천**이며 `references/guide-template.md`와 `references/llm-friendly-checklist.md`는 이 섹션을 참조한다.

- **규약**: `issue/{N}`. N은 GitHub 이슈 번호.
- **근거**: 이 스킬이 프로비저닝되는 환경(nixos-config)의 dominant convention.
- **기본값이며 강제 규약이 아니다**. 서술형 branch(`feat/*`, `fix/*`, `refactor/*` 등)도 여전히 유효한 선택.
- **Shared skill에 repo convention을 박은 이유 (수용된 trade-off)**: `write-handoff`는 `modules/shared/` 경로로 프로비저닝되지만 실질적 소비자는 이 프로젝트 단일 repo이고, `issue/{N}`이 merged PR의 지배적 convention이다. convention을 별도 override 레이어로 분리하면 caller가 항상 값을 전달해야 하는 간접층이 생기고, 단일 repo 환경에서는 그 추상화가 소비 없이 비용만 발생한다. 다른 규약을 쓰는 repo에서 이 스킬을 소비할 필요가 생기면 그 시점에 configuration 인터페이스를 도입한다 (NGMI 지적은 기각 — YAGNI 우선).
- **NSS 동작**:
  1. `git ls-remote --exit-code --heads origin "issue/{N}"`로 remote 존재 판정 (exit 0=present, 2=absent, 기타=transport error → fail-closed).
  2. present 이면 `git fetch origin "refs/heads/issue/{N}:refs/remotes/origin/issue/{N}"`로 explicit refspec fetch하여 remote-tracking ref를 materialize한다 (`git fetch origin "issue/{N}"` 성공만으로 존재 증거로 취급하지 않는다).
  3. local branch가 없으면 `git switch -c "issue/{N}" "refs/remotes/origin/issue/{N}"`로 local 생성 + checkout (single-branch clone 호환).
  4. local branch가 있으면 먼저 `git switch "issue/{N}"` 후 dirty/ahead/diverged 상태를 검사하여 자동 reset하지 않는다. clean+behind 상태에서만 `git merge --ff-only "origin/issue/{N}"` 허용.
  5. remote/local 모두 부재 시 서술형 branch로 작업된 케이스로 간주하여 `git log --all --grep='#{N}'` 힌트를 출력하고 `exit 1` (fail-closed). 사용자가 수동으로 작업 branch 결정.
- **실패 경로**: `||` 에러 블록이 `ERROR: handoff restore failed. REPO=... ISSUE_NUM=...`를 출력하여 재시도 안내. main/master 등 기본 branch 자동 복귀는 하지 않는다 (silent wrong-branch resume 방지).
- **Fail-fast 메커니즘**: NSS는 `set -e` 대신 실패 시 중단해야 하는 필수 명령에 명시적 `|| exit 1`을 부착하고, `ls-remote`/`show-ref`처럼 exit code가 상태 판정인 probe 명령은 `if`/`case`로 처리한다. POSIX 규정상 `set -e`는 AND-OR list의 비최종 위치(`( ... ) || { ... }` 문맥 포함)에서 억제되어, 서브쉘이 OR 좌변일 때 fail-fast가 동작하지 않는다. 근거: [POSIX Shell Command Language — set](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#set), [Bash Manual — The Set Builtin](https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html), [BashFAQ 105](http://mywiki.wooledge.org/BashFAQ/105).

**cross-repo linked branch/PR 제한** (`[UNVERIFIED]` 현재 미지원): GitHub는 issue를 다른 repository의 branch/PR과 연결할 수 있다 ([linked branch 문서](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/creating-a-branch-for-an-issue), [linked PR 문서](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue)). 이 스킬은 `$REPO`를 handoff 대상 repo로 고정하므로, 작업 branch가 다른 repo에 있으면 자동 복구가 wrong repo를 clone/fetch한다. 해당 시나리오는 사용자가 이슈 본문 또는 확답으로 명시하면 수동 처리한다.

NSS 템플릿 구현 상세는 `references/guide-template.md` 참조.

## 가이드 구조

이행 가이드는 다음 섹션으로 구성한다.

| # | 섹션 | 역할 |
|---|------|------|
| 0 | **TL;DR 블록** | 상황/현재 상태/다음 액션/Blockers — 새 세션 LLM이 가이드 상단에서 전체 맥락 파악 (primacy bias) |
| 1 | 헤더 블록 | 대상/목표/예상소요/난이도 — 한눈에 파악 가능한 메타 정보 |
| 2 | 핵심 원칙 | 행동 제약 1-3개 — 작업 전체에 적용되는 불변 규칙 |
| 3 | Phase 1: 사전 확인 | CLI/파일시스템에서 현재 값 확인 (병렬 가능 힌트 포함) |
| 4 | Phase 2: 실행 | BEFORE/AFTER 치환 또는 상세 변경 지시 |
| 5 | Phase 3: 검증 + 커밋 | 빌드 확인 + git add/commit 템플릿 |
| 6 | 주의사항 | 환경 분기, 대체 행동, 예외 처리 |
| 7 | **Next Session Starter 블록** | 다음 세션 LLM이 바로 실행할 명령어/재개 지점 (recency bias) |

복잡도에 따라 Phase 수가 3-6개로 조정된다. 상세 템플릿은 [references/guide-template.md](references/guide-template.md) 참조.

템플릿 상단의 **TL;DR 블록** (상황/현재 상태/다음 액션/Blockers)과 말미의 **Next Session Starter 블록** (재개 지점)은 `references/guide-template.md`에서 정의한다. primacy/recency bias를 활용하여 새 세션 LLM의 맥락 파악 속도를 높인다 (출처: [Lost in the Middle (TACL 2024)](https://direct.mit.edu/tacl/article/doi/10.1162/tacl_a_00638/119630/Lost-in-the-Middle-How-Language-Models-Use-Long)).

## 절차

### Step 1: 이슈 내용 읽기 + 컨텍스트 확보

**1-A. 이슈 읽기**

`$ARGUMENTS`가 비어있으면 런타임 도구 매핑 표의 질문 도구로 이슈 번호 또는 URL을 요청한다.
`$ARGUMENTS`에서 이슈 번호 또는 URL을 파싱한다.

```bash
# 이슈 번호인 경우
gh issue view <number> --json title,body,labels,assignees,comments

# URL인 경우
gh issue view <url> --json title,body,labels,assignees,comments
```

이슈 본문, 라벨, 기존 코멘트를 분석하여 작업 범위를 파악한다.

**1-B. Repo slug + 이슈 번호 확보 (필수)**

LLM이 helper 스크립트를 직접 호출한다. 런타임 도구 매핑 표의 helper 경로를 사용한다. helper는 REPO slug와 ISSUE_NUM을 각각 한 줄씩 개행 구분으로 출력한다 (실제 출력 계약은 script source 상단 주석 참조). 둘 중 하나가 빈 줄일 수 있다.

```bash
# Claude Code 세션 — stderr 진단 코드를 함께 캡처하려면 다음 패턴을 사용한다
TMP_ERR=$(mktemp)
trap 'rm -f "$TMP_ERR"' EXIT
HELPER_OUT=$(~/.claude/scripts/write-handoff-repo-and-issue.sh "$ARGUMENTS" 2>"$TMP_ERR")
HELPER_ERR=$(cat "$TMP_ERR")
REPO_SLUG=$(printf '%s\n' "$HELPER_OUT" | sed -n '1p')
ISSUE_NUM=$(printf '%s\n' "$HELPER_OUT" | sed -n '2p')

# Codex 세션은 ~/.codex/scripts/write-handoff-repo-and-issue.sh 경로를 사용한다.
# 출력 예:
#   stdout: greenheadHQ/nixos-config\n534
#   stderr: (정상) 빈 줄 / (실패) ERR_NOT_FOUND 등 한 줄 (Step 1-C 표 참조)
```

우선순위 (helper 내부, fail-closed):
1. **이슈 인자가 있으면**: `gh issue view "$issue_arg" --json url,number`로 URL + number 동시 파싱. 실패 시 **두 값 모두 빈 줄 반환 (cwd fallback 하지 않음)**.
2. **이슈 인자가 없으면**: cwd repo의 `gh repo view --json nameWithOwner` (REPO만; ISSUE_NUM은 빈 줄).
3. 결과에서 REPO 또는 ISSUE_NUM이 빈 줄이면 → 아래 **1-C. 값 확보 실패 / 유효성 검사 처리**.

두 값은 NSS placeholder 치환(`<REPO_SLUG>`, `<ISSUE_NUM>`)에 그대로 사용된다. Step 1-A의 `$ARGUMENTS` 원형은 이슈 본문 읽기에만 쓰고, NSS 주입에는 helper 출력을 쓴다 (입력 해석 경로 단일화).

**주의 (bare 번호 입력 시 cwd 의존)**: `$ARGUMENTS`가 `123`, `#123` 같은 bare 번호일 때 `gh issue view 123`은 **cwd repo의 이슈로 해석**된다. cwd가 handoff 대상 repo와 다르면 **전혀 다른 이슈**를 resolve하여 잘못된 repo slug + 이슈 번호를 placeholder 검증을 통과하는 형태로 반환할 수 있다. `gh issue view --json`은 `repository` 필드를 지원하지 않으므로 이 모호성을 helper 내부에서 제거할 방법이 없다. bare 번호 입력 시 LLM은:

1. `gh repo view --json nameWithOwner -q .nameWithOwner`로 현재 cwd repo를 확인한다.
2. 작업 맥락(이슈 본문의 파일 경로, 사용자 요청 등)을 살펴 cwd가 handoff 대상 repo와 일치하는지 판단한다.
3. 확신이 없으면 런타임 도구 매핑 표의 질문 도구로 **이슈 URL**(full `https://github.com/owner/repo/issues/N` 형태)을 사용자에게 명시적으로 확답받고, helper를 해당 URL 인자로 재실행하여 두 값 모두 재확보한다. repo slug 단독은 `gh issue view`의 허용 입력이 아니므로 helper 재실행에 쓸 수 없다.

bare 번호 + cwd 불일치 조합은 Step 1-C 실패 처리 대상이다.

**1-C. 값 확보 실패 / 유효성 검사 처리**

helper의 stderr (`HELPER_ERR`)에 `ERR_<CODE>` 한 줄이 있으면 다음 표에 따라 복구 경로를 분기한다.

| `ERR_` 코드 | 의미 | 복구 |
|---|---|---|
| `ERR_AUTH` | gh auth 미인증 / 토큰 무효 | 사용자에게 `gh auth login` 안내 후 중단 |
| `ERR_NETWORK` | 네트워크 오류 | 한 번 재시도. 여전히 실패 시 사용자 보고 |
| `ERR_NOT_FOUND` | 이슈/repo 미존재 | 질문 도구로 이슈 URL/번호 재확인 |
| `ERR_URL_PARSE` | gh 성공했으나 URL 파싱 실패 | GitHub URL 형식 확인 요청 |
| `ERR_NO_CWD_REPO` | cwd가 git repo 밖 (인자 없는 호출) | 이슈 인자 전달 또는 올바른 cwd로 이동 요청 |
| `ERR_GH_UNKNOWN` | 분류 실패 | 코드(`ERR_GH_UNKNOWN`)만 사용자에게 보고한다. helper는 raw `gh` stderr를 의도적으로 emit하지 않는다(URL/credential/local path 누출 차단). 디버깅이 필요하면 사용자가 underlying gh 명령을 직접 실행해 stderr를 검사한다 (인자 있는 호출은 `gh issue view "$ARGUMENTS" --json url,number`, no-arg 호출은 `gh repo view --json nameWithOwner -q .nameWithOwner`). helper 자체를 재실행하면 raw stderr가 다시 `ERR_GH_UNKNOWN`으로 collapse되므로 디버그에 쓸 수 없다 |

위 표가 control flow의 단일 진실이다. 각 코드의 복구 액션은 표 항목에 한정되며 공통 후속 절차는 두지 않는다 — 서로 다른 복구 입력(URL/cwd 이동/재인증/네트워크 복구)을 한 절차로 묶지 않는다. 이슈 URL을 사용자에게 확답받아야 하는 경로(`ERR_NOT_FOUND`, `ERR_URL_PARSE`, `ERR_NO_CWD_REPO` 중 사용자가 URL을 모를 때)는 질문 도구로 URL을 받은 뒤 helper를 그 URL 인자로 재실행하면 된다 (repo slug 단독은 `gh issue view`의 허용 입력이 아니다).

**Invalid-output 케이스 (stderr가 비어 있고 출력이 비정상)**:
- 인자 있는 호출에서 `REPO_SLUG` 또는 `ISSUE_NUM`이 빈 문자열, `null` 리터럴 문자열, placeholder 형태(`<...>`)이면 helper 버그 가능성 — 그대로 사용자에게 보고한다.
- 인자 없는 호출(no-arg)에서는 `ISSUE_NUM` 빈 줄이 정상 계약이다 (cwd repo fallback은 REPO만 반환). 이 모드에서는 `REPO_SLUG`만 검증하고, 빈 줄이면 cwd 이동 또는 인자 전달을 사용자에게 요청한다.

**NSS 블록에 unresolved placeholder(`<REPO_SLUG>`, `<ISSUE_NUM>`, `<unknown-*>`, 빈 문자열)가 남은 상태로는 Step 9(게시)로 진행하지 않는다.** Step 8 self-verification에서 placeholder 잔존 여부를 재검증한다.

**Shell-안전성 가드 (필수)**: NSS 블록은 `REPO='...'` / `ISSUE_NUM='...'` 처럼 single-quoted literal로 값을 삽입하여 `$(...)`, 백틱, `$var` 해석을 차단한다. REPO 값에 **`'`(single quote)** 가 포함되면 single-quoted literal을 조기에 닫아 주변 명령을 오염시킬 수 있으므로 치환 즉시 게시를 중단하고 질문 도구로 사용자에게 escape 전략을 확답받는다. (ISSUE_NUM은 정수이므로 single quote가 포함될 수 없다. `$`/`"`/백틱은 single-quoted literal 내부에서는 리터럴로 처리되어 안전하다.)

Next Session Starter 블록 작성 시 위에서 확보한 REPO와 ISSUE_NUM 두 값을 실제 값으로 치환해 handoff 본문에 포함한다. `TARGET`은 NSS 내부에서 `"issue/$ISSUE_NUM"`로 자동 구성된다 ("Handoff branch convention" 섹션 참조). 예시 template의 repo slug(`greenheadHQ/nixos-config` 등) 하드코딩을 그대로 두지 않는다.

### Step 2: 복잡도 판단

이슈의 변경 규모와 범위를 판단하여 Phase 깊이를 결정한다.

| 복잡도 | Phase 수 | 세션 전략 | 판단 기준 | 예시 |
|--------|---------|----------|----------|------|
| 단순 | 3 | 단일 세션 ~10분 | 파일 1-2개, 값 치환 수준 | 버전 업데이트, 경로 변경, 상수 교체 |
| 중간 | 4 | 단일 세션 ~15분 | 파일 3-5개, 로직 수정 포함 | 옵션 추가, 조건분기 변경, 설정 구조 변경 |
| 복잡 | 6 | 다중 세션, Phase별 독립 프롬프트 | 파일 6개 이상, 아키텍처 수준 변경 | 대규모 리팩토링, 새 모듈 도입, 서비스 마이그레이션 |

복잡도 판단이 애매하면 한 단계 높게 잡는다 (과소 추정보다 과대 추정이 안전).

### Step 3: 변경 대상 추출

이슈에서 다음 정보를 추출한다:

- **변경 대상 파일**: 이슈에 명시된 파일 경로 + 코드베이스 탐색으로 발견한 관련 파일
- **변경 내용**: 각 파일에서 무엇을 어떻게 바꾸는지
- **검증 기준**: 변경이 올바르게 적용되었는지 확인하는 방법

코드베이스를 직접 탐색하여 이슈에 명시되지 않은 관련 파일(예: 상수 참조, 테스트, 설정)도 식별한다.

**탐색 도구 예시** (관련 파일/경로를 찾아 Phase 작성 시 B4 `path:LINE` citation에 활용):
- 셸 `find . -name "*.nix" -path "*<키워드>*"` 또는 그에 상당하는 검색 도구 — 파일 경로 검색
- 셸 `rg -n "<심볼>" <경로>` 또는 그에 상당하는 검색 도구 — import/상수/테스트 참조 발견
- `git log --oneline -20 -- <경로>` — 최근 변경 이력
- `git blame <파일>` — 라인별 맥락

관련 파일 누락 방지: `rg "<심볼>" modules/ libraries/ tests/` 또는 그에 상당하는 검색 도구로 repo 전체 재검색.

### Step 4: Phase별 가이드 작성

[references/guide-template.md](references/guide-template.md)의 템플릿에 따라 각 Phase를 작성한다.

**Phase 작성 원칙:**
- 각 Phase는 독립 실행 가능해야 한다 (이전 Phase의 출력에 의존하되, 맥락 공유 없이도 수행 가능).
- 명령어와 기대 결과를 코드블록으로 제공한다.
- BEFORE/AFTER 형식으로 치환 내용을 명시한다 (체크리스트 C3).
- **비자명한 주장에는 인라인 citation을 붙인다** (체크리스트 B1). 예: `Nix rebuild 경로는 main-agent-only [run-da/references/hardening-contract.md의 main-agent-only commands 항목 참조]`.
- **근거 없는 주장은 `[UNVERIFIED]` 라벨 또는 삭제** (체크리스트 E1; 라벨 체계 상세는 [체크리스트 라벨 체계](references/llm-friendly-checklist.md#라벨-체계-anti-hallucination) 참조).

### Step 5: "진실 원천 우선" 원칙 적용

이슈에 기재된 값을 맹신하지 않는다. 가이드의 Phase 1(사전 확인)에서 반드시 CLI/파일시스템에서 실제 현재 값을 확인하는 단계를 포함한다.

예시:
```
이슈에 "현재 버전은 1.2.3"이라고 적혀 있더라도,
Phase 1에서 `grep version <파일>`로 실제 값을 확인하라는 지시를 포함한다.
실제 값이 이슈와 다르면 실제 값을 기준으로 진행한다.
```

이 원칙은 이슈 작성 시점과 가이드 실행 시점 사이의 시간차를 보상한다.

### Step 6: 커밋 메시지 템플릿 사전 작성

가이드의 검증+커밋 Phase에 완전한 커밋 메시지 템플릿을 미리 작성하여 포함한다.

```
git commit -m "$(cat <<'EOF'
<type>(<scope>): <요약>

<상세 설명>

Closes #<이슈번호>
EOF
)"
```

LLM이 커밋 메시지를 자의적으로 작성하지 않고, 가이드에 명시된 템플릿을 사용하도록 한다.

### Step 7: DA 피드백 수행 지시 포함

가이드의 마지막 Phase 또는 주의사항에 DA 피드백 루프 수행을 권장하는 지시를 포함한다.

```
구현 완료 후, run-da 스킬(for_pr 모드)을 실행하여
코드 품질을 검증한 뒤 PR을 생성하라.
```

### Step 8: Self-verification 패스 (CoVe 경량)

게시 전 초안에 대해 Chain-of-Verification 경량판을 수행한다 (체크리스트 E2).
출처: [Chain-of-Verification (arXiv 2309.11495)](https://arxiv.org/abs/2309.11495), [Self-Alignment for Factuality (ACL 2024)](https://aclanthology.org/2024.acl-long.107/).

절차:
1. **Claim 추출**: 가이드 본문에서 비자명한 주장을 추출. 자명/trivial 사실 제외.
2. **검증 질문 재작성**: 각 claim을 검증 질문으로 변환. 예: `"파일 X에 Y 함수가 있다"` → `"실제 파일 X에 Y 함수가 있는가?"`
3. **독립 답변**: 초안을 보지 않은 상태로 파일 읽기·검색 도구 또는 `gh` CLI 재실행으로 질문에 답.
4. **불일치 처리**: 답변과 초안이 일치하지 않으면 초안 수정. 확인 불가 시 `[UNVERIFIED]` 라벨 또는 삭제.
5. **NSS placeholder 검증 (필수)**: Next Session Starter 블록의 REPO와 ISSUE_NUM이 다음 중 하나라도 해당하면 Step 1-C "값 확보 실패 처리" 순서로 실제 값 확보 후 치환. 치환 완료 전에는 Step 9(게시)로 진행하지 않는다.
    - `<...>` 형태 placeholder (`<REPO_SLUG>`, `<ISSUE_NUM>`, `<unknown-*>`, `<repo-root-path>` 등)
    - 빈 문자열
    - `null` 리터럴 문자열
    - **REPO 값이 Step 1-B helper 출력의 첫 줄(REPO)과 불일치**: 예시 template의 repo slug(`greenheadHQ/nixos-config` 등)가 남아 있고 실제 handoff 대상이 다른 repo인 경우. Step 1-B 첫 줄과 **문자열 비교하여 동일 여부 확인**. 다르면 반드시 치환.
    - **ISSUE_NUM 값이 정수가 아니거나 Step 1-B helper 출력의 둘째 줄(ISSUE_NUM)과 불일치**: 정수 검증(`[0-9]+`)과 Step 1-B 출력 일치 검증을 모두 수행. 다르면 치환.
6. **Shell-안전성 재검증 (필수)**: NSS 블록의 `REPO=` 할당이 **single-quoted literal(`'...'`)** 형태인지 확인하고, REPO 값에 `'`(single quote)이 포함되어 있으면 Step 9를 중단한다 (Step 1-C Shell-안전성 가드 참조). ISSUE_NUM은 정수이므로 single quote 위험이 원천 없다.

### Step 9: 이슈 코멘트로 게시

작성한 가이드를 이슈 코멘트로 게시한다. **`--body-file`만 허용**한다. 본문에는 `$HOME`, `$(...)`, 백틱, 큰따옴표, 내부 `EOF` 등 셸 해석 토큰이 포함될 수 있으며, 이번 스킬이 추가한 `Phase N 검증+커밋` 섹션 자체가 커밋 템플릿용 `cat <<'EOF'...EOF` 예시를 포함한다. 따라서 `$(cat <<'EOF' ... EOF)` 래퍼는 inner `EOF`에서 조기 종료되어 본문이 잘리거나 명령이 실행된다. `--body "<본문>"` 직접 전달과 quoted HEREDOC 모두 금지.

```bash
# 필수: 본문을 파일에 저장한 뒤 --body-file로 전달
gh issue comment <number> --body-file <path-to-guide.md>
```

참고: `gh issue comment --body-file -`로 stdin도 허용되지만, 생성된 가이드를 파일로 저장하는 워크플로가 디버깅·재실행에 유리하다.

## 복잡도별 분기

### 단순 (Phase 3)

| Phase | 내용 |
|-------|------|
| 1. 사전 확인 | 현재 값 확인 (1-2개 파일) |
| 2. 실행 | BEFORE/AFTER 치환 |
| 3. 검증 + 커밋 | grep 확인 + 커밋 |

단일 세션(~10분)으로 완료 가능. 가이드를 하나의 프롬프트로 전달한다.

### 중간 (Phase 4)

| Phase | 내용 |
|-------|------|
| 1. 사전 확인 | 현재 값 + 의존성 확인 |
| 2. 핵심 변경 | 주요 로직/설정 수정 |
| 3. 부수 변경 | 관련 파일 업데이트 |
| 4. 검증 + 커밋 | 빌드 + 기능 확인 + 커밋 |

단일 세션(~15분)으로 완료 가능. 가이드를 하나의 프롬프트로 전달한다.

### 복잡 (Phase 6)

| Phase | 내용 |
|-------|------|
| 1. 사전 확인 + 아키텍처 파악 | 현재 구조, 의존 관계, 영향 범위 분석 |
| 2. 기반 구조 변경 | 새 모듈/파일 생성, 인터페이스 정의 |
| 3. 핵심 로직 마이그레이션 | 기존 코드를 새 구조로 이전 |
| 4. 부수 코드 업데이트 | 참조, import, 설정 파일 갱신 |
| 5. 통합 검증 | 빌드 + 전체 기능 테스트 |
| 6. 정리 + 커밋 | old 아티팩트 제거 + 커밋 |

다중 세션 전략: 각 Phase를 `<details>` 접기로 제공하여 세션별로 독립 실행 가능하게 한다.

## 주의사항

- **복잡한 이슈의 세션 분리**: Phase 6인 복잡한 이슈는 각 Phase를 `<details>` 태그로 접어서 제공한다. LLM이 한 세션에서 하나의 Phase만 펼쳐 실행하고, 다음 세션에서 다음 Phase를 진행한다.
- **대안 선택 기준 명시**: 구현 방법에 대안이 있으면 각 대안의 장단점과 추천 선택지를 명시한다. LLM이 자의적으로 판단하지 않도록 한다.
- **환경별 분기 명시**: macOS/NixOS 분기, `ssh minipc` 필요 여부 등 환경에 따라 달라지는 행동을 명확히 기술한다.
- **QA 체인**: 스킬 관련 이슈의 기본 QA 체인은 `/run-da for_pr` + skill-creator 플러그인(evals/queries.json 검증)이다. `/parallel-audit`는 다중 스킬 영향·광범위 사이드이펙트·고위험 변경일 때만 조건부로 추가한다. 검증 축(frontmatter/구조/links/evals)은 유지하고 도구만 활성 경로로 교체한다.
- **병렬 힌트 제공**: 독립적으로 실행 가능한 명령에는 `(병렬 가능)` 힌트를 명시하여 LLM이 병렬 실행을 활용하도록 유도한다.
## 참조 자료

- **[references/guide-template.md](references/guide-template.md)** — LLM 이행 가이드 마크다운 템플릿 + TL;DR 블록 + Next Session Starter 블록 + 헤더 블록/Phase 구조/커밋 템플릿/QA 체크리스트 + 모범 패턴
- **[references/llm-friendly-checklist.md](references/llm-friendly-checklist.md)** — `create-issue`/`write-handoff` 공유 체크리스트. Normative(스킬 강제) + Informational(권장) 분리. 라벨 체계(`[UNVERIFIED]`/`[INFERRED]`/`[CONFLICTING]`)와 출처 링크

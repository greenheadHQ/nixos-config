# LLM 이행 가이드 마크다운 템플릿

## TL;DR 블록 (최상단)

가이드 최상단(헤더 블록보다 앞)에 4슬롯 TL;DR을 배치한다. 새 세션 LLM이 첫 화면에서 전체 맥락을 파악하도록 한다. 체크리스트 D1 참조.

````markdown
## TL;DR

- **상황**: <배경 + 지금까지의 맥락>
- **현재 상태**: <관련 파일 현황 (repo-relative), 남은 단계, 실패한 검증 결과 등 공개 안전 정보>
- **다음 액션**: <Phase 1부터 시작할 첫 명령어>
- **Blockers**: <있으면 명시, 없으면 "없음">
````

**작성 규칙**:
- 가이드 상단 10줄 이내에 배치 (primacy bias 활용).
- 4슬롯 모두 채운다. 해당 없으면 "없음" 명시.
- **공개 노출 주의**: 이 가이드는 `gh issue comment`로 GitHub에 게시된다. `현재 상태` 슬롯에 민감한 로컬 컨텍스트(`git status` 출력, 워크트리 dirty state, 개인 작업 경로)를 적지 않는다. 공개 안전 정보(repo-relative 파일 경로, 작업 단계, 검증 결과)만 기술.
- 출처: [Lost in the Middle (TACL 2024)](https://direct.mit.edu/tacl/article/doi/10.1162/tacl_a_00638/119630/Lost-in-the-Middle-How-Language-Models-Use-Long) — 장문에서 모델은 시작/끝 정보에 강하고 중간 정보 활용이 약함.

## 헤더 블록

blockquote 형태로 작업의 메타 정보를 한눈에 제공한다.

```markdown
> **대상**: <변경 대상 모듈/파일/서비스>
> **목표**: <이 가이드가 달성하는 최종 상태를 1문장으로>
> **예상 소요**: ~<N>분 (단일 세션 / 다중 세션)
> **난이도**: 단순 / 중간 / 복잡
> **관련 이슈**: #<N>
```

### 예시

```markdown
> **대상**: `modules/shared/programs/claude/files/skills/syncing-atuin/`
> **목표**: Atuin sync 스킬을 생성하여 shell history 동기화 절차를 자동화한다
> **예상 소요**: ~10분 (단일 세션)
> **난이도**: 단순
> **관련 이슈**: #252
```

## 핵심 원칙

작업 전체에 적용되는 불변 규칙을 1-3개로 기술한다.
LLM이 작업 중 판단이 필요할 때 참조하는 최상위 제약이다.

```markdown
## 핵심 원칙

1. **진실 원천 우선**: 이 가이드의 값보다 CLI/파일시스템에서 확인한 실제 값이 우선한다.
2. **기존 패턴 존중**: 코드베이스에 확립된 네이밍/구조 컨벤션을 따른다. 새 패턴을 도입하지 않는다.
3. **최소 변경 원칙**: 이슈에 명시된 범위만 변경한다. 인접 코드의 리팩토링은 하지 않는다.
```

## Phase 구조

### Phase 1: 사전 확인

CLI/파일시스템에서 현재 상태를 확인한다. 변경 전 기준선을 수립하는 Phase이다.

````markdown
## Phase 1: 사전 확인

다음 명령으로 현재 상태를 확인한다 (병렬 가능):

```bash
# 1. 현재 버전 확인
grep "version" modules/shared/programs/tool/default.nix

# 2. 관련 설정 확인
cat modules/shared/programs/tool/config.nix | head -20

# 3. 상수 참조 확인
grep "toolPath" libraries/constants.nix
```

**기대 결과**:
- `modules/shared/programs/tool/default.nix:15` 에 `version = "1.2.3"` (이슈 본문 line 42의 주장에 따라, 실제 값이 다르면 실제 값 기준으로 진행 — [이슈 #NNN](https://github.com/<owner>/<repo>/issues/NNN))
- `modules/shared/programs/tool/config.nix:8` 에 `enableFeature = false;` 존재
- `libraries/constants.nix:42` 에 `toolPath = "/old/path";` 존재
- `[UNVERIFIED]` `toolPath`가 다른 모듈에서 import되는지 여부는 구현 시점에 `grep -rn toolPath modules/` 로 실측 필요
````

**작성 규칙:**
- `(병렬 가능)` 힌트를 명시하여 LLM이 독립 명령을 동시 실행하도록 유도한다.
- 이슈에 기재된 값과 실제 값이 다를 수 있음을 명시한다 ("진실 원천 우선" 패턴).
- 기대 결과를 구체적으로 적어 LLM이 현재 상태와 비교할 수 있게 한다.

### Phase 2-N: 실행

BEFORE/AFTER 형식으로 변경 내용을 명시한다.

````markdown
## Phase 2: 실행

### 2-1. 버전 업데이트

**파일**: `modules/shared/programs/tool/default.nix:15` ([upstream v1.3.0 release notes](https://github.com/example/tool/releases/tag/v1.3.0) 근거)

BEFORE:
```nix
version = "1.2.3";
```

AFTER:
```nix
version = "1.3.0";
```

> `[UNVERIFIED]` v1.3.0에서 breaking change가 있는지 릴리스 노트 재확인 권장.

### 2-2. 설정 변경

**파일**: `modules/shared/programs/tool/config.nix`

BEFORE:
```nix
enableFeature = false;
```

AFTER:
```nix
enableFeature = true;
```
````

**작성 규칙:**
- BEFORE/AFTER 쌍을 반드시 제공한다. "version을 업데이트한다"같은 모호한 지시는 금지.
- 각 변경에 대상 파일 경로를 명시한다.
- 변경이 여러 파일에 걸치면 파일별로 소항목을 분리한다.

### 검증 + 커밋 Phase

변경 결과를 검증하고 커밋하는 최종 Phase이다.

````markdown
## Phase N: 검증 + 커밋

### 정적 검증

```bash
# 새 값 존재 확인 (병렬 가능)
grep -q 'version = "1.3.0"' modules/shared/programs/tool/default.nix
grep -q 'enableFeature = true' modules/shared/programs/tool/config.nix

# old 값 부재 확인 (병렬 가능)
! grep -q 'version = "1.2.3"' modules/shared/programs/tool/default.nix
! grep -q 'enableFeature = false' modules/shared/programs/tool/config.nix
```

### 빌드 검증

```bash
nrs
```

빌드가 성공하면 커밋한다.

### 커밋

```bash
git add modules/shared/programs/tool/default.nix modules/shared/programs/tool/config.nix
git commit -m "$(cat <<'EOF'
feat(tool): enable feature and bump to v1.3.0

- version: 1.2.3 → 1.3.0
- enableFeature: false → true

Closes #252
EOF
)"
```

### DA 피드백 (권장)

구현 완료 후, `/run-da for_pr` 스킬을 실행하여 코드 품질을 검증하고,
필요하면 `/parallel-audit`로 전수조사를 수행한 뒤 `/create-pr` 스킬로 PR을 생성한다.
````

## 커밋 메시지 템플릿

가이드에 포함하는 커밋 메시지는 완전한 형태로 사전 작성한다.

```text
git commit -m "$(cat <<'EOF'
<type>(<scope>): <요약>

<변경 내용 bullet points>

Closes #<이슈번호>
EOF
)"
```

- type: feat/fix/refactor/docs/chore 등 conventional commit 형식
- scope: 변경 대상 모듈명
- 요약: 50자 이내, 명령형 현재시제
- 변경 내용: BEFORE → AFTER 형태의 bullet points
- Closes: 관련 이슈 번호

## QA 감사 체크리스트 (스킬 관련 이슈용)

스킬 파일 변경 이슈의 경우, 가이드 마지막에 QA 체인을 포함한다.

```markdown
## QA 체크리스트

구현 완료 후 다음 순서로 검증한다:

1. **`/run-da for_pr`** — 변경 diff에 대해 독립 DA 에이전트 리뷰. SKILL.md 품질 기준 준수 확인:
   - frontmatter 유효성 (name, description, Triggers)
   - 본문 구조 (Purpose → 빠른참조 → 핵심절차 → 참조)
   - `references/` 링크 유효성
2. **skill-creator 플러그인**: `evals/queries.json` 검증
   - positive 10개 + negative 10개 충족
   - negative에 인접 스킬 트리거 포함
3. (선택) **`/parallel-audit`** — 다중 스킬 영향·광범위 사이드이펙트·고위험 변경일 때만 추가로 전수조사.
```

## Next Session Starter 블록 (최하단)

가이드 말미(QA 체크리스트 뒤)에 Next Session Starter를 배치한다. 다음 세션 LLM이 이 가이드만 읽고 즉시 작업을 시작할 수 있도록 재개 지점을 명시한다. 체크리스트 D2 참조.

````markdown
## Next Session Starter

- **이 가이드 읽고 바로 시작할 명령어** (복붙 즉시 실행 가능. 임의 cwd에서 실행해도 대상 repo로 복귀 + 실패 시 즉시 중단):
  ```bash
  # 작성자 LLM: 아래 두 placeholder를 write-handoff/SKILL.md Step 1-B(repo slug) / Step 1-C(branch)에서 확보한 값으로 치환
  # single-quoted literal로 emit하여 $(...), 백틱, $var 해석을 차단한다.
  # 값에 '(single quote) 또는 \가 포함되면 Step 9(게시)를 중단하고 사용자에게 확답받는다 (Step 1-D).
  REPO='<REPO_SLUG>'      # 예: acme/project (owner/name)
  BRANCH='<BRANCH_NAME>'  # 예: feat/foo (handoff 대상 branch)

  # 서브쉘 + set -e: 중간 명령 실패 시 즉시 중단하여 엉뚱한 cwd의 follow-up 명령 실행 방지
  (
    set -e
    TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)" || true
    CURRENT_REPO=""
    [ -n "$TOPLEVEL" ] && CURRENT_REPO="$(cd "$TOPLEVEL" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || true
    if [ "$CURRENT_REPO" = "$REPO" ]; then
      cd "$TOPLEVEL"
    else
      gh repo clone "$REPO" "${REPO##*/}"
      cd "${REPO##*/}"
    fi
    git fetch origin "$BRANCH"
    git checkout "$BRANCH"
    git status
    git log --oneline -3
  ) || { echo "ERROR: handoff restore failed. REPO=$REPO BRANCH=$BRANCH"; echo "수동으로 repo/branch 확보 후 재시도하세요."; }
  ```
  - **REPO와 BRANCH는 `write-handoff/SKILL.md` Step 1-B / Step 1-C에서 확보한 값으로 치환**한다. 확보 경로: repo slug는 `~/.claude/scripts/write-handoff-repo-slug.sh` 또는 `~/.codex/scripts/write-handoff-repo-slug.sh` 헬퍼를 LLM이 직접 호출(이슈 인자가 있으면 URL 파싱, 실패 시 빈 줄 반환 = fail-closed. 이슈 인자가 없을 때만 cwd `gh repo view --json nameWithOwner` fallback). branch는 `gh api graphql`로 `linkedBranches` 조회(1순위), 미확보 시 `closedByPullRequestsReferences`의 PR 번호로 `gh pr view --json headRefName` 호출(2순위), 최종 미확보 시 런타임 도구 매핑 표의 질문 도구로 사용자 확답. `gh issue view --json`은 `repository`/`linkedBranches` 필드를 지원하지 않으므로 절대 `gh issue view --json repository` 또는 `gh issue view --json linkedBranches`로 대체하지 않는다. 작성자 LLM은 placeholder(`<REPO_SLUG>`, `<BRANCH_NAME>`)를 그대로 두지 않고 확보된 값으로 치환한다. 특정 repo slug(`greenheadHQ/nixos-config` 등)을 예시로 하드코딩하지 않는다 — 다른 repo handoff에서 엉뚱한 clone을 유발한다.
  - **게시 전 placeholder 검증 필수**: Step 8 Self-verification 5번 항목에서 다음 중 하나라도 남아 있으면 게시 금지.
    - `<...>` 형태 placeholder (`<REPO_SLUG>`, `<BRANCH_NAME>`, `<unknown-*>` 등)
    - 빈 문자열
    - `null` 리터럴 문자열
    - 실제 handoff 대상과 다른 기본 branch(`main`/`master`)
    - 이 template의 예시 repo slug(`greenheadHQ/nixos-config` 등) 리터럴이 실제 handoff 대상 repo와 다름에도 남아 있는 경우
    해당 시 SKILL.md Step 1-D "값 확보 실패 처리" 순서(helper 재실행 / GraphQL 재시도 → 런타임 질문 도구)로 실제 값 확보 후 치환.
  - `git rev-parse --show-toplevel`은 repo 밖에서 `fatal: not a git repository`를 반환하므로 `2>/dev/null` + `|| true`로 우회하고 `CURRENT_REPO` 빈 변수 검사로 분기한다.
  - **"어떤 git repo든 toplevel로 이동" 방지**: 사용자가 다른 repo 체크아웃 안에서 이 명령을 실행해도 `CURRENT_REPO ≠ REPO`일 때 clone 경로로 분기하므로 엉뚱한 repo를 재사용하지 않는다.
  - **실패 경로 격리 (서브쉘 + `set -e`)**: `gh repo clone` 실패, `cd` 실패, `git fetch` 실패 등 어떤 중간 명령이 실패해도 서브쉘이 즉시 exit 1로 종료한다. 따라서 `git fetch`/`git checkout`가 **엉뚱한 cwd**(예: clone 실패 후 이전 디렉토리)에서 실행되는 경로가 원천 차단. 서브쉘 종료 후 `||` 에러 메시지로 사용자에게 명시적 복구 안내.
  - **주의**: `gh repo clone`은 기본 branch(main)를 체크아웃하므로 `git fetch origin $BRANCH && git checkout $BRANCH` 단계로 handoff 작업 맥락 복귀.
- **이전 세션 산출물 위치**: <파일 경로 또는 PR/이슈 URL>
- **재개 지점**: Phase N-M부터
- **남은 Blockers**: <있으면 명시, 없으면 "없음">
````

**작성 규칙**:
- 가이드의 마지막 섹션으로 배치 (recency bias 활용). 필수 슬롯(재개 명령/산출물 위치/재개 지점/Blockers)만 포함하고 간결하게 유지한다.
- **공개 노출 주의**: 이 가이드는 `gh issue comment`로 GitHub에 게시된다. 로컬 사용자명/절대 경로/워크트리 메타데이터가 공개 코멘트에 포함되지 않도록 한다. `<worktree-root>` 같은 placeholder 또는 repo-relative 경로를 우선 사용한다.
- 출처: [Lost in the Middle (TACL 2024)](https://direct.mit.edu/tacl/article/doi/10.1162/tacl_a_00638/119630/Lost-in-the-Middle-How-Language-Models-Use-Long).

## 모범 패턴 (Issue #252 기반)

Issue #252의 LLM 이행 가이드에서 관찰된 효과적인 패턴:

### "진실 원천 우선" 패턴

```markdown
> 이슈에 "현재 버전 1.2.3"이라 기재되어 있으나, 실행 시점에서
> `grep version <파일>`로 실제 값을 먼저 확인한다.
> 실제 값이 다르면 실제 값을 BEFORE로 사용한다.
```

이슈 작성과 가이드 실행 사이의 시간차를 보상한다. 다른 PR이 먼저 머지되어 값이 변경되었을 수 있다.

### "병렬 힌트" 패턴

```markdown
다음 명령으로 현재 상태를 확인한다 (병렬 가능):
```

독립적인 명령들을 병렬 실행할 수 있음을 명시하여 LLM의 실행 효율을 높인다.

### "완전한 커밋 템플릿" 패턴

커밋 메시지를 LLM에게 자유작성시키지 않고, 가이드에 완성된 템플릿을 포함한다.
커밋 메시지의 type, scope, 본문 구조가 프로젝트 컨벤션과 일치하도록 보장한다.

### "조건부 분기" 패턴

```markdown
### 환경별 분기

- **macOS (Platform: darwin)**: 로컬에서 직접 실행
- **NixOS (Platform: linux)**: `ssh minipc`로 실행하되, 파일 편집은 로컬에서 수행
```

실행 환경에 따라 달라지는 행동을 명시하여 LLM이 올바른 경로를 선택하도록 한다.

### "TL;DR + Next Session Starter" 패턴

장문 가이드에서 핵심 맥락을 상단 TL;DR에, 재개 지점을 하단 Next Session Starter에 배치한다. "Lost in the Middle" 현상을 상쇄하여 새 세션 LLM의 맥락 파악을 돕는다. 출처: [Lost in the Middle (TACL 2024)](https://direct.mit.edu/tacl/article/doi/10.1162/tacl_a_00638/119630/Lost-in-the-Middle-How-Language-Models-Use-Long), [Anthropic: Long context tips](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/long-context-tips).

### "`[UNVERIFIED]` 라벨" 패턴

근거 없는 주장을 가이드에 남길 때 인라인 라벨을 사용한다. `[INFERRED]`(근접 근거의 추론), `[CONFLICTING]`(출처 상충)도 함께. 출처: [Anthropic: Reduce hallucinations](https://docs.anthropic.com/en/docs/test-and-evaluate/strengthen-guardrails/reduce-hallucinations), [MetaFaith (EMNLP 2025)](https://aclanthology.org/2025.emnlp-main.1505/).

예:
```markdown
`[UNVERIFIED]` 이 옵션은 NixOS 24.11에서 동작하지만 24.05에서는 미확인.
`[INFERRED]` PoC 추가가 품질을 개선한다 — 정량 벤치마크 부재, PROMPTEVALS 등 인접 근거로 추론.
`[CONFLICTING]` FRONT(2024)는 pipeline 분리 우세, Evaluating Design Choices(2025)는 direct generation 우세.
```

### "미검증 주석" 패턴 (DEPRECATED)

> **DEPRECATED**: 이 HTML 주석 패턴은 더 이상 권장되지 않는다. 신규 산출물은 위 [`[UNVERIFIED]` 라벨 패턴](#unverified-라벨-패턴)을 사용한다. 기존 산출물은 점진적으로 마이그레이션한다.

```markdown
<!-- 미검증: NixOS에서 이 옵션이 적용되는지 확인 필요. macOS에서만 테스트됨. -->
```

(참고용 — 가이드 작성 시점에 확인하지 못한 사항을 HTML 주석으로 표시하던 구 패턴.
`[UNVERIFIED]` 라벨은 본문에 인라인으로 노출되어 실행 LLM이 더 안정적으로 인지한다.)

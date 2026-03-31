---
name: run-da
argument-hint: "[for_plan|for_pr|both] [full] [fresh]"
description: |
  Run Devil's Advocate review on plans or code. Args: for_plan, for_pr, both. Modifier: full, fresh.
  Trigger: 'DA', 'DA 피드백', '피드백 루프', 'YAGNI 리뷰', '코드 리뷰 루프', 'run-da'.
  NOT for PR 코멘트 (use review-pr-feedback). NOT for 전수조사 (use parallel-audit).
---

# Devil's Advocate 피드백 루프

최대 8개 영역별 전문 DA 에이전트를 변경 규모에 맞게 병렬 실행하여 계획/코드를 엄격 리뷰한다.

## 모드

| `$ARGUMENTS` | 동작 |
|--------------|------|
| `for_plan` | 계획 단계 DA 1회 — 계획 파일 또는 대화 컨텍스트 대상 |
| `for_pr` | 구현 후 코드 DA 1회 — git diff 대상 |
| `both` | for_plan → 사용자 승인 → 구현 → for_pr 순차 수행 (각 단계의 실행 강도는 Review Intensity에 따라 다름) |
| *(비어있음)* | 사용자에게 모드 선택을 질문한다 |

### `full` modifier

모드 뒤에 `full`을 추가하면 (예: `for_pr full`, `both full fresh`)
**Review Intensity 판단을 건너뛰고 항상 전체 영역을 실행**한다.

| 구분 | 기본 동작 | `full` 동작 |
|------|----------|------------|
| 경중 판단 | 자동 수행 (SKIP/LITE/FULL) | 건너뜀 → FULL 강제 |
| 에이전트 수 | 판단 결과에 따라 가변 | 항상 전체 |
| 사용 시점 | 일반 | 상위 스킬이 강한 검토를 보장해야 할 때 |

### `fresh` modifier

모드 뒤에 `fresh`를 추가하면 (예: `for_pr fresh`, `both fresh`) **DA 에이전트에게 이전 라운드의 맥락을 전달하지 않는다.**

| 구분 | 기본 동작 | `fresh` 동작 |
|------|----------|-------------|
| DA 프롬프트 | 이전 라운드 결과 요약 포함 가능 | 코드/계획 + 프로젝트 컨텍스트만 전달. 이전 라운드 언급 금지 |
| 편향 | 이전 발견에 anchoring 가능 | 매 라운드 완전 독립 리뷰 |
| 무한 루프 위험 | 낮음 (이전 맥락으로 중복 감소) | 높음 (동일 지적 반복 가능 → 반복 감지 규칙으로 대응) |

`fresh` 사용 시 메인 에이전트는 DA 에이전트 프롬프트에 다음을 포함하지 않는다:
- 이전 라운드의 발견 사항
- 이전 라운드에서 수용/기각된 지적 내역
- "이번에는 다른 관점에서 봐주세요" 등 이전 라운드를 암시하는 표현

메인 에이전트는 finding의 도메인 + 위치(파일:줄) 조합으로 라운드 간 반복 감지를 수행한다.

## 빠른 참조

| 항목 | 위치 |
|------|------|
| DA 영역 상세 + 프롬프트 템플릿 | [references/da-domains.md](references/da-domains.md) |
| 피드백 프로토콜 상세 | [references/protocol.md](references/protocol.md) |
| Arbiter 프롬프트 + 판정 기준 | [references/arbiter-prompt.md](references/arbiter-prompt.md) |
| Arbiter 스케일링 + 실행 계약 | [references/arbiter-scaling.md](references/arbiter-scaling.md) |

## DA 영역

| 영역 | 집중 관점 | 심각도 기준 |
|------|----------|-----------|
| YAGNI | 불필요한 추상화, 미래 대비 과설계 | 사용처 0인 코드/인터페이스 존재 |
| NGMI | 근본적 설계 결함, 확장 불가 구조 | 요구사항 변경 시 전면 재작성 필요 |
| HALLUCINATION | 존재하지 않는 API/플래그/경로 사용 | 실행 시 즉시 에러 |
| SECURITY | 인증 우회, 비밀 노출, 입력 미검증 | 공격 표면 확대 |
| SIDE_EFFECT | 수정하지 않은 기존 기능에 대한 영향 | 기존 동작 변경/파괴 |
| CONSISTENCY | 프로젝트 컨벤션/네이밍/구조 위반 | 코드베이스 일관성 훼손 |
| READABILITY | 이해하기 어려운 로직, 주석 부재 | 다음 개발자(LLM 포함)가 의도 파악 불가 |
| CLEAN_CODE | 중복 코드, 매직넘버, 죽은 코드 | 유지보수 비용 증가 |

상세 프롬프트 템플릿과 출력 형식은 [references/da-domains.md](references/da-domains.md) 참조.

## Review Intensity (변경 규모 판단)

for_plan/for_pr 절차 시작 전에 실행한다. `full` modifier가 있으면 이 단계를 건너뛰고 FULL로 직행한다.

### 3단계

| 단계 | 에이전트 수 | 사용자 승인 | 설명 |
|------|-----------|-----------|------|
| SKIP | 0 | AskUserQuestion **필수** | DA 완전 생략 |
| LITE | SECURITY 필수 + 관련 도메인 | 불필요 | 관련 도메인만 선택 실행 |
| FULL | 전체 | 불필요 | 현행 전체 실행 |

### 판단 알고리즘

다음 순서로 평가한다. **먼저 매치된 조건이 우선**한다:

1. `full` modifier → **FULL**
2. 보안 관련 변경 (인증, 권한, 시크릿, 네트워크 노출, TLS) → **FULL**
3. 새 모듈/서비스 추가, 아키텍처/인터페이스 변경 → **FULL**
4. 설정/포트/환경변수/의존성 변경 → **FULL**
5. 단일 함수 소규모 수정, 리팩터링 → **LITE**
6. 순수 문서/주석/오타/whitespace/CHANGELOG → **SKIP** (단, 에이전트 실행 정책 파일 — SKILL.md, hooks/*, settings.json, AGENTS*.md — 은 문서가 아닌 코드 변경으로 취급하여 FULL)
7. 혼합 변경 → 포함된 변경 중 **가장 높은 단계** 적용
8. 불명확 → **FULL**

### 예시

| 변경 유형 | 단계 | 이유 |
|----------|------|------|
| README 오타, 주석 오탈자 | SKIP | 비실행 텍스트 |
| docstring 업데이트 | SKIP | 비실행 텍스트 |
| 기존 함수의 소규모 로직 수정 | LITE | 단일 함수, 구조 변경 없음 |
| flake.lock hash 업데이트 | FULL | 의존성 변경 (규칙 4) |
| 포트 번호 변경 | FULL | 설정/포트 변경 (규칙 4) |
| 새 NixOS 모듈 추가 | FULL | 새 모듈 (규칙 3) |
| secrets.nix 수정 | FULL | 보안 관련 (규칙 2) |
| README 오타 + 포트 변경 혼합 | FULL | 혼합: 가장 높은 FULL 적용 (규칙 7) |

### SKIP 절차

1. AskUserQuestion으로 사용자에게 DA 생략 승인을 요청한다:
   - 변경 내용 요약
   - SKIP 판단 근거
   - "DA를 생략해도 괜찮겠습니까?"
2. 사용자가 승인하면 DA를 생략하고 해당 모드(for_plan/for_pr)를 종료하여 상위 워크플로로 복귀한다.
3. 사용자가 거부하면 LITE 또는 FULL로 승격하여 DA를 진행한다.

### LITE 절차

1. SECURITY는 항상 포함한다.
2. 코드 변경이면 SIDE_EFFECT도 기본 포함한다 (기존 호출부 회귀 검출을 위해).
3. 나머지 도메인 중 변경 성격에 관련된 도메인만 선택한다.
   선택 판단 기준: 해당 도메인의 "집중 대상"(da-domains.md)이 이번 변경에 적용되는가.
4. 선택되지 않은 도메인은 NOT_RUN으로 기록한다.
5. 선택된 도메인만으로 기존 for_plan/for_pr 절차를 수행한다.
6. 종료 조건: **선택된 도메인 전부 CLEAR** (NOT_RUN 도메인은 평가 대상 아님).

### LITE 예시

단일 함수명 정리 리팩터링 → **SECURITY** + **SIDE_EFFECT** + **READABILITY** + **CONSISTENCY** 실행.
미실행: YAGNI(NOT_RUN), NGMI(NOT_RUN), HALLUCINATION(NOT_RUN), CLEAN_CODE(NOT_RUN).
이유: SECURITY는 항상 포함, SIDE_EFFECT는 코드 변경이므로 기본 포함, READABILITY/CONSISTENCY는 이름 변경에 직접 관련.

### LITE 라운드 요약 형식

```text
Round N 요약 (LITE: 선택 M개/전체 N개): DA 발견 X건
→ Arbiter: CONFIRMED Y건, NOT_AN_ISSUE Z건, NEEDS_MORE_INFO W건
영역별: SECURITY CLEAR, SIDE_EFFECT 2건(CONFIRMED 1, NOT_AN_ISSUE 1), ...
미실행: YAGNI(NOT_RUN), NGMI(NOT_RUN), ...
```

## 절차

### for_plan 모드

0. **Review Intensity 판단**을 수행한다.
   - SKIP → SKIP 절차를 따른다. 승인 시 for_plan을 종료한다.
   - LITE → LITE 절차에 따라 실행할 도메인을 선택한다.
   - FULL → 전체 영역을 실행한다.
1. 현재 계획 파일 또는 대화 컨텍스트에서 계획 내용을 수집한다.
2. 선택된 영역별 DA 에이전트를 `codex exec --full-auto`로 **병렬 실행**한다.
   실행 전 `/using-codex-exec` 스킬의 패턴 4 (exec 우회)와 패턴 5 (DA 피드백 루프)를 참조한다.
   - 세션별 임시 디렉토리를 생성한다: `DA_DIR=$(mktemp -d /tmp/da-plan-XXXXXX)`
   - 선택된 영역별 프롬프트 파일을 생성한다: `$DA_DIR/{domain}.md`
     각 프롬프트는 [da-domains.md](references/da-domains.md)의 공통 프롬프트 구조에 계획 전체 내용을 포함한다.
     반드시 "계획 외의 관련 파일도 직접 읽어 탐색하라"는 지시를 포함한다.
   - 선택된 도메인 수만큼 codex exec를 **background Bash tool 호출** (`run_in_background: true`)로 실행한다:
     ```zsh
     # SELECTED_DOMAINS: Review Intensity 판단 결과에 따라 결정
     # FULL이면 전체, LITE이면 SECURITY + SIDE_EFFECT(코드 변경 시) + 관련 도메인
     SELECTED_DOMAINS=(SECURITY SIDE_EFFECT READABILITY CONSISTENCY)  # 예: LITE

     # 1개 Bash call: 임시 디렉토리 + 선택된 도메인별 프롬프트 파일 생성
     DA_DIR=$(mktemp -d /tmp/da-plan-XXXXXX)
     for domain in "${SELECTED_DOMAINS[@]}"; do
       cat > "$DA_DIR/$domain.md" <<PROMPT
       ... 영역별 프롬프트 ...
     PROMPT
     done

     # 선택된 도메인 수만큼 background Bash tool 호출 (run_in_background: true)
     codex exec --full-auto --ephemeral \
       -o "$DA_DIR/${domain}-result.md" \
       "$(cat "$DA_DIR/${domain}.md")" \
       2>"$DA_DIR/${domain}-stderr.log"
     ```
   - `run_in_background: true`로 실행하면 LLM이 즉시 반환받아 사용자와 대화 가능하다.
     각 codex exec 완료 시 자동 알림이 온다. sleep/poll로 완료를 확인하지 않는다.
   - `& + wait` shell-level 병렬을 사용하지 않는다 (Bash tool sandbox 제약, [known-issues.md §11](../using-codex-exec/references/known-issues.md) 참조).
   - stdin pipe(`cat file | codex exec`) 대신 `"$(cat file)"` 인라인 인자를 사용한다.
   - `fresh` modifier가 있으면 이전 라운드 결과를 프롬프트에 포함하지 않는다.
   - codex exec는 `--full-auto`(workspace-write)로 실행되나, 프롬프트에서 "리뷰만 수행하고 파일을 수정하지 마라"를 명시한다.
     (이유: codex CLI 제약상 `--full-auto`가 `-s read-only`를 override하여 read-only 강제 불가. exec 우회 패턴 사용을 위한 트레이드오프.)
   - `--ephemeral`로 실행하여 Codex 세션 히스토리를 오염시키지 않는다.
   - 모델은 codex config.toml 기본값을 따른다. `-m` 플래그를 생략한다.
   - `/using-codex-exec` 패턴 5의 실행 흐름(`-o` 사용법, 결과 파일 검증, 명령 실행 순서)만 참고한다. 프롬프트 내용 규칙(문맥 보존, 라운드 히스토리 포함 여부)은 이 스킬의 `fresh`/프롬프트 조향 금지 규칙이 우선한다.
3. 모든 background 작업의 완료 알림을 수신한 후 결과 파일(`$DA_DIR/*-result.md`)을 수집하여 종합 리포트를 작성한다.
   실패 판정: 결과 파일이 없거나 빈 경우, 또는 exit code가 0이 아닌 경우(`$DA_DIR/*-stderr.log` 확인).
   실패한 영역만 재실행한다. 라운드마다 새 `DA_DIR`을 생성하여 이전 라운드 산출물과 분리한다.
4. findings 0건 → ALL CLEAR, 종료.
5. findings 1건 이상 → Arbiter 실행:
   - Arbiter 프롬프트를 조립한다 ([arbiter-prompt.md](references/arbiter-prompt.md) 참조).
   - codex exec로 실행한다 ([arbiter-scaling.md](references/arbiter-scaling.md) 실행 계약 참조).
   - 결과를 수집하여 사용자에게 전건 보고한다:
     - CONFIRMED_ISSUE + CRITICAL: **진행 차단** — 즉시 수정, 다음 라운드 전 해결 필수.
     - CONFIRMED_ISSUE + HIGH/MEDIUM/LOW: 자동으로 계획에 반영한다.
     - NOT_AN_ISSUE: 보고만 (반영 불필요).
     - NEEDS_MORE_INFO: AskUserQuestion으로 사용자 판단을 요청한다.
6. 반영 후 동일 선택 DA를 **새 codex exec 프로세스로** 재실행한다.
7. 선택된 DA 전부 CLEAR를 반환할 때까지 반복한다.

### for_pr 모드

0. **Review Intensity 판단**을 수행한다.
   - SKIP → SKIP 절차를 따른다. 승인 시 for_pr을 종료한다.
   - LITE → LITE 절차에 따라 실행할 도메인을 선택한다.
   - FULL → 전체 영역을 실행한다.
1. 변경사항이 커밋되어 있는지 확인한다 (`git status --porcelain`이 빈 출력이면 clean).
   `git diff main...HEAD`로 diff를 수집한다.
   - diff를 프롬프트에 직접 포함한다 (exec 우회 패턴).
   - diff가 과도하게 크면 (`git diff main...HEAD | wc -l`로 확인) 기계적 변경(flake.lock, hash 변경 등)을 필터링한 축약 diff를 사용한다.
     `git diff main...HEAD -- ':!flake.lock'`로 lock 파일 제외 가능.
2. 선택된 영역별 DA 에이전트를 `codex exec --full-auto --ephemeral`로 **병렬 실행**한다.
   실행 전 `/using-codex-exec` 스킬의 패턴 4 (exec 우회)를 참조한다.
   - 라운드별 임시 디렉토리를 생성한다: `DA_DIR=$(mktemp -d /tmp/da-pr-XXXXXX)`
   - 선택된 영역별 프롬프트 파일을 생성한다: `$DA_DIR/{domain}.md`
     각 프롬프트는 [da-domains.md](references/da-domains.md)의 공통 프롬프트 구조에 diff를 `<git-diff>` 태그로 감싸서 포함한다.
     반드시 "diff 외부의 관련 파일도 직접 읽어 탐색하라"는 지시를 포함한다.
   - 선택된 도메인 수만큼 codex exec를 **background Bash tool 호출** (`run_in_background: true`)로 실행한다 (for_plan과 동일 패턴).
     stdin pipe 대신 `"$(cat file)"` 인라인 인자를 사용한다.
     `& + wait` shell-level 병렬을 사용하지 않는다 (Bash tool sandbox 제약).
   - `fresh` modifier가 있으면 이전 라운드 결과를 프롬프트에 포함하지 않는다.
   - 프롬프트에서 "리뷰만 수행하고 파일을 수정하지 마라"를 명시한다.
3. 모든 background 작업의 완료 알림을 수신한 후 결과 파일을 수집하여 종합 리포트를 작성한다.
   실패 판정: 결과 파일이 없거나 빈 경우, 또는 exit code가 0이 아닌 경우. 실패한 영역만 재실행한다.
   라운드마다 새 `DA_DIR`을 생성하여 이전 라운드 산출물과 분리한다.
4. findings 0건 → ALL CLEAR, 종료.
5. findings 1건 이상 → Arbiter 실행:
   - Arbiter 프롬프트를 조립한다 ([arbiter-prompt.md](references/arbiter-prompt.md) 참조).
   - codex exec로 실행한다 ([arbiter-scaling.md](references/arbiter-scaling.md) 실행 계약 참조).
   - 결과를 수집하여 사용자에게 전건 보고한다:
     - CONFIRMED_ISSUE + CRITICAL: **진행 차단** — 즉시 수정, 다음 라운드 전 해결 필수.
     - CONFIRMED_ISSUE + HIGH/MEDIUM/LOW: 자동으로 코드에 반영하고 커밋한다.
     - NOT_AN_ISSUE: 보고만 (반영 불필요).
     - NEEDS_MORE_INFO: AskUserQuestion으로 사용자 판단을 요청한다.
6. 반영 후 동일 선택 DA를 **새 codex exec 프로세스로** 재실행한다.
7. 선택된 DA 전부 CLEAR를 반환할 때까지 반복한다.
8. 최종 승인 후 push한다.

### both 모드

1. **for_plan 절차** 전체를 수행한다.
2. 사용자의 계획 승인을 받은 뒤 구현을 진행한다.
3. 구현 완료 후 1차 커밋을 생성한다.
4. **for_pr 절차** 전체를 수행한다.
5. 최종 커밋 후 push하고 PR을 생성한다.

## 피드백 프로토콜

핵심 원칙 요약:

- **Arbiter 독립 판정**: DA findings는 독립 Arbiter 에이전트가 판정한다. 메인 에이전트는 판정하지 않는다.
  메인 에이전트는 CONFIRMED_ISSUE 항목의 수정만 담당한다.
- **CONFIRMED_ISSUE 자동 반영**: Arbiter가 CONFIRMED_ISSUE로 판정한 항목은 자동으로 반영한다.
  CRITICAL 심각도는 진행을 차단하고 즉시 수정한다.
- **사용자 전건 보고**: 모든 Arbiter 판정 결과(CONFIRMED_ISSUE, NOT_AN_ISSUE, NEEDS_MORE_INFO)를 사용자에게 보고한다.
  NEEDS_MORE_INFO 항목은 AskUserQuestion으로 사용자 판단을 요청한다.
- **PoC 의무화**: DA가 위반을 지적하면 구체적 파일:줄 또는 계획 항목 번호를 제시해야 한다.
  증거 없는 추상적 우려는 Arbiter가 NOT_AN_ISSUE로 판정한다.
- **Fresh perspective 보장**: 매 라운드마다 새 에이전트를 사용한다.
  `fresh` modifier 사용 시 이전 라운드 맥락도 완전히 차단한다.
- **프롬프트 조향 금지**: 후속 라운드 DA/Arbiter 프롬프트에 이전 라운드의 판정 결과를 포함하지 않는다.
  이전 라운드 결과를 "이미 해결된 사안"으로 프레이밍하는 것도 금지한다.
- **무한 루프 방지**: 3회 연속 동일 지적(도메인 + 위치 기준)이 반복되면 사용자 결정에 위임한다.
- **탈출 조건**: 선택된 DA 모두 CLEAR를 반환하면 루프를 종료한다 (NOT_RUN 도메인 제외).

상세 프로토콜은 [references/protocol.md](references/protocol.md) 참조.

## 사용자 질문 시 맥락 설명 의무

사용자에게 AskUserQuestion으로 판단을 요청할 때 (3회 반복 규칙, 5회 라운드 초과, fresh 모드 반복 감지 등 모든 경우), 사용자가 **딴짓을 하다가 돌아온 상황**을 가정하고 다음을 모두 포함한다:

1. **현재 상황 요약**: 어떤 작업을 하고 있었는지 (예: "PR #296의 DA for_pr 피드백 루프 Round 3입니다")
2. **문제 설명**: 무엇이 충돌/반복되고 있는지 구체적으로
3. **비유법 설명**: 기술 용어를 모르는 사람도 이해할 수 있도록 쉬운 비유로 설명
4. **선택지별 장단점**: 각 선택이 가져올 결과를 명확히
5. **질문**: AskUserQuestion으로 결정 요청

**나쁜 예** (맥락 부재):
> "SECURITY DA가 3회 연속 동일 지적을 반복합니다. 수용/기각/보류 중 선택해주세요."

**좋은 예** (맥락 풍부):
> "현재 PR #296 코드 리뷰 3라운드째입니다. SECURITY 영역 DA가 '입력 검증 누락'을 3회 연속 지적하고 있습니다.
> 해당 코드는 modules/foo.nix:42의 사용자 입력 처리 부분인데, 쉽게 비유하면 '현관문에 잠금장치를 달아야 한다'는 지적입니다.
> 저는 이전 2라운드에서 '이 입력은 내부 시스템에서만 오므로 잠금이 불필요하다'고 기각했지만, DA가 계속 지적합니다.
> - 수용: 입력 검증 코드 추가 (안전하지만 불필요한 코드 증가)
> - 기각 + CIR: '내부 전용 입력'이라는 근거를 기록하고 넘어감
> - 보류: 별도 이슈로 등록하고 나중에 판단"

## 검증 의무 (강화)

### DA 에이전트 출력 요건
- 모든 지적에는 반드시 구체적 파일:줄 또는 계획 항목 번호를 제시해야 한다.
- 코드 스니펫을 직접 인용하여 문제를 증명해야 한다.
- "~할 수도 있다", "~이 우려된다" 등 증거 없는 추상적 우려는 즉시 기각한다.

### Arbiter 검증 의무
- Arbiter는 각 finding에 대해 4가지 판정 기준(사실 정확성, 변경 연관성, 심각도 타당성, 실행 가능성)으로 독립 검증한다.
- NOT_AN_ISSUE 판정에는 파일:줄 직접 읽기 + 반증 코드 스니펫이 필수다.
- NEEDS_MORE_INFO는 추가 정보가 필요한 경우에만 사용한다.
- 상세 판정 기준은 [references/arbiter-prompt.md](references/arbiter-prompt.md) 참조.

### 메인 에이전트 수정 의무
- CONFIRMED_ISSUE 항목을 수정할 때, 해당 파일:줄을 읽는 것은 수정 작업의 일부로 수행한다.
- 수정 결과가 finding을 해결하는지 확인한다.

## 주의사항

- 매 라운드 새 codex exec 프로세스를 사용한다 (이전 라운드 결과에 의한 확증 편향 방지).
- DA codex 프로세스는 `--full-auto`(workspace-write)로 실행되나, 프롬프트에서 수정 금지를 지시한다. 코드나 계획을 직접 수정하지 않는다.
- "사용자 지시"만으로 DA 지적을 기각하지 않는다. 기술적 근거가 필수이다.
- DA 결과에서 다른 영역을 침범한 지적은 해당 영역의 DA 결과로 이관하거나 무시한다.
- 피드백 루프 결과는 PR 코멘트로 게시하여 이력을 보존한다.

## 참조 자료

- **[references/da-domains.md](references/da-domains.md)** -- DA 영역별 상세 정의, 프롬프트 템플릿, 출력 형식
- **[references/protocol.md](references/protocol.md)** -- 상태 흐름 매핑, Arbiter 판정 프로토콜, PoC 의무화 규칙, 무한 루프 방지, PR 코멘트 형식
- **[references/arbiter-prompt.md](references/arbiter-prompt.md)** -- Arbiter 프롬프트 템플릿, 4가지 판정 기준, few-shot 교정 예시, blind review 범위, 편향 방지
- **[references/arbiter-scaling.md](references/arbiter-scaling.md)** -- 동적 스케일링, codex exec 실행 계약, 실패 처리
- **[/using-codex-exec 스킬](../using-codex-exec/SKILL.md)** -- codex exec 실행 패턴 (패턴 4: exec 우회, 패턴 5: DA 피드백 루프). 플래그/제한사항 확인용.

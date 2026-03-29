---
name: run-da
argument-hint: "[for_plan|for_pr|both] [fresh]"
description: |
  Run Devil's Advocate review on plans or code. Args: for_plan, for_pr, both. Modifier: fresh.
  Trigger: 'DA', 'DA 피드백', '피드백 루프', 'YAGNI 리뷰', '코드 리뷰 루프', 'run-da'.
  NOT for PR 코멘트 (use review-pr-feedback). NOT for 전수조사 (use parallel-audit).
---

# Devil's Advocate 피드백 루프

8개 영역별 전문 DA 에이전트를 병렬 실행하여 계획/코드를 엄격 리뷰한다.

## 모드

| `$ARGUMENTS` | 동작 |
|--------------|------|
| `for_plan` | 계획 단계 DA 1회 — 계획 파일 또는 대화 컨텍스트 대상 |
| `for_pr` | 구현 후 코드 DA 1회 — git diff 대상 |
| `both` | 계획 DA + 사용자 승인 + 구현 + 코드 DA 총 2회 |
| *(비어있음)* | 사용자에게 모드 선택을 질문한다 |

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

메인 에이전트는 여전히 DA_ROUND_LOG를 내부적으로 관리하여 반복 감지를 수행한다.

## 빠른 참조

| 항목 | 위치 |
|------|------|
| 8개 DA 영역 상세 + 프롬프트 템플릿 | [references/da-domains.md](references/da-domains.md) |
| 피드백 프로토콜 상세 | [references/protocol.md](references/protocol.md) |

## 8개 DA 영역

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

## 절차

### for_plan 모드

1. 현재 계획 파일(`.claude/plans/`) 또는 대화 컨텍스트에서 계획 내용을 수집한다.
2. 8개 영역별 DA 에이전트를 `codex exec --full-auto`로 **병렬 실행**한다.
   실행 전 `/using-codex-exec` 스킬의 패턴 4 (exec 우회)와 패턴 5 (DA 피드백 루프)를 참조한다.
   - 세션별 임시 디렉토리를 생성한다: `DA_DIR=$(mktemp -d /tmp/da-plan-XXXXXX)`
   - 8개 영역별 프롬프트 파일을 생성한다: `$DA_DIR/{domain}.md`
     각 프롬프트는 [da-domains.md](references/da-domains.md)의 공통 프롬프트 구조에 계획 전체 내용을 포함한다.
     반드시 "계획 외의 관련 파일도 직접 읽어 탐색하라"는 지시를 포함한다.
   - 8개 codex exec를 **8개 background Bash tool 호출** (`run_in_background: true`)로 실행한다:
     ```zsh
     # 1개 Bash call: 임시 디렉토리 + 8개 프롬프트 파일 생성
     DA_DIR=$(mktemp -d /tmp/da-plan-XXXXXX)
     for domain in YAGNI NGMI HALLUCINATION SECURITY SIDE_EFFECT CONSISTENCY READABILITY CLEAN_CODE; do
       cat > "$DA_DIR/$domain.md" <<PROMPT
       ... 영역별 프롬프트 ...
     PROMPT
     done

     # 8개 background Bash tool 호출 (run_in_background: true): 각각 1개 codex exec 실행
     codex exec --full-auto --ephemeral \
       -o "$DA_DIR/YAGNI-result.md" \
       "$(cat "$DA_DIR/YAGNI.md")" \
       2>"$DA_DIR/YAGNI-stderr.log"
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
3. 8개 background 작업의 완료 알림을 모두 수신한 후 결과 파일(`$DA_DIR/*-result.md`)을 수집하여 종합 리포트를 작성한다.
   실패 판정: 결과 파일이 없거나 빈 경우, 또는 exit code가 0이 아닌 경우(`$DA_DIR/*-stderr.log` 확인).
   실패한 영역만 재실행한다. 라운드마다 새 `DA_DIR`을 생성하여 이전 라운드 산출물과 분리한다.
4. 유효한 지적만 선별하여 계획에 반영한다.
   - 기각하는 지적에는 반드시 [구조화된 기각 포맷](references/protocol.md#구조화된-기각-포맷)을 사용한다.
   - 기각 전 반드시 해당 파일:줄을 직접 읽어 확인한다. **검증 없는 기각을 금지한다.**
   - [묵살 안티패턴](references/protocol.md#묵살-안티패턴-금지)에 해당하는 기각 패턴을 사용하지 않는다.
5. 반영 후 동일 8개 DA를 **새 codex exec 프로세스로** 재실행한다.
6. 8개 DA 전부 CLEAR를 반환할 때까지 반복한다.

### for_pr 모드

1. 변경사항이 커밋되어 있는지 확인한다 (`git status --porcelain`이 빈 출력이면 clean).
   `git diff main...HEAD`로 diff를 수집한다.
   - diff를 프롬프트에 직접 포함한다 (exec 우회 패턴).
   - diff가 과도하게 크면 (`git diff main...HEAD | wc -l`로 확인) 기계적 변경(flake.lock, hash 변경 등)을 필터링한 축약 diff를 사용한다.
     `git diff main...HEAD -- ':!flake.lock'`로 lock 파일 제외 가능.
2. 8개 영역별 DA 에이전트를 `codex exec --full-auto --ephemeral`로 **병렬 실행**한다.
   실행 전 `/using-codex-exec` 스킬의 패턴 4 (exec 우회)를 참조한다.
   - 라운드별 임시 디렉토리를 생성한다: `DA_DIR=$(mktemp -d /tmp/da-pr-XXXXXX)`
   - 8개 영역별 프롬프트 파일을 생성한다: `$DA_DIR/{domain}.md`
     각 프롬프트는 [da-domains.md](references/da-domains.md)의 공통 프롬프트 구조에 diff를 `<git-diff>` 태그로 감싸서 포함한다.
     반드시 "diff 외부의 관련 파일도 직접 읽어 탐색하라"는 지시를 포함한다.
   - 8개 codex exec를 **8개 background Bash tool 호출** (`run_in_background: true`)로 실행한다 (for_plan과 동일 패턴).
     stdin pipe 대신 `"$(cat file)"` 인라인 인자를 사용한다.
     `& + wait` shell-level 병렬을 사용하지 않는다 (Bash tool sandbox 제약).
   - `fresh` modifier가 있으면 이전 라운드 결과를 프롬프트에 포함하지 않는다.
   - 프롬프트에서 "리뷰만 수행하고 파일을 수정하지 마라"를 명시한다.
3. 8개 background 작업의 완료 알림을 모두 수신한 후 결과 파일을 수집하여 종합 리포트를 작성한다.
   실패 판정: 결과 파일이 없거나 빈 경우, 또는 exit code가 0이 아닌 경우. 실패한 영역만 재실행한다.
   라운드마다 새 `DA_DIR`을 생성하여 이전 라운드 산출물과 분리한다.
4. 유효한 지적만 선별하여 코드에 반영하고 커밋한다.
   - 기각하는 지적에는 반드시 [구조화된 기각 포맷](references/protocol.md#구조화된-기각-포맷)을 사용한다.
   - 기각 전 반드시 해당 파일:줄을 직접 읽어 확인한다. **검증 없는 기각을 금지한다.**
   - [묵살 안티패턴](references/protocol.md#묵살-안티패턴-금지)에 해당하는 기각 패턴을 사용하지 않는다.
5. 반영 후 동일 8개 DA를 **새 codex exec 프로세스로** 재실행한다.
6. 8개 DA 전부 CLEAR를 반환할 때까지 반복한다.
7. 최종 승인 후 push한다.

### both 모드

1. **for_plan 절차** 전체를 수행한다.
2. 사용자의 계획 승인을 받은 뒤 구현을 진행한다.
3. 구현 완료 후 1차 커밋을 생성한다.
4. **for_pr 절차** 전체를 수행한다.
5. 최종 커밋 후 push하고 PR을 생성한다.

## 피드백 프로토콜

핵심 원칙 요약:

- **PoC 의무화**: DA가 위반을 지적하면 구체적 파일:줄 또는 계획 항목 번호를 제시해야 한다.
  증거 없는 추상적 우려는 기각한다.
- **기각 시 근거 제시**: "사용자 지시"만으로 DA 지적을 기각하지 않는다.
  기술적 근거를 반드시 명시한다.
- **Fresh perspective 보장**: 매 라운드마다 새 에이전트를 사용한다.
  `fresh` modifier 사용 시 이전 라운드 맥락도 완전히 차단한다.
- **프롬프트 조향 금지**: 후속 라운드 DA 프롬프트에 이전 라운드의 기각 근거를 포함하지 않는다.
  이전 라운드 결과를 "이미 해결된 사안"으로 프레이밍하는 것도 금지한다.
  `fresh` modifier 사용 여부와 무관하게 적용된다.
  (근거: #298 Case 3에서 2차 리뷰 프롬프트에 반박 논거를 사전 주입하여 P1 재제기를 방지한 사례)
- **무한 루프 방지**: 3회 연속 동일 지적이 반복되면 사용자 결정에 위임한다.
- **탈출 조건**: 8개 DA 모두 CLEAR를 반환하면 루프를 종료한다.

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

### 메인 에이전트 검증 의무
- DA 에이전트의 각 발견 사항을 수용하기 전에, 해당 파일:줄을 직접 읽어 사실 여부를 확인한다.
- 검증 없이 DA 결과를 그대로 수용하는 것을 금지한다.
- 검증 결과를 DA_ROUND_LOG(라운드별 발견/해결/기각 요약 — 형식은 references/protocol.md 참조)에 기록한다:
  "확인됨: 파일:줄에서 실제로 [문제] 발견" 또는
  "확인됨: 계획 Step N에서 [문제] 확인" 또는
  "기각: 파일:줄 확인 결과 DA 지적이 사실과 다름"
- 계획 모드에서도 파일 시스템 탐색이 가능하므로, 검증 불이행의 변명이 될 수 없다.

## 주의사항

- 매 라운드 새 codex exec 프로세스를 사용한다 (이전 라운드 결과에 의한 확증 편향 방지).
- DA codex 프로세스는 `--full-auto`(workspace-write)로 실행되나, 프롬프트에서 수정 금지를 지시한다. 코드나 계획을 직접 수정하지 않는다.
- "사용자 지시"만으로 DA 지적을 기각하지 않는다. 기술적 근거가 필수이다.
- DA 결과에서 다른 영역을 침범한 지적은 해당 영역의 DA 결과로 이관하거나 무시한다.
- 피드백 루프 결과는 PR 코멘트로 게시하여 이력을 보존한다.

## 참조 자료

- **[references/da-domains.md](references/da-domains.md)** -- 8개 DA 영역별 상세 정의, 프롬프트 템플릿, 출력 형식
- **[references/protocol.md](references/protocol.md)** -- 피드백 수용/기각 판단 기준, PoC 의무화 규칙, 무한 루프 방지, DA_ROUND_LOG 페이로드, PR 코멘트 형식
- **[/using-codex-exec 스킬](../using-codex-exec/SKILL.md)** -- codex exec 실행 패턴 (패턴 4: exec 우회, 패턴 5: DA 피드백 루프). 플래그/제한사항 확인용.

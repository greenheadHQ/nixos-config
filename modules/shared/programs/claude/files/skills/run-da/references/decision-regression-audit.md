# 의사결정·회귀 컨텍스트 조사 (Decision-Regression Audit)

이 문서가 "새 세션이 과거 의사결정을 모르고 회귀를 재도입"하는 것을 막기 위한 컨텍스트 조사 절차의 단일 진실 원천(SSOT)이다. `run-da`(reviewer/Arbiter)와 `parallel-audit`(auditor)이 모두 이 문서를 참조한다.

SSOT 경계 (중복 방지): 본 문서는 절차·소스 계층·세션 로그 방법론의 정본이다. 단 (a) 발동 조건(어떤 변경에 조사를 강제할지)은 [`intensity-rules.md`](intensity-rules.md)의 `GATE-REMOVAL-SIMPLIFY`가, (b) 5기준 기반 verdict 매핑은 [`arbiter-prompt.md`](arbiter-prompt.md)의 "Decision regression 판정"이 각각 정본이다. 본 문서는 이들 정본을 복제(verbatim 또는 규범적 재서술)하지 않으며, 탐색을 돕는 1줄 요지와 링크만 둔다. 또한 reviewer/auditor에게 주입되는 프롬프트 본문([`da-domains.md`](da-domains.md) 공통 프롬프트 등)은 self-containment를 위해 핵심 지시를 의도적으로 재서술할 수 있다(중복 허용 예외).

Owner: `run-da`. Dependent: `parallel-audit`. (validation-path catalog와 동일한 owner+링크 모델)

## 문제 정의

새 세션의 LLM은 과거 결정의 도입 근거를 모른 채 현재 산출물만 보고 판단하기 쉽다. 그 결과 발생하는 회귀(regression)는 git diff나 현재 코드만으로는 드러나지 않는다 — 결정의 근거는 commit/PR/issue 산문에, (있으면) CIR/ADR·세션 로그에 있다.

이 조사는 git으로 버전관리되는 모든 저장소에서 동작해야 한다. CIR/ADR 같은 프로젝트 특수 관습을 쓰지 않는 저장소에서도 commit/PR/issue 히스토리만으로 회귀를 점검할 수 있어야 한다.

## 4대 탐지 범위

| # | 범위 | 정의 | 대표 신호 |
|---|------|------|----------|
| 1 | decision regression | 과거에 의도적으로 내린 결정(방어 로직, 트레이드오프 선택, 기각한 대안)을 근거를 모른 채 되돌림 | "군살로 보여 제거", "단순화", 도입 PR/issue의 결정과 충돌 |
| 2 | 시계열 무시 (stale finding) | 이미 고쳐진 문제를 신규 문제로 재등록, 또는 옛 증거를 현재 상태로 오인 | 증거 시점 이후의 수정 커밋 미확인 |
| 3 | 제거/단순화 = 군살 오판 | 코드/문구를 덜어내는 변경에서 그 코드의 방어 의도를 못 읽음 | "줄 수가 많다=불필요" 추론, 도입 근거 미확인 |
| 4 | cross-layer 속성 회귀 | `mv`/rename/in-place write가 기존 파일의 보존돼야 할 속성을 silently 파괴 | symlink(다른 레이어가 관리)·mode/권한·owner 손실 |

범위 1·3은 보통 같은 변경에서 함께 나타난다(제거 방향 변경이 도입 근거를 모르면 decision regression). 범위 2는 세션 로그/이슈 기반 진단의 정확도 게이트다. 범위 4는 git 히스토리 없이 diff만으로 탐지되는 보조 차원으로, parallel-audit bundle 5와 auditor 프롬프트의 속성 보존 점검이 주로 담당하되 run-da SIDE_EFFECT도 점검한다.

## 발동 조건

발동 조건(어떤 변경에 이 조사를 강제할지)의 정본은 [`intensity-rules.md`](intensity-rules.md)의 `GATE-REMOVAL-SIMPLIFY`다. 요지(1줄): 제거·단순화·되돌림·리팩터 또는 왕복 핫스팟이면 Review Intensity와 무관하게 fail-closed 전체 조사, 그 외는 Review Intensity 연동. 트리거 정의·"왕복 핫스팟" 기준·불확실 시 fail-closed 규칙의 정본은 모두 위 문서다.

## 조사 소스 계층 (graceful degradation)

| 계층 | 소스 | 조회 수단 | 가용성 |
|------|------|----------|--------|
| 필수 | commit 히스토리 | `git log -S"<문자열>"`(pickaxe), `git log -p --follow -- <path>`, `git blame`, revert 추적 | 모든 git repo |
| 필수 | PR·issue 본문 | `gh`/`glab` (forge 있으면). 본문의 결정·기각 대안·"되돌림" 논의 | GitHub/GitLab 등 forge 연결 시 |
| 보조 | CIR/ADR | PR 본문 CIR/ADR 섹션, 인라인 `# CIR:` 주석 | 해당 관습을 쓰는 저장소만 |
| 보조 | 로컬 세션 로그 | `~/.claude/projects/<repo>/`·`~/.codex/sessions/`에서 현재 repo 관련 세션 (아래 "세션 로그 조사") | 사용자 로컬 작업 시에만 (CI·타인 환경엔 부재) |
| 보조 | 계획·연구 노트 | `.claude/plans/`·`.claude/research/` 등 | 해당 관습을 쓰는 저장소만 |

보조 소스는 있으면 활용, 없으면 건너뛴다(graceful skip) — 부재가 조사 실패가 아니다. 단 필수 소스(commit; forge 있으면 PR/issue)는 반드시 조회한다. 신호는 경험상 코드 주석보다 PR/issue 산문과 세션 로그에 집중되므로, git diff만 grep하고 끝내지 않는다.

## 조사 주체와 역할 분담

| 주체 | 역할 |
|------|------|
| 메인 에이전트 | "의사결정 컨텍스트 팩" 1차 수집·주입. 네트워크(`gh`/`glab`)·세션 로그 접근은 메인 전용 (reviewer/auditor는 read-only sandbox라 네트워크·홈 디렉토리 접근이 막힐 수 있음) |
| reviewer / auditor | 주입된 컨텍스트 팩 위에서, 자기 bundle 관점으로 `git log`/`blame`/`show` 등 read-only 보강 조회 |

메인이 수집한 "의사결정 컨텍스트 팩"은 reviewer/auditor/Arbiter 프롬프트에 selective propagation 원칙([`protocol.md`](protocol.md))에 맞춰 주입한다 — 변경과 무관한 전체 히스토리가 아니라, 변경 파일·주제에 관련된 결정·되돌림 이력만.

degraded 수행 (fan-out 없는 경우): Review Intensity가 SKIP/LITE여서 reviewer/auditor fan-out이 없거나 적어도, `GATE-REMOVAL-SIMPLIFY`가 발동하면 메인 에이전트가 직접 Step A·B·D를 수행한다. reviewer/auditor가 있으면 Step C로 보강한다. 즉 조사 강제는 fan-out 유무와 독립이며, SKIP이라도 메인이 최소 Step A·B·D를 책임진다. 단 degraded 수행 시에도 가능하면 fresh 독립 검토를 우선한다 — 메인이 자기 변경을 self-arbitration하는 것은 SKIP(무검토) 기준선보다 나은 best-effort이며, 독립 Arbiter 분리(피고≠심판)를 완전히 대체하지는 않는다.

## 절차

### Step A — 의사결정 컨텍스트 팩 수집 (메인)

변경 파일·주제별로 다음을 수집해 자기 완결적 팩으로 정리한다:

1. commit 이력: `git log --oneline --follow -- <path>` (왕복 핫스팟 판별) + 의심 개념을 `git log -S"<개념>" --oneline`로 역추적해 도입/소멸 커밋 식별.
2. 되돌림 신호: `git log -i -E --grep='revert|회귀|regress|되돌|롤백' --oneline` 및 도입 커밋 메시지의 근거. (패턴은 `--grep=`로 직접 붙이고 `-i -E`는 분리한다 — `git log --grep -iE '...'`는 `--grep`이 `-iE`를 패턴 값으로 소비하고, 뒤따르는 정규식 문자열이 revision으로 오인되어 fatal로 실패한다.)
3. PR/issue 본문 (forge 있으면): 도입 PR의 결정·기각 대안, 관련 issue의 "이건 …에서 결정됨/폐기=회귀" 논의.
4. 보조 소스 (있으면): CIR/ADR, 세션 로그(아래), 계획 노트.

### Step B — 시계열 게이트

세션 로그·이슈·옛 finding을 근거로 한 진단은 다음을 대조한 뒤에만 회귀로 판정한다:

> 증거 시점 → 그 이후의 수정 커밋 존재 여부 → 현재 코드에 문제가 실제로 남아 있는지

이미 고쳐진 문제를 신규로 등록하지 않는다. 증거가 과거 시점이면 `git log --since=<증거시점> -- <path>`로 후속 수정을 확인한다.

### Step C — reviewer/auditor 보강

각 reviewer/auditor는 주입된 팩 + 자기 bundle 관점의 read-only 조회로, 이번 변경이 과거 결정과 충돌하는지 점검한다. 충돌 발견 시 finding에 과거 결정의 출처(commit SHA / PR# / issue# / 세션)를 근거로 첨부한다(출처 없는 추상적 우려는 기각 대상).

### Step D — 회귀 판정 및 처리

회귀가 의심되면 Arbiter가 과거 결정의 근거를 출처(commit SHA / PR# / issue#)와 함께 제시하고, 현재 변경 의도(commit/PR/대화)와 대조한다. 5기준 기반 verdict 매핑(과거 근거를 알고 한 의도적 변경 → 통과, 근거를 모르는 되돌림 → 회귀, 불명확 → 사용자 질문)의 정본은 [`arbiter-prompt.md`](arbiter-prompt.md)의 "Decision regression 판정" 섹션이다. 사용자 질문 시 [`main-agent-obligations.md`](main-agent-obligations.md)의 5요소 맥락 의무를, 상태 전이는 [`protocol.md`](protocol.md)를 따른다.

이는 [`da-domains.md`](da-domains.md)의 "의도된 제거·축소는 위반이 아니다"의 반대편을 보완한다: 의도된 변경은 통과시키되, 근거를 모르는 되돌림만 잡는다.

## 세션 로그 조사 (보조 소스)

로컬 세션 로그는 git/PR에 박제되지 않은 raw 의사결정 맥락("왜 그 결정을 내렸나, 무엇을 기각했나")을 담는다. 현재 repo 관련 세션으로 한정하여 조사한다.

| 런타임 | 위치 | repo 한정 방법 |
|--------|------|---------------|
| Claude Code | `~/.claude/projects/<sanitized-cwd>/*.jsonl` | 경로 자체가 cwd별 디렉토리 |
| Codex | `~/.codex/sessions/<YYYY/MM/DD>/*.jsonl` | 세션 내 cwd/`<environment_context>`로 필터 |

방법론 (비용 큰 대용량 로그 대응):

1. 키워드 grep으로 후보 세션 식별: 변경 주제 키워드 + 회귀/되돌림 시그널(`회귀|되돌|롤백|재도입|왜 또|왜 다시|이미 결정|...`).
2. user 발화만 추출 (노이즈 필터): `jq`로 user role 텍스트만 뽑고 `task-notification`/`<command-`/`system-reminder`/skill 주입 등을 제외. 사람의 결정·지적이 신호다.
3. 후보 세션을 정독해 결정 근거·기각 이력을 추출한다.

프라이버시: 세션 로그는 민감 정보를 포함할 수 있다. 내부 점검에만 쓰고, PR 코멘트 등 외부 산출물에는 원문을 노출하지 않는다(요지·출처만). 외부 산출물 마스킹 정책과 정합.

## Non-goals

1. 세션 로그는 로컬 전용: CI·`claude -p`·타인 머신·codex exec subprocess 등 홈 디렉토리 세션 로그가 없는 환경에서는 이 보조 소스를 건너뛴다(graceful skip). 필수 소스(git; forge 있으면 PR/issue)만으로 진행한다.
2. forge 부재: GitHub/GitLab 등 forge가 없거나 인증되지 않은 저장소에서는 PR/issue 본문 조회를 건너뛰고 commit 히스토리만으로 진행한다. 이 경우 PR/issue 산문에만 있던 근거는 놓칠 수 있음을 finding 신뢰도에 반영한다.
3. 완전한 의도 추론 불가: 현재 변경이 "의도적 변경"인지 "모르고 되돌림"인지는 commit/PR/대화로 근사 판정한다. 불확실하면 fail-closed로 `NEEDS_MORE_INFO` 사용자 질문 (Step D).

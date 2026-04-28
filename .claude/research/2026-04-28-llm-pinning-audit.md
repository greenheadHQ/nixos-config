# LLM 박제(pinning) 패턴 전수조사 — 기록 archive

> 본 문서는 분석 시점(2026-04-28)의 측정 결과를 보존하는 **archive**다.
> 스킬/기술 문서/코드 주석에서 본 문서를 참조하지 않는다 — 운영 정책의 단일 진실 원천은
> 각 SKILL.md / hook script / lefthook 설정이며, 본 문서는 그 정책의 도입 배경을 설명하는
> 역사 기록일 뿐이다. 후속 LLM은 본 문서를 일반 인용 대상으로 사용하지 마라.

작성일: 2026-04-28
대상 corpus: nixos-config 67개 jsonl (10,896줄 assistant text)
보조 검증 corpus: 타 활성 corpus 1,832 jsonl (309,216줄)

## 메서드

1차 분석: 4개 패턴(이슈/PR 번호, DA 라운드, 커밋 hash, 기타 메타데이터)에 대해 4개 분석 에이전트 병렬 발사.

2차 심층조사 (1차 한계 4가지 해소):
- 보조 corpus 검증
- manual triage n=120 (패턴당 30건 무작위 표본, 95% Wilson CI ±15-18pp)
- 부활 카테고리 직접 증거 수집 (세션 경계 + cross-session 매트릭스)
- GitHub PR/이슈/commit 직접 조회 (gh CLI + 로컬 git grep)

총 분석 에이전트 8개 (1차 4 + 2차 4) + run-da Intensity 1개 + 4 reviewer bundle + Arbiter.

## 1차 분석 결과 (4개 패턴 빈도)

대상: nixos-config corpus 10,896줄 assistant text dump.

| 패턴 | 등장 횟수 |
|---|---|
| `#NNN` (PR/이슈 번호) | 411 |
| `Round [0-9]` | 227 |
| 7-8자리 hex (commit-like) | 254 |
| `Round/Phase/Step/단계` 합 | 637 |
| 워크트리 절대경로 | 91 |
| ad-hoc finding ID (REG/CIR/YAGNI/CORR/MAINT/Adjacent) | 51 |
| `arbiter` | 254 |
| `parallel-audit` / `전수조사` | 161 |

top 식별자 (등장 횟수): `#511` 50회, `#539` 17, `#535` 12, `#534` 12, `#512` 12.

## 2차 심층조사 결과

### 보조 corpus 비교 (1만줄당 정규화)

본 분석은 nixos-config 한정으로 가드레일을 도출. 보조 corpus(별도 활성 프로젝트, 28.4배 크기)는 비교 baseline.

| 패턴 | nixos /1만줄 | 보조 corpus /1만줄 | 비율 |
|---|---|---|---|
| `#NNN` PR/이슈 | 365 | 82 | nixos 4.5배 |
| `Round N` | 240 | 26 | nixos 9배 |
| `arbiter` | 249 | 9.7 | nixos 25배 |
| 7-8자 hex | 233 | 33 | nixos 7배 |
| 워크트리 절대경로 | 21 | 93 | **보조 4.4배** |
| `Phase N` | 소수 | 119 | **보조 단독** |

해석: nixos는 비율로 강함 (harness/DA 메타 작업 편향). 보조 corpus는 절대량/구조적 잡음(stale 워크트리 경로 등) 압도. 본 가드레일은 nixos 패턴 기반이며 보조 corpus의 단독 위험(Jira ID, Phase decimal)은 별도 작업 범위.

### Manual triage 분류 (n=120, 패턴당 30건 무작위)

| 패턴 | (a) 정상 | (b) 영구 박제 | (c) drift | (e) FP | n |
|---|---|---|---|---|---|
| 이슈/PR 번호 | 17 (57%) | **13 (43%)** | 0 | 0 | 30 |
| DA Round | 26 (87%) | 4 (13%) | 0 | 0 | 30 |
| 커밋 hash | 10 (33%) | **11 (37%)** | **2 (7%)** | 7 (23%) | 30 |
| 워크트리 경로 | 22 (73%) | 6 (20%) | 2 (7%) | 0 | 30 |

이전 추정 vs manual:
- 이슈/PR: 추정 25% → 실측 43% (+18pp 과소평가)
- DA Round: 추정 15% → 실측 13% (정확)
- 커밋 hash: 박제+drift 합쳐 44% (가장 위험)

**박제는 결합되어 등장**: hash 박제 11건 중 4건이 Round 박제와 같은 응답에 동거. 패턴별 b%를 단순 합산 금지.

### GitHub 잔존 박제 매트릭스 (직접 조회)

| 카테고리 | 박제 건수 | 정정 | 잔존 (dangling) | 잔존율 |
|---|---|---|---|---|
| Mid-flight commit hash (squash 후) | ~30 partial | 0 | ~25 | **83%** |
| Finding ID PR/이슈 본문 | 11종 | 0 | 11 | **100%** |
| 코드 주석 finding ID (main) | 13건(과거) | 13 | 0 | **0%** ✅ |
| 라인번호 박제 (이슈 본문) | 8 | 0 | 8 | **100%** |
| 워크트리 절대경로 (이슈 본문) | 1 | 0 | 1 | **100%** |
| Hallucination 수치 (PR/commit) | 3곳 | 1 | 2 | **66%** |

핵심 발견:
- **Squash 머지가 박제를 보존**: 한 PR squash 후 main에 머지 SHA 1개만 reachable, 나머지 14개 partial hash dangling. squash commit message 본문엔 살아남아 후속 LLM에게 "유효한 git ref"로 오인됨.
- **Hallucination이 commit message에서 정정 안 됨**: 한 PR에서 잘못된 수치가 PR 본문에는 정정 메모 추가됐으나 commit body와 squash commit message에는 그대로 박제 잔존.
- **코드 주석 finding ID는 깨끗하게 제거됨**: 사용자의 일괄 제거 지시가 코드 레벨에서 성공. 단 PR/이슈 본문 잔존율 100%.
- **이슈 본문 라인번호 박제**: 작성자가 self-aware하게 "현재 값과 다를 수 있음, Phase 1에서 grep 재확인" 경고 동반했지만 실행 LLM이 무시할 위험.

### 부활 메커니즘 직접 증거

세션 경계 식별: 67개 jsonl 중 명시적 압축 marker(`/compact`, "continued from previous conversation") **0건**. `/clear` 1건. 즉 부활은 거의 전부 cross-session.

부활 매커니즘 5가지 (증거 기반):

1. **SKILL.md hard-code inject (가장 강력)** — 22개 ID baked in SKILL.md, 매 트리거 시 자동 컨텍스트 진입.
2. **워크트리 이름이 cwd 자동 진입** — `/clear` 직후 27초 만에 cwd가 `worktrees/issue_NNN`인 세션에서 LLM이 `#NNN` 자동 인용 직접 관찰.
3. **git/gh 명령 결과의 영구성** — `git stash list`/`git log`/`gh pr list` 출력에 commit message의 `(#NNN)`이 매 세션 부활.
4. **자기 분석 루프 (메타)** — grep 통계 작업이 모든 식별자 부활시킴 (본 작업 자체 포함).
5. **Research doc 영구성** — `docs/superpowers/research/...` 같은 영구 docs가 worktree마다 복제되어 grep/Read 시 자동 부활.

부활 매트릭스 (top 식별자):

| 식별자 | 등장 세션 수 | 총 등장 | SKILL.md baked? | 기간 |
|---|---|---|---|---|
| `#296` | 24 | 83 | run-da, parallel-audit | 24일 |
| `#298` | 22 | 48 | run-da, parallel-audit | 24일 |
| `#486` | 13 | 79 | parallel-audit | 8일 |
| `#115` | 13 | 23 | review-pr-feedback | 광범위 |
| `issue_491` worktree | 10 | 183 | — | 8일 |
| `issue_492` worktree | 9 | 311 | — | 8일 |
| `issue_511` worktree | 6 | 867 | — | 7일 |
| `#511` | 4+6 | 51+867 | syncing-codex-harness | 7일 |
| `#500/#502` | 9/8 | 25/28 | unbaked (자연 부활) | 8일 |

22개 baked ID + 자연 부활 ID(예: `#500`, `#488`, `#512`) 다수.

## 사용자 짜증 시그널 매핑 (pain-points.jsonl 17건 중 nixos-config 사례)

| 시그널 | 직전 LLM 발화 | 박제 카테고리 |
|---|---|---|
| "야," | "Round 2 8개 DA 실행 중. 완료 알림 대기" | DA 라운드 카운터 + 에이전트 수 |
| "작업 끝난 거 아니야?" | "Post-Implementation 절차: 1.~~커밋~~ ✓ 2.**DA for_pr** ← 현재 ..." | 절차 단계 번호 박제 |
| ";;" | 일반 결과 요약 표 + 진행 단계 박제 직후 | 결과 표 + 진행 카운터 |

별도 corpus 짜증 사례도 있으나 본 작업 범위 외.

## 가드레일 우선순위 11개 (전체)

본 작업은 1-3+4를 처리. 나머지는 후속 이슈 분리.

| 순위 | 가드레일 | 본 작업? |
|---|---|---|
| 🔴 1 | commit message 박제 차단 hook (lefthook commit-msg, warn-only) | ✅ |
| 🔴 2 | PR 본문 작성 시 round/finding ID 자동 sanitize (create-pr SKILL.md instruction) | ✅ |
| 🔴 3 | 이슈/PR 박제 가드 (create-issue Step 1 자동 cross-reference 첨부 금지 + epic 제목 sub-issue 박제 금지) | ✅ |
| 🟠 4 | SKILL.md hard-code 정리 (22 baked ID 중 nixos-config 9건 우선 정리) | ✅ |
| 🟠 5 | 워크트리 절대경로 strip hook | 후속 |
| 🟠 6 | commit message hallucination 정정 강제 | 후속 |
| 🟡 7 | 세션 내 진행 보고 디테일 축소 | 후속 |
| 🟡 8 | CIR 섹션 정의 재명시 — 본 작업 가드레일 2에 흡수 | 부분 ✅ |
| 🟡 9 | harness wrapper 태그 인용 금지 | 후속 |
| 🟢 10 | handoff/CIR 산출물 형태 재검토 (영구 코멘트 → worktree-local) | 후속 |
| 🟢 11 | 보조 corpus 단독 가드 (Jira ID, Phase decimal, Stale 경로) | 후속 |

## DA Round 1 결과 (for_plan, 본 plan에 반영 완료)

Review Intensity: FULL (규칙 6: SKILL.md/hooks = 에이전트 실행 정책 파일).

4 reviewer bundle (Correctness/Design/Regression/Maintainability) 병렬 + Arbiter 판정.

14건 distinct findings 모두 CONFIRMED_ISSUE (CRITICAL 0건):
- HIGH 5건: finding ID Title Case 누락, 8 세부 도메인 누락, lefthook install 단계 명시, create-issue Step 1 instruction 모호, create-issue Epic 예시 자기모순.
- MEDIUM 5건: 패턴3 단어경계 부재, R[0-9]+ docs 표 충돌, 백틱 hex revert 충돌, baked ID 회색지대, regex 매직값 주석 부재, create-pr instruction 위치 분리.
- LOW 4건: scripts/lint vs scripts/ai 컨벤션, R[0-9]+ 일반어 false positive, .claude/research/ 명명, revert false positive PoC 부정확.

selective consistency trigger 없음 (split/fragmented 없음). 14건 모두 본 plan에 반영.

## 메서드 한계

1. Manual triage n=30 표본 95% Wilson CI ±15-18pp. ±5pp 정확도면 패턴당 n≈300 필요.
2. 분류 주관성 — a/b 경계 흐린 케이스 ±3건 변동.
3. 부활 (d) 카테고리 — ±2줄 컨텍스트로 식별 불가, 별도 cross-session 매트릭스로 보완.
4. 보조 corpus(타 활성 corpus)의 GitHub 잔존 박제는 측정 안 됨 (별도 repo 직접 조회 필요).
5. 67개 jsonl 코퍼스에 명시적 auto-compaction marker 0건. Claude Code가 transcript에 별도 형태로 남기는지 미확인 (130 프로젝트 전체 확장 필요).

## 데이터 위치 (휘발성 — 작업 당시 /tmp 경로, 재현 불가)

> ⚠️ 아래 `/tmp/*` 경로는 분석 작업 시점의 임시 산출물이다. 호스트 재부팅 또는 `/tmp` cleanup 시 사라지므로 **유효 참조로 인용하지 마라**. 재분석이 필요하면 본 문서의 메서드 섹션을 따라 새로 dump를 생성한다. 재분석 메서드와 당시 측정값은 본 archive만 보존한다 — 운영 정책의 단일 진실 원천(SoT)은 여전히 각 SKILL.md / hook script / lefthook 설정이며 본 문서가 아님 (문서 상단 archive 경고 참조).

- nixos-config corpus jsonl 리스트: `/tmp/nixos-jsonl-list.txt` (67개)
- nixos-config assistant text dump: `/tmp/nixos-assistant-text.dump` (10,896줄, 644KB)
- 보조 corpus jsonl 리스트: `/tmp/zari-jsonl-list.txt` (1,832개)
- 보조 corpus dump: `/tmp/zari-assistant-text.dump` (309,216줄, 17MB)
- 통합 corpus 리스트: `/tmp/all-jsonl-list.txt` (2,767 jsonl)
- 부활 매트릭스 raw: `/tmp/jsonl-meta/sorted.tsv`, `id-counts-all.tsv`, `baked.txt`, `unbaked-ids.txt`
- pain-points (영구): `~/.claude/pain-points{,.archive}.jsonl` (17건 짜증 시점)

## 다음 단계 후보 (사용자 결정)

| 옵션 | 효과 | 비용 |
|---|---|---|
| A. 본 PR 머지 | 가드레일 1-3+4 활성화 | 즉시 |
| B. 후속 이슈 분리 (가드레일 5-10) | 잔여 우선순위 처리 | 중-고 |
| C. 과거 GitHub corpus 박제 일괄 sweep | 잔존 박제 정리 (이슈 본문 라인번호, PR 본문 finding ID 등) | 중 |
| D. 보조 corpus 별도 GitHub 잔존 조사 | 보조 corpus 잔존율 측정 | 중 |
| E. 130 프로젝트 전체 auto-compaction marker 탐색 | 미해결 블랙박스 해소 | 낮음 |

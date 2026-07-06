# Implementation Plans

improve 스킬이 2026-07-02 (commit `fb2a8aa6`) 기준 전 저장소 감사(standard 깊이:
correctness/security very thorough, 나머지 카테고리 medium)에서 생성했다.
최초 leverage 상위 5건(001–005)에 더해, 운영자 지시로 backlog 전체와
direction 3건을 plan으로 승격했다(006–018). 각 plan은 epic
[#937](https://github.com/greenheadHQ/nixos-config/issues/937)의 sub-issue로
등록되어 있다 (Issue 열).

021–023은 2026-07-03 (commit `79530cec`) 이슈 백로그 전수조사에서 승격됐다.
같은 전수조사에서 열린 이슈 84건 중 38건을 close했고(판정 근거·재개 조건은
각 이슈의 close 코멘트에 기록), 잔여 유효 이슈 31건은 본문을 improve 형식
(Current state 재검증 / Remaining work / Verification / Boundaries)으로
재작성했다 — 재감사 시 GitHub 열린 이슈 본문이 최신 판정이다.

**Reconcile 2026-07-06 (commit `a6bbf637`)**: DONE 전 건 spot-check 통과 —
002(비특권 유저·sandbox 실배포 유지), 003(same-fs mktemp), 006(gitleaks
`.local.md` 예외 부재 + gitignore 대체), 007(flock 타임아웃), 019(미러 타이머
당일 04:31 정상 실행), 021–023(머지 커밋 확인). TODO 9건 drift check:
010만 drift(커밋 `09fffbee`의 1줄 삽입으로 라인 번호 +1 shift — plan 파일
현행화 완료, finding 불변), 나머지 8건(008·011·012·013·014·015·018·020)은
NO DRIFT — 대상 파일 미변경 또는 plan이 명시적으로 예상한 변경(020의 019
착륙, 018의 스냅샷 이동)뿐. epic [#903](https://github.com/greenheadHQ/nixos-config/issues/903)
하위 이슈(#904·#905·#907·#911)는 run-da/parallel-audit 디렉토리가 2026-07-03
재검증 이후 미변경이라 이슈 본문이 그대로 최신 판정이다. Anki plans 024–027은
PR [#978](https://github.com/greenheadHQ/nixos-config/pull/978)(OPEN) 머지
대기 중 — 머지 전까지 본 인덱스에 미반영이 정상.

각 executor: plan 파일을 끝까지 읽고 시작하고, STOP conditions를 존중하고,
끝나면 자기 행의 Status를 갱신한다.

## Execution order & status

| Plan | Title | Priority | Effort | Depends on | Issue | Status |
|------|-------|----------|--------|------------|-------|--------|
| 001 | Immich DB 재해복구 문서를 백업 이원 구조에 맞게 정정 | P1 | S | — | #938 | DONE |
| 002 | karakeep webhook 브리지 비특권·sandbox·인증 하드닝 | P1 | M | — | #939 | DONE (PR #971, nrs 적용 + E2E 검증 완료 2026-07-05 — AF_UNIX 불필요 실측, 200 계약 후속 수정 PR #972 포함. 토큰 활성화는 선택적 운영자 후속) |
| 003 | log-monitor 상태/큐 재작성 same-fs 원자적 교체 | P1 | S | — | #940 | DONE |
| 004 | 백업 스크립트 추출 + 특성화 테스트 | P2 | M | — | #941 | DONE (PR #980, nrs 적용 + 실 백업 2종 E2E 완료 2026-07-05) |
| 005 | Immich DB(pgvecto-rs) 마이그레이션 spike (조사 전용) | P2 | M | — | #942 | DONE |
| 006 | gitleaks `.local.md` 전면 예외 제거 → gitignore 대체 | P2 | S | — | #943 | DONE (PR #981 — 전후 히스토리 스캔 차집합 0건 확인, 배포 불필요) |
| 007 | codex-remote-control-maint flock 타임아웃 부여 | P2 | S | — | #944 | DONE (PR #979, nrs 적용 + 락 타임아웃 실측 완료 2026-07-05) |
| 008 | 완료 PRD 상태 정정 + 아카이브 관례 적용 | P3 | S | — | #945 | TODO |
| 009 | maint sync/알림 상태전이 특성화 테스트 | P3 | S | 007 (soft) | #946 | DONE (PR #982 — 테스트 전용, 배포 불필요) |
| 010 | verify-ai-compat lint 엔진 분리 + host-state 테스트 | P2 | M | — | #947 | TODO (2026-07-06 reconcile: 라인 번호 현행화) |
| 011 | Pushover 전송 플랫폼 공용 헬퍼 통합 | P3 | M | — | #948 | TODO |
| 012 | claude 훅 hook-runtime 파서 채택 확대 | P3 | M | — | #949 | TODO |
| 013 | Karakeep 파이프라인 헬퍼(fallback-sync·bridge) 테스트 | P3 | M | — | #950 | TODO |
| 014 | Karakeep CSP 전면 제거를 아카이브 경로로 한정 | P3 | M | — | #951 | TODO |
| 015 | folder-actions 공유 lib 특성화 테스트 (1단계) | P3 | L | 011 (soft) | #952 | TODO |
| 016 | 홈서버 백업/복구 자세 설계 spike | P2 | M | — | #953 | DONE |
| 017 | 유지보수 창 3작업 묶음 실행 계획서 | P3 | S | 005, 016 (hard) | #954 | DONE |
| 018 | 하네스 추출 가능성 판정 spike | P3 | M | — | #955 | TODO |
| 019 | Immich 원본 사진 HDD 일일 미러 (016 추천 A 구현) | P1 | M | — | #961 | DONE (nrs 적용 + 초회 미러 완료 2026-07-02 — 창 사전 게이트 충족) |
| 020 | 소용량 데이터 restic→R2 오프사이트 백업 (016 추천 B 구현) | P2 | M-L | 운영자 사전 준비 (R2/1Password) | #962 | TODO |
| 021 | pinning-guard `--body-file` 파일 내용 스캔 | P1 | M | — | #684 | DONE (PR #966) |
| 022 | using-codex-exec 문서 codex-cli 0.142.5 현행화 | P1 | M | — | #861 | DONE (PR #967) |
| 023 | worktree-path-guard sibling worktree 오탐 제거 | P2 | S | — | #935 | DONE (PR #968) |

Status values: TODO | IN PROGRESS | DONE | BLOCKED (with one-line reason) | REJECTED (with one-line rationale)

## Dependency notes

- **hard**: 017은 005·016의 spike 보고서를 입력으로 사용 — 둘 다 DONE 후 착수.
- **soft**: 009는 007과 같은 파일·suite를 만지므로 007 먼저 머지 권장.
  015는 011이 `_folder-actions-lib.sh`를 수정하므로 011 먼저면 충돌 없음
  (반대 순서면 테스트 기대값 갱신 필요).
- 001↔004는 같은 백업 주제지만 001은 문서만, 004는 코드+테스트만 만진다.
- 005의 보고서는 롤백 절차에서 001의 `.dump` 복원 문서를 참조한다.
- 004는 #917 재개·백업 자세 구현(016 후속)의 안전망 — 그들보다 먼저가 이득.
- 007·009는 같은 파일 대상이지만 성격(버그 수정 vs 테스트)이 달라 분리
  (운영자 결정).
- NixOS/darwin 모듈 변경(002, 004, 011, 014)의 실 배포(`nrs`)와 실경로 확인은
  **운영자 후속 작업** — executor 게이트는 eval/flake-check/테스트까지.
- **가변 태그 digest 고정** finding은 독립 plan으로 승격하지 않고 005 보고서의
  권고안 절에서 판정한다 (운영자 결정 — 중복 회피).
- 019·020은 016 spike 보고서(#959)의 추천 (A)/(B) 구현 승격분 (운영자 결정:
  원본 위치 유지+백업, 오프사이트 R2, 키는 1Password, 템플릿 비활성 유지).
  020은 **운영자 사전 준비**(R2 버킷/토큰 + 1Password 항목) 완료 전 착수 불가.
  017 runbook의 "사전 게이트"는 019의 머지·적용·초회 미러 완료를 전제한다 —
  019는 유지보수 창 실행 전에 처리되는 것이 이상적.

## Dependency notes (021–023)

- 021–023은 상호 독립이며 001–020과도 파일이 겹치지 않는다.
- 021과 023은 둘 다 Claude 훅을 만지지만 대상 파일이 다르다
  (pinning-guard vs worktree-path-guard) — 순서 무관.

## Findings considered and rejected (재감사 방지)

- **nrs 락이 "같은 worktree + 죽은 PID"를 re-entry로 취급 (locks.sh)**: by-design.
  nrs 락은 세션 스코프다 — Stop hook(`nrs-session-cleanup.sh`)이 해제 책임을
  지므로, 같은 worktree의 죽은 PID는 "같은 세션의 이전 nrs 실행"이라는 정상
  경로이고 re-entry 시 미해제는 의도된 수명 관리다. 크로스 세션 크래시 잔존은
  30분 타임아웃 + `nrs-lock unlock`으로 self-heal.
- **Chrome CDP 9222가 컨테이너망에 `--no-sandbox`로 노출 (karakeep.nix)**:
  Karakeep 상류 표준 배포 패턴과 동일, 호스트/tailnet 비노출, 위협 모델상 앱
  침해 전제면 이득 미미 — not worth doing.
- **upload-immich.sh가 CLI 출력(파일명)을 로그/Pushover로 기록**: 단일 사용자
  본인 기기로 가는 알림에 본인 파일명 — 실질 위험 없음. not worth doing.
- **immich-update만 mk-update-module 미사용 (bespoke Nix 래퍼)**: divergence가
  커서(tailscale-wait, detectMajorMismatch, 커스텀 version-check) 헬퍼 흡수
  비용 대비 이득 불확실. #917 재개 시 같은 맥락에서 재판정.
- **docs/TRIAL_AND_ERROR.md 이중 소스화**: 실질 비용 낮음(historical log,
  스킬이 canonical). 역할 1줄 명시 이상은 not worth doing.
- **version-check.sh의 ERR trap이 비-JSON 2xx 응답에서 오탐 알림**: 트리거가
  드물고 영향이 오탐 알림 1건 수준 — 백로그 미만으로 판정.
- **EPIC-912-LIVING-PRD.md / EPIC-912-GOAL-PROMPT.txt 루트 잔존**: 커밋되지 않는
  로컬 문서(`.git/info/exclude`) — dead doc 아님.
- **flake 입력 lag**: nixpkgs/home-manager 등 전부 2026-06월분으로 신선 —
  finding 없음.

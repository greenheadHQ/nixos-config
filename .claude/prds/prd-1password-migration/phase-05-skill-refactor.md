# Phase 5: managing-secrets 스킬 리팩토링

Parent PRD: [PRD: Bitwarden(Vaultwarden) → 1Password 마이그레이션 + LLM 주도 개발 생태계](../prd-1password-migration.md)
Status: Not Started
Last Updated: 2026-05-27

## Objective

`managing-secrets` 스킬을 agenix 단일 backend에서 agenix + 1Password 양쪽 routing 스킬로 확장한다. SKILL.md 상단에 2단계 routing 매트릭스 + tag convention을 박제하고, 통합 inventory 표(name × storage × vault × age path × 소비처)로 한눈에 보는 secret 카탈로그를 제공한다. `evals/queries.json`의 vaultwarden 혼동 쌍을 1Password 컨텍스트로 재작성하여 reverse polarity 회귀를 방지한다.

## Context From Master PRD

- Goals covered: G-5 (routing 규칙 명문화)
- Success Criteria: SC-7 (routing 매트릭스 + inventory + queries.json)
- Requirements covered: FR-15, FR-16, FR-17, NFR-3
- Key scenarios touched: Scenario 1 (새 secret 어디 둘지)
- Constraint: SKILL.md ≤ 250줄. 초과 시 references/ 분할 트리거.

## Phase Discovery Gate

- [ ] 관련 코드/파일: `.claude/skills/managing-secrets/SKILL.md` (현재 129줄), `.claude/skills/managing-secrets/evals/queries.json` (vaultwarden 혼동 쌍 11-20행), `.claude/skills/managing-secrets/references/workflows.md`, `.claude/skills/managing-secrets/references/troubleshooting.md`
- [ ] 관련 테스트/fixture: `.claude/skills/managing-secrets/evals/queries.json` (eval 회귀)
- [ ] 관련 docs/spec/외부 참조: 다른 managing-* 스킬의 라우팅 패턴 (managing-minipc, managing-macos, managing-ssh)
- [ ] 관련 command 또는 도구: skill router eval harness (있다면)
- [ ] Phase 1-3가 완료되어 1Password 운영 패턴이 안정됨 (inventory 표 작성 가능)
- [ ] Phase 2b에서 reserved한 "확장 트리거 텍스트" Discoveries 회수
- [ ] Phase 2a mobile SSH follow-up 결정 상태 확인: 아래 "Phase 2a Mobile SSH Integration Policy"에 따라 분류

## Scope

### In Scope

- `managing-secrets/SKILL.md` 상단에 **routing 매트릭스** (압축된 표 1개) + tag convention 박제
- Automation vault sub-folder 또는 tag 컨벤션 명문화 (`system/`, `dev/`, `ssh/`)
- 통합 inventory 표 (SKILL.md inline 또는 `references/inventory.md`)
- 1Password 운영 절차 추가: SA token rotation 5단계, Service Account 발급, vault 생성, item naming convention, `op_get` helper 사용법
- SSH device key 운영 절차 추가(조건부): 아래 "Phase 2a Mobile SSH Integration Policy"를 따른다.
- `evals/queries.json`: 1Password 혼동/포함 쌍을 신규 추가. vaultwarden negative 쌍은 **Phase 5에서 제거**(소유자 결정 — 1Password 마이그레이션 스킬의 초점 정리, hosting-vaultwarden 자체 evals가 positive 검증을 커버). 당초 add-only(Phase 6 삭제) 계획에서 변경됨 — Phase Change Log 2026-06-01 참조
- SKILL.md frontmatter trigger 키워드 확장: `'1password', '1Password', 'op CLI', 'opnix', 'service account token', 'Automation vault', 'biometric unlock'`
- `NOT for Vaultwarden 비밀번호 관리자 (use hosting-vaultwarden)` line은 Phase 6에서 hosting-vaultwarden 스킬 삭제와 동시 제거 (본 phase에서는 변경하지 않음)
- Phase 2b에서 reserved한 확장 트리거 텍스트 박제: "추가 shell plugin 도입 조건 = (a) 해당 도구 secret을 .env로 export하는 패턴 ≥ 2건 발생 OR (b) agenix 평문 노출 위험 보고 1건"
- SKILL.md 줄수 측정 (`wc -l`) → 250줄 초과 시 references/ 분할 (references/agenix.md + references/1password.md)

### Out of Scope

- 새 managing-1password 스킬 신설 (NG-3)
- hosting-vaultwarden 스킬 삭제 (Phase 6)
- (변경됨) vaultwarden 쌍은 Phase 5에서 제거함 — Phase Change Log 2026-06-01 참조. Phase 6 잔여 작업은 hosting-vaultwarden 스킬 삭제 + 잔여 dead reference 정리

### Phase 2a Mobile SSH Integration Policy

Phase 5는 Phase 2a mobile SSH follow-up 정책을 새로 결정하지 않는다.

- 상태 판정은 Phase 2a [Closed Status Definition](./phase-02a-mac-ssh.md#closed-status-definition)을 따른다.
- 결정 상태가 `닫힘`이면 [Phase 2a Post-Merge Remediation](./phase-02a-mac-ssh.md#post-merge-remediation-termius-mobile-key-mismatch)의 확정 절차를 SKILL.md 또는 `references/1password.md`에 반영한다.
- 결정 상태가 `열림`이면 확정 Termius 절차 반영은 Phase 5 exit gate에서 제외하고, Phase 2a Post-Merge Remediation 링크와 follow-up tracking 위치 기록만 Phase 5 exit gate로 유지한다. 이때 tracking 위치는 master PRD Open Questions의 Phase 2a mobile SSH follow-up 항목과 Phase 2a Post-Merge Remediation anchor다. GitHub issue/#780 comment는 Phase 2a Policy Follow-Up의 Issue/PR tracking 질문이 닫히기 전까지 필수 tracking 위치가 아니다.

## Implementation Checklist

- [ ] 현재 SKILL.md 줄수 측정: `wc -l .claude/skills/managing-secrets/SKILL.md` (baseline 박제)
- [ ] SKILL.md 상단에 routing 매트릭스 표 신규 추가 (상위 description 직후):
  ```markdown
  ## Routing Matrix

  | 사용 주체 | Storage | Vault | Tag |
  |---|---|---|---|
  | NixOS systemd가 root로 부팅 시 자동 읽음 (컨테이너 API 토큰, 알림 토큰 등) | agenix | — | — |
  | 사용자 또는 LLM이 user-level shell에서 호출 (gh PAT, npm token, API key) | 1Password | Automation | `dev` |
  | 디바이스 SSH key 또는 emergency fallback | 1Password | Automation | `ssh` |
  | 개인 비밀번호 / 신용카드 / passkey | 1Password | Personal | — |

  - 같은 토큰이 양쪽 필요한 경우는 수동 이중 등록 (mirror 자동화 yagni)
  - 부팅 시 1Password SaaS 도달이 어려운 환경은 컨테이너 secret = agenix 영구 (A-3)
  ```
- [ ] SKILL.md에 통합 inventory 표 신규 추가 (또는 `references/inventory.md` 신규 파일):
  ```markdown
  ## Inventory

  | Name | Storage | Vault | age path | 소비처 |
  |---|---|---|---|---|
  | opnix-service-account-token.age | agenix | — | /run/agenix/opnix-service-account-token | opnix-secrets.service (MiniPC) |
  | pushover-system-monitor.age | agenix | — | /run/agenix/pushover-system-monitor | pushover-system-monitor.service |
  | immich-api-key.age | agenix | — | /run/agenix/immich-api-key | immich-server container |
  | karakeep-openai-key.age | agenix | — | /run/agenix/karakeep-openai-key | karakeep container |
  | ... | ... | ... | ... | ... |
  | github-pat | 1Password | Automation | — | gh CLI (Mac + MiniPC) |
  | mac-ssh | 1Password | Automation | — | Mac SSH agent |
  | iphone-ssh (backup copy) | 1Password | Automation | — | intended iPhone Termius identity; per-device status pending/confirmed by Phase 2a remediation |
  | ipad-ssh (backup copy) | 1Password | Automation | — | pending if included in Phase 2a remediation; otherwise not validated per Phase 2a scope decision |
  | emergency-ssh | 1Password | Automation | — | Mac fallback (~/.ssh/emergency_ed25519) |
  ```
- [ ] SKILL.md에 1Password 운영 절차 추가 섹션 (Service Account 발급 5단계, vault 생성, item naming, `op_get` 사용법, 90일 rotation):
- [ ] Phase 2a Mobile SSH Integration Policy 적용: 결정 상태가 `닫힘`이면 Phase 2a remediation anchor의 확정 Termius SSH 운영 절차를 추가
- [ ] Phase 2a Mobile SSH Integration Policy 적용: 결정 상태가 `열림`이면 Phase 2a Post-Merge Remediation 링크와 master PRD Open Questions의 Phase 2a mobile SSH follow-up 항목만 tracking 위치로 기록
- [ ] Phase 2b reserved 확장 트리거 텍스트 박제: "## Shell Plugin 확장 정책: 추가 shell plugin 도입 조건 = (a) 해당 도구 secret을 .env로 export하는 패턴 ≥ 2건 발생 OR (b) agenix 평문 노출 위험 보고 1건"
- [ ] SKILL.md frontmatter trigger 키워드 확장 (1Password 관련 추가)
- [ ] `evals/queries.json` 작업 (add-only):
  - [ ] 1Password 혼동 쌍 신규 추가 (예: "Service Account 발급 절차" `should_trigger=true`, "1Password Master Password 분실 복구" `should_trigger=true`, "op CLI biometric prompt 안 뜸" `should_trigger=true`)
  - [x] vaultwarden negative 쌍 제거 (소유자 결정 — 당초 comment marker 계획에서 변경, Phase Change Log 2026-06-01)
  - [ ] 신규 추가 후 eval harness 실행 (있다면) — 모든 항목 통과 확인
- [ ] SKILL.md 줄수 재측정: 250줄 이하 확인. 초과 시 references/ 분할 트리거:
  - `references/agenix.md` 신규 (agenix-only 워크플로: re-encrypt, host 추가, secrets.nix 패턴)
  - `references/1password.md` 신규 (1Password-only 워크플로: SA token rotation, op CLI 사용법, vault/item 관리, biometric unlock)
  - SKILL.md inline에는 routing matrix + inventory 표 (cross-cutting)만 유지
- [ ] eval harness 실행 (있다면) — `should_trigger=true/false` 모두 정상 분류 확인
- [ ] managing-secrets의 trigger 키워드가 다른 스킬과 충돌하지 않는지 확인: `rg -l "trigger.*1[Pp]assword" .claude/skills/ --glob '!managing-secrets/**'` 결과가 0건이어야 정상 (managing-secrets 자체는 의도적 매치라 제외). 결과 ≥ 1건이면 충돌 스킬과 트리거 분리 협의.

## Validation Strategy

- SKILL.md 줄수 측정 + 직접 읽고 routing 매트릭스/inventory가 한 화면에 들어오는지 확인. eval/queries.json은 skill router harness가 있다면 실행, 없다면 LLM 호출로 manual 회귀 확인 (`"새 GitHub PAT 1Password에 저장하려면?"` 같은 query가 managing-secrets로 라우팅됨).

## Validation Checklist

- [ ] Static check — markdown 형식 정합성 (md-lint 또는 manual)
- [ ] 자동 test — `evals/queries.json` 통과 (harness 있는 경우)
- [ ] API/CLI 검증 — N/A
- [ ] Browser/UI E2E — N/A
- [ ] Agent/dev browser check — N/A
- [ ] Mobile/app simulator — N/A
- [ ] Visual/screenshot check — N/A
- [ ] Observability/logging — N/A
- [ ] Manual smoke check — LLM에서 "SA token 90일 갱신 절차" 묻기 → managing-secrets routing 성공 + 답변에 박제된 5단계 등장
- [ ] 해당 시 error/empty/loading — invalid query (예: "Vaultwarden admin token 갱신") → 적절한 fallback (Phase 6 후 archive 안내 또는 NOT_APPLICABLE 응답)

## Exit Criteria

- [ ] Phase objective 달성 (routing 매트릭스 + inventory + 1Password 운영 절차 + evals 재작성)
- [ ] FR-15, FR-16, FR-17 구현
- [ ] NFR-3 (SKILL.md ≤ 250줄) 충족 또는 references/ 분할 완료
- [ ] Phase 2b reserved 확장 트리거 텍스트 박제 완료
- [ ] Phase 2a Mobile SSH Integration Policy 적용 결과 기록 완료
- [x] vaultwarden negative 쌍 Phase 5에서 제거 (Phase 6 잔여 = hosting-vaultwarden 스킬/dead reference 정리)

## Phase-End Multi-Pass Review

- [ ] 1. Intent/coverage — SC-7 달성
- [ ] 2. Correctness — routing 매트릭스가 모든 case (system / user / mixed)를 cover. inventory 표가 20개 .age(실측 — 당초 PRD의 23개는 STALE) + 1Password 항목 모두 포함
- [ ] 3. Simplicity — SKILL.md 줄수 250 이하 유지. 분할 시 references/ 2개로 한정
- [ ] 4. Code quality — markdown 표 형식 일관, trigger 키워드 sorted/dedup
- [ ] 5. Duplication/cleanup — vaultwarden 관련 dead reference는 Phase 6에서 처리. 본 phase에서 reverse polarity 신규 쌍 우선 추가
- [ ] 6. Security/privacy — inventory 표에 평문 token 누출 0. 1Password vault item 이름만 노출
- [ ] 7. Performance — SKILL.md 줄수 측정 후 분할 필요성 결정
- [ ] 8. Validation — eval harness 또는 manual LLM query 검증
- [ ] 9. Future-phase — Phase 6 hosting-vaultwarden 스킬 삭제 (vaultwarden eval 쌍은 Phase 5에서 제거 완료 — deprecation marker 미사용)
- [ ] 10. PRD sync — master PRD Status, Current Phase, Change Log 갱신

## Discoveries / Decisions

- SKILL.md 줄수: baseline 125줄 → 최종 166줄 (≤250 충족)
- 분할: 250줄 미만이라 routing matrix + inventory는 SKILL.md inline 유지. 운영 절차만 `references/1password.md`로 분리 (`references/agenix.md`는 기존 troubleshooting.md/workflows.md가 커버하므로 신설하지 않음)
- 신규 trigger 키워드 충돌 조사: `rg -l "trigger.*1[Pp]assword" .claude/skills/ --glob '!**/managing-secrets/**'` → 0건

## Phase Change Log

- 2026-05-17: Phase file created.
- 2026-05-26: Phase 2a mobile SSH follow-up을 Phase 5 조건부 scope로 반영. Follow-up 결정이 닫혔으면 확정 Termius 운영 절차를 문서화하고, 열려 있으면 Phase 2a Post-Merge Remediation 링크와 master PRD Open Questions의 Phase 2a mobile SSH follow-up 항목만 Phase 5 exit gate로 요구한다.
- 2026-06-01: Phase 5 구현 완료 (PR #878). routing 매트릭스 + 통합 inventory(.age 20개 + 1Password 항목) + `references/1password.md` 운영 절차 + frontmatter trigger 확장 + Shell Plugin 확장 정책 박제. 결정 변경: vaultwarden negative 쌍을 당초 add-only(Phase 6 삭제) 대신 Phase 5에서 제거 — 1Password 마이그레이션 스킬의 초점 정리, hosting-vaultwarden 자체 evals/queries.json이 positive 검증을 커버. 독립 검증(설계·코드 비판적 리뷰 + 전수 감사)으로 STALE 교정 반영: mobile-ssh=Termius keychain(1Password 미보관), shottr-license=Darwin-only HM 배포, SA token material=agenix `.age`(vault item은 github-pat), emergency 1Password item 이름=emergency-ssh(ssh key comment는 emergency-fallback). PRD 당초 예시의 `.age 23개`는 실측 20개로 정정.

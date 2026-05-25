# Phase 4: Apple Passwords Import

Parent PRD: [PRD: Bitwarden(Vaultwarden) → 1Password 마이그레이션 + LLM 주도 개발 생태계](../prd-1password-migration.md)
Status: Not Started
Last Updated: 2026-05-17

본 phase는 Phase 6 (Vaultwarden EOL)과 의존 없음 → 병렬 가능.

## Objective

iCloud Keychain (Apple Passwords 앱)에 잔존하는 비밀번호/TOTP/passkey를 1Password로 옮기되, CSV export의 field 매트릭스를 사전 실측하여 silent loss를 방지한다. iOS/macOS AutoFill 우선순위를 1Password로 변경하고 iCloud Keychain AutoFill을 비활성화하여 re-fragmentation을 차단한다. passkey는 lazy migration 정책을 박제하고 종료 조건을 명시한다.

## Context From Master PRD

- Goals covered: G-1 (vault 통합)
- Success Criteria: SC-5 (CSV import + TOTP/passkey 매트릭스 + iCloud disable)
- Requirements covered: FR-13, FR-14, NG-5
- Key scenarios touched: 없음 (사용자 일상 UX)
- Critical risk: Apple Passwords CSV는 통상 password/username만 보장. TOTP/passkey 보존 여부 사전 실측 필수.

## Phase Discovery Gate

- [ ] 관련 코드/파일: 없음 (사용자 GUI 작업)
- [ ] 관련 테스트/fixture: 없음
- [ ] 관련 docs/spec/외부 참조: https://support.apple.com/guide/passwords/export-passwords-mchl35b12625/mac, https://support.1password.com/import-csv/
- [ ] 관련 command 또는 도구: macOS Passwords 앱 (System Settings → Passwords), 1Password 데스크탑 앱
- [ ] iCloud Keychain이 macOS Sequoia(15) 이상 + iOS 18 이상 환경임 (Passwords 앱 GUI export 기능 가용성)
- [ ] Phase 1의 1Password 데스크탑 앱 설치 + 로그인 완료

## Scope

### In Scope

- Phase 4a: sample 3개 사전 export — password-only / TOTP 포함 / passkey 포함 항목 각 1개를 macOS Passwords 앱에서 export → CSV 파일 직접 열기 → field 매트릭스 박제
- Phase 4b: field 매트릭스 결과에 따른 정책 결정 (TOTP가 CSV에 포함되면 일괄 import, 미포함이면 TOTP는 별도 sub-phase로 서비스별 재설정 — 1Password 데스크탑이 QR 코드 스캔 기능 제공)
- Phase 4c: 전체 export → 1Password 데스크탑 import 실행. 결과 항목 수 일치 확인
- Phase 4d: macOS System Settings → Passwords → "AutoFill Passwords" 1Password만 체크, iCloud Passwords 토글 해제. iOS Settings → Passwords → AutoFill Passwords and Passkeys → 1Password만 활성화, iCloud Passwords 비활성화
- Phase 4e: passkey lazy migration 종료 조건 박제 — "분기별 (Q1/Q3) review trigger" + "Chrome+iPhone 활성 passkey 서비스 N건 임계" (N=20 권장, 사용자 조정 가능). 첫 review를 본 phase 종료 시점부터 90일 후로 calendar 등록 (Reminders 또는 1Password recurring item)

### Out of Scope

- 1Password GUI/CLI 설정 변경 (Phase 1)
- Vaultwarden 종료 (Phase 6 — 본 phase와 독립)
- Chrome/iPhone passkey 즉시 일괄 이전 (lazy migration 정책)

## Implementation Checklist

- [ ] Phase 4a sample export 실측:
  - [ ] macOS Passwords 앱 → 3개 sample 선택 후 File → Export Selected Passwords → CSV 생성
  - [ ] CSV 파일을 텍스트 에디터로 열어 컬럼 확인: Title, URL, Username, Password, Notes, OTPAuth (있는지) 등
  - [ ] passkey 항목이 CSV에 포함되는지 확인 (보통 미포함)
  - [ ] TOTP secret이 otpauth:// URI로 포함되는지 확인
  - [ ] **결과를 본 phase의 Discoveries에 박제**:
    ```
    | Field | password-only | TOTP 포함 | passkey 포함 |
    |---|---|---|---|
    | Title | ✓ | ✓ | ? |
    | URL | ✓ | ✓ | ? |
    | Username | ✓ | ✓ | ? |
    | Password | ✓ | ✓ | ? |
    | OTPAuth | — | ?✓/× | — |
    | Passkey | — | — | ?✓/× |
    ```
  - [ ] 사용자 PRD 갱신 결정 (TOTP 일괄 vs 별도 sub-phase)
- [ ] Phase 4b 정책 분기:
  - 분기 A (TOTP 포함되면): 전체 일괄 import 진행 (Phase 4c)
  - 분기 B (TOTP 미포함이면): Phase 4c는 password만 import, TOTP는 Phase 4c1 sub-phase로 서비스별 재등록 (1Password 데스크탑 + 모바일 1Password 앱 QR 스캔)
- [ ] Phase 4c 일괄 import:
  - [ ] macOS Passwords 앱 → File → Export All Passwords → CSV 전체 생성 (경로 기록 — 예: `~/Downloads/Passwords.csv`)
  - [ ] 1Password 데스크탑 → File → Import → CSV → Apple Passwords 옵션 선택 → 파일 지정 → vault = Personal (사용자 vault)
  - [ ] import 완료 후 1Password에서 항목 수 확인 → Apple Passwords 항목 수와 일치 검증
- [ ] **Phase 4c-cleanup CSV 평문 처분** (sample export + full export 모두 적용 — 평문 비밀번호가 디스크에 잔존하지 않도록):
  - [ ] 해당 CSV 파일을 secure delete: `rm -P <csv-path>` (BSD `rm -P`는 3-pass overwrite. 파일 1개당 수 초)
  - [ ] Finder Trash 비우기: `osascript -e 'tell app "Finder" to empty trash'`
  - [ ] Time Machine snapshot 결정: (a) `tmutil delete -p <csv-path>`로 해당 경로의 로컬 snapshot 제거 OR (b) Time Machine exclude 등록 (`tmutil addexclusion <csv-path>` — 추후 동일 경로 export 시 자동 제외) — 둘 중 선택 후 본 phase Discoveries에 박제
  - [ ] 검증: `find ~ -name '*assword*.csv' -mtime -7 2>/dev/null` 결과에 export CSV 부재
- [ ] (분기 B인 경우) Phase 4c1 sub-phase: TOTP 서비스 N건을 1Password 데스크탑/모바일 1Password 앱 QR 스캔으로 재등록. 완료 항목 체크리스트는 본 phase Discoveries에 박제 후 추적
- [ ] Phase 4d AutoFill 우선순위:
  - macOS: System Settings → Passwords → AutoFill Passwords and Passkeys → **1Password ON, iCloud Passwords OFF**
  - iOS (iPhone): Settings → Passwords → AutoFill Passwords and Passkeys → **1Password ON, iCloud Passwords OFF**
  - iPadOS (iPad): 동일 절차
  - 검증: Safari에서 임의 사이트 로그인 시도 → 1Password 팝업만 출현 (iCloud Passwords 팝업 부재)
- [ ] Phase 4e passkey lazy migration 종료 조건 박제:
  - 본 phase의 Discoveries / Decisions에 정책 텍스트 작성: "Passkey lazy migration 완료 정의: (a) 분기별 Q1/Q3 review trigger OR (b) Chrome+iPhone 활성 passkey 서비스 임계 (N=20) 도달 시 강제 migration 검토"
  - macOS Calendar 또는 1Password Reminders에 90일 후 "passkey migration review" 일정 등록
  - 활성 passkey 서비스 카운트 추적: 1Password Automation vault (또는 Personal) tag `passkey-pending`로 자동 import된 항목 카운트 = 미이전 카운트

## Validation Strategy

- Phase 4a는 manual 실측이 핵심 — 결과를 PRD에 박제하지 않으면 silent loss 위험. Phase 4c import는 항목 수 일치로 1차 검증, sample 5개 password 실제 사용 가능성 manual 확인. Phase 4d는 Safari 임의 사이트 로그인으로 popup 출현 검증.

## Validation Checklist

- [ ] Static check 통과 — N/A (코드 변경 없음)
- [ ] 자동 test — N/A
- [ ] API/CLI 검증 — N/A
- [ ] Browser/UI E2E — Safari에서 임의 사이트 로그인 popup이 1Password만 출현
- [ ] Agent/dev browser check — playwright-cli로 자동화 가능하나 yagni
- [ ] Mobile/app simulator — 실기 iPhone/iPad에서 manual
- [ ] Visual/screenshot check — Phase 4a CSV field 매트릭스 + Phase 4d Settings 캡처
- [ ] Observability/logging — 1Password 데스크탑 import 결과 dialog 항목 수 일치 확인
- [ ] Manual smoke check — sample 5개 password를 1Password에서 호출 → 실제 로그인 성공
- [ ] 해당 시 error/empty/loading — import 실패 항목 (특수문자 등) 처리

## Exit Criteria

- [ ] Phase objective 달성 (CSV 매트릭스 실측 + 일괄 import + iCloud AutoFill 비활성화 + passkey 종료 조건 박제)
- [ ] FR-13, FR-14 구현
- [ ] passkey lazy migration 종료 조건이 calendar/Reminders에 등록되어 향후 강제 review 가능
- [ ] **CSV 평문 처분 완료**: 모든 export CSV (sample + full)가 secure delete + Trash 비움 + Time Machine 처리됨. `find ~ -name '*assword*.csv' -mtime -7` 0건
- [ ] Phase 6과 의존 없음 (병렬 진행 가능)

## Phase-End Multi-Pass Review

- [ ] 1. Intent/coverage — SC-5 달성
- [ ] 2. Correctness — TOTP 미포함 시 분기 B 처리, AutoFill popup 검증
- [ ] 3. Simplicity — 단순 GUI 작업 + 정책 박제. 자동화 yagni
- [ ] 4. Code quality — 코드 변경 없음. PRD/Discoveries 박제 품질
- [ ] 5. Duplication/cleanup — iCloud Keychain 기존 항목은 보존 (참고용). 중복 제거는 시간이 흐른 후 자연 정리
- [ ] 6. Security/privacy — CSV export 파일은 import 후 즉시 안전 삭제 (`rm` + Empty Trash + Time Machine 백업도 검토)
- [ ] 7. Performance — N/A
- [ ] 8. Validation — Safari popup 실측 + 항목 수 일치
- [ ] 9. Future-phase — Phase 5에 passkey migration 추적 도구가 필요할지 검토 (현재는 manual)
- [ ] 10. PRD sync — master PRD Status, Current Phase, Change Log 갱신

## Discoveries / Decisions

- (Phase 4a 실측 결과 매트릭스 박제 예정)
- (TOTP 분기 결정 박제 예정)
- passkey lazy migration 종료 조건: 분기별 Q1/Q3 review trigger + 활성 passkey 서비스 임계 N=20

## Phase Change Log

- 2026-05-17: Phase file created.

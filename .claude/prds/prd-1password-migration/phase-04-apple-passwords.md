# Phase 4: Apple Passwords Import

Parent PRD: [PRD: Bitwarden(Vaultwarden) → 1Password 마이그레이션 + LLM 주도 개발 생태계](../prd-1password-migration.md)
Status: Done (GUI/실기 + 박제 완료 — PR 대기)
Last Updated: 2026-05-26

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

- [x] Phase objective 달성 (CSV 매트릭스 실측 + 62개 import + iCloud AutoFill 비활성화 + passkey 처리)
- [x] FR-13 구현 (분기 A 일괄 import). FR-14 구현 — macOS 재정의(iCloud OFF + 브라우저 extension; "1Password ON 토글"은 macOS에 부재), iOS 시스템 토글
- [x] passkey 처리 완료 (Google 1개가 기존 1Password passkey로 충족). 원안 lazy 종료조건 + 90일 calendar는 폐기(over-engineering) — Discoveries 참조
- [x] **CSV 평문 처분 완료**: `/bin/rm -P` secure delete + Trash 미경유 + TM 백업 미설정(N/A). `find ~ -name '*assword*.csv' -mtime -7` 0건
- [x] Phase 6과 의존 없음 (병렬 진행 가능)

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

> 아래 실측 결과가 SSOT다. 위 Implementation Checklist의 Phase 4d/4e 절차는 깨진 가정 2건(아래)에 따라 재정의되었다.

### CSV field 매트릭스 (2026-05-26 실측, 전체 export 1회)

macOS 26.5 Passwords 앱 "모든 암호를 파일로 내보내기"(Export All Passwords to File) CSV 헤더 6컬럼 (확정):

| Field | 포함 | 비고 |
|---|---|---|
| Title | ✓ | |
| URL | ✓ | |
| Username | ✓ | 빈 값 1건 허용 |
| Password | ✓ | 빈 값 0 |
| Notes | ✓ | |
| OTPAuth | ✓ | `otpauth://` URI (TOTP 설정 항목만, 없으면 빈 값) |

- 레코드 68개. OTPAuth 채워진 행 4 = 고유 2서비스(OpenAI, Twitch; Twitch는 www/http/https 3중복).
- passkey·Wi-Fi·Sign in with Apple·비소유 공유그룹은 CSV 미포함(Apple 설계). passkey는 별도 FIDO Credential Exchange 전용.
- CSV는 평문(Apple 공식 경고).

### TOTP 분기 결정 → 분기 A (일괄 import)

TOTP가 otpauth로 CSV에 포함되므로 일괄 import. 단 함정: 1Password의 "Safari" importer는 password만 가져오고 TOTP를 버린다 → **generic CSV import + OTPAuth 컬럼을 `one-time password` 라벨로 매핑**해야 보존. 실측 통과(Twitch 항목 6자리 코드 주기 동작 확인).

### import 결과

- CSV 68개 중 사용자 선별 6건 제거 → **62개 개인 vault import 완료**.
- green.com SSH key 항목 2건(public+private, 평문): Passwords 앱에 SSH key 저장은 부적절 + Phase 2a 1Password SSH agent와 중복 + 미사용 키 → import 제외/삭제(rotation 불필요, 사용자 확인).
- Twitch 3중복(www/http/https)은 1개로 정리. sample 로그인 정상.

### 깨진 PRD 가정 2건 (공식 출처 교차검증: Apple/1Password/FIDO)

1. **macOS 1Password는 시스템 AutoFill credential provider로 등록하지 않는 설계**(1Password 공식). System Settings "자동 완성 및 암호" 목록에 1Password가 안 뜨고 `pluginkit` 0건도 정상. macOS 자동채움은 (a) 브라우저 extension, (b) Universal Autofill(System Settings > Privacy & Security > Accessibility 권한 + `Cmd+\`). → **Phase 4d의 macOS "1Password ON 토글" 가정은 성립하지 않음**. macOS는 iCloud AutoFill OFF만 수행, 1Password는 브라우저 extension이 담당. iOS/iPadOS는 시스템 토글(1Password ON, iCloud OFF) 유효.
2. **Apple "앱으로 내보내기"는 FIDO Credential Exchange(CXP/CXF)지만 macOS 1Password는 전 버전 import 미구현**(iOS 26/iPadOS 26·Android 14+만 수신). "호환 가능한 앱 없음" 팝업은 정상 동작. → macOS에서 CXP 직접 이전 불가, CSV 경로가 정답.

### passkey 결정 (P2)

- Apple Passwords passkey는 Google 1개뿐. 실측 결과 **2024-09-14에 이미 1Password로 Google passkey가 등록돼 있었고 로그인 검증 통과** → passkey 마이그레이션 사실상 완료(추가 등록 불필요).
- Apple(iCloud 키체인) Google passkey는 백업으로 잔존 유지(사용자 결정). 둘 다 동작.
- CXP 결합안(iOS에서 passkey만 전송) 기각: FIDO CXF 선택 단위가 "로그인 항목"이라 password 동반 → CSV import분과 중복 + 이전 passkey 작동 리스크. 1개 항목엔 과함.

### Phase 4e 단순화 (lazy migration 정책 폐기)

passkey가 1개이고 이미 1Password에 있으므로, 원안의 "lazy migration 종료 조건(분기별 Q1/Q3 review + N=20 임계) + 90일 review calendar"는 over-engineering → **폐기**. 신규 passkey는 향후 1Password에 직접 생성하는 일상 워크플로로 충분(YAGNI).

### CSV 평문 처분 (Phase 4c-cleanup)

- `/bin/rm -P`(BSD 3-pass overwrite)로 secure delete. Trash 미경유.
- **Time Machine destination 미설정 + 로컬 snapshot 0개** → CSV가 백업/snapshot에 잔존한 적 없음. PRD의 `tmutil delete`/`addexclusion` 택일은 **N/A**.
- 종료 게이트 `find ~ -name '*assword*.csv' -mtime -7` **0건 통과**.

### 환경 메모

- 1Password 8.12.21 + macOS 26.5에 Universal Autofill 회귀 버그 보고(브라우저 밖 `Cmd+\` 채움 실패, beta 8.12.24 수정). 브라우저 내 채움은 extension으로 정상 → 본 Phase 진행 영향 없음.
- 1Password import는 중복 자동 병합/스킵 안 함(append). 중복은 import 후 수동 정리 전제.

## Phase Change Log

- 2026-05-17: Phase file created.
- 2026-05-26: Phase 4 GUI/실기 완료 + 박제. 공식 출처(Apple/1Password/FIDO) 교차검증 조사로 깨진 가정 2건 규명(macOS 1Password 시스템 AutoFill 미등록 설계 / macOS CXP import 미구현). CSV 매트릭스 실측(헤더 6컬럼, 68 records, TOTP otpauth 포함 → 분기 A). generic CSV import로 62개(68−6 선별) 개인 vault 적재 + TOTP 동작 검증 + green.com SSH·Twitch 중복 정리. CSV `/bin/rm -P` secure delete + 종료 게이트 통과(TM 백업 미설정 → N/A). passkey는 기존 1Password Google passkey(2024-09)로 충족, iCloud passkey 백업 유지. Phase 4d macOS 재정의(iCloud AutoFill OFF + 브라우저 extension), iOS 시스템 토글. Phase 4e lazy 정책 폐기(passkey 1개·기존재).

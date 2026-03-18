# Shottr 크레덴셜 관리 (상세)

## 샌드박스 앱 구조

Shottr는 macOS 샌드박스 앱이며 plist가 `~/Library/Containers/cc.ffitch.shottr/Data/Library/Preferences/cc.ffitch.shottr.plist`에 저장됩니다. `~/Library/Preferences/`에는 존재하지 않습니다. 다만 `defaults read/write cc.ffitch.shottr ...`는 `cfprefsd`를 통해 Container plist에 투명하게 접근하므로, 추가 경로 지정 없이 정상 동작합니다.

## 라이센스 이중 저장 구조

| 저장소 | 키 | 용도 |
|--------|---|------|
| macOS Keychain | `Shottr-license`, `Shottr-vault` | Primary (서버 검증 후 기록) |
| defaults (plist) | `kc-license`, `kc-vault` | Secondary (UI pre-fill용) |

- Keychain 삭제 -> defaults에서 라이센스를 UI에 pre-fill하되, "Activate" 버튼 1회 클릭 필요
- defaults 삭제 -> Keychain에서 자동 복원 (라이센스 유지)
- 양쪽 모두 삭제 -> 미등록 상태
- "Registered to:" 이메일은 **Keychain** (`Shottr-vault`)에서 읽힘 -- defaults의 `kc-vault`와 무관
- `kc-vault`(defaults)의 정확한 역할은 불명 (Activate 시 서버 통신 데이터 캐시로 추정). 안전을 위해 둘 다 기록

## Nix 관리 전략

`defaults write kc-license + kc-vault`로 라이센스를 pre-fill합니다. 완전 자동 활성화는 불가능하지만(Keychain은 Nix로 관리 불가), 새 맥북에서 **라이센스 키를 기억/입력할 필요 없이 Activate 버튼 1회 클릭만으로 활성화**할 수 있습니다.

## HM activation에서의 주의사항

- Home Manager activation 스크립트는 최소한의 PATH로 실행 -> macOS 시스템 명령어는 절대 경로 필수 (`/usr/bin/defaults`, `/usr/bin/killall`)
- `defaults write`에서 `{...}` 패턴은 plist dictionary로 해석 시도 -> JSON 형태 문자열은 반드시 `-string` 플래그 명시
- 예: `/usr/bin/defaults write cc.ffitch.shottr KeyboardShortcuts_area -string '{"carbonKeyCode":20,"carbonModifiers":768}'`

## defaults 테스트 시 SIGTERM vs SIGKILL

- `killall Shottr`(SIGTERM)로 종료하면 Shottr가 종료 시점에 메모리 캐시를 plist에 재기록
- defaults 조작 테스트 시에는 반드시 `kill -9 $(pgrep -x Shottr)` (SIGKILL) 사용 후 `defaults delete/write` 실행

> 테스트 환경: Shottr 1.9.1 (build 128, versionCode 10901), macOS Darwin 24.6.0, 2026-02-18

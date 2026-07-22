# Shottr 크레덴셜 관리 (상세)

## 샌드박스 앱 구조

Shottr는 macOS 샌드박스 앱이며 plist가 `~/Library/Containers/cc.ffitch.shottr/Data/Library/Preferences/cc.ffitch.shottr.plist`에 저장됩니다. `~/Library/Preferences/`에는 존재하지 않습니다. 일반 설정과 수동 진단 read는 `defaults`를 사용하지만, 라이센스 pre-fill은 비밀값을 argv에 싣지 않도록 전용 CFPreferences writer에 stdin으로 전달합니다.

## 라이센스 이중 저장 구조

| 저장소 | 키 | 용도 |
|--------|---|------|
| macOS Keychain | `Shottr-license`, `Shottr-vault` | Primary (서버 검증 후 기록) |
| defaults (plist) | `kc-license`, `kc-vault` | Secondary (UI pre-fill용) |

- Keychain 삭제 -> defaults에서 라이센스를 UI에 pre-fill하되, "Activate" 버튼 1회 클릭 필요
- defaults 삭제 -> Keychain에서 자동 복원 (라이센스 유지)
- 양쪽 모두 삭제 -> 미등록 상태
- "Registered to:" 이메일은 Keychain (`Shottr-vault`)에서 읽힘 -- defaults의 `kc-vault`와 무관
- `kc-vault`(defaults)의 정확한 역할은 불명 (Activate 시 서버 통신 데이터 캐시로 추정). 안전을 위해 둘 다 기록

## Nix 관리 전략

container preferences의 `kc-license`와 `kc-vault`를 pre-fill합니다. 전용 writer는 대상 preference basename과 key만 argv로 받고 값은 stdin으로 읽습니다. 완전 자동 활성화는 불가능하지만(Keychain은 Nix로 관리 불가), 새 맥북에서 라이센스 키를 기억/입력할 필요 없이 Activate 버튼 1회 클릭만으로 활성화할 수 있습니다.

## HM activation에서의 주의사항

- Home Manager activation 스크립트는 최소한의 PATH로 실행 -> macOS 시스템 명령어는 절대 경로 필수 (`/usr/bin/defaults`, `/usr/bin/killall`)
- `defaults write`에서 `{...}` 패턴은 plist dictionary로 해석 시도 -> JSON 형태 문자열은 반드시 `-string` 플래그 명시
- Shottr 라이센스와 vault 값은 `/usr/bin/defaults ... -string "$secret"` 형태로 전달하지 않는다.
  Nix가 빌드한 native writer에 `builtin printf`의 stdin으로 넘겨 process argv와 경고 로그에서
  값을 제외한다. inherited/exported `kc_license`/`kc_vault`도 caller와 helper subshell에서 제거해
  timeout/writer child environment에 값을 복제하지 않는다.
- Shottr container의 `defaults` read/write는 `SystemPolicyAppData` prompt를 만들 수 있으므로,
  activation은 Nix store의 GNU timeout을 사용하고 수동 진단은 repo devShell에서
  `timeout -k 5s 30s`로 감싼다. bare `defaults` 호출은 사용하지 않는다.
- 예: `timeout -k 5s 30s /usr/bin/defaults write cc.ffitch.shottr KeyboardShortcuts_area -string '{"carbonKeyCode":20,"carbonModifiers":768}'`
- exit 124/137이면 같은 activation의 후속 Shottr write를 생략하고 나머지 activation을 계속한다.
  원격 기본 경로는 prompt 승인을 요구하지 않는 이 bounded skip이다. Shottr preference를 꼭
  갱신해야 해 운영자가 AppData grant를 별도로 선택한 경우에만 prompt를 직접 승인하고, `nrs` 및
  그 과정의 앱 재실행에 대한 action-time confirmation을 받은 뒤 `nrs --force`로 다시 적용한다.

## defaults 테스트 시 SIGTERM vs SIGKILL

- `killall Shottr`(SIGTERM)로 종료하면 Shottr가 종료 시점에 메모리 캐시를 plist에 재기록한다.
- cache overwrite를 배제해야 하는 진단에서만 SIGKILL을 사용한다. 앱 종료 직전에 반드시
  action-time confirmation을 받고, 확인 뒤 아래처럼 현재 Shottr PID만 종료한다.

```bash
/usr/bin/pgrep -x Shottr | while IFS= read -r pid; do
  /bin/kill -9 "$pid"
done
if timeout -k 5s 30s /usr/bin/defaults read cc.ffitch.shottr kc-license \
  >/dev/null 2>&1; then
  printf 'kc-license: present\n'
else
  rc=$?
  printf 'kc-license: unavailable (exit %s)\n' "$rc" >&2
fi
```

실제 라이센스 값은 출력하지 않고 presence/pass-fail만 확인한다. 테스트가 끝난 뒤 앱을 다시
열거나 `nrs --force`를 실행하기 전에도 각각 action-time confirmation을 받는다. 앱 또는 OS가
업데이트되면 bounded read와 activation pass/fail을 다시 확인한다.

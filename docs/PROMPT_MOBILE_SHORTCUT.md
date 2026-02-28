# iOS Shortcut 기반 프롬프트 모바일 원탭 복사

iPhone에서 prompt preset을 선택하고 변수를 입력하면, MiniPC에서 렌더링된 프롬프트가 클립보드에 복사된다.

## 전제조건

- iPhone에 Tailscale 설치 + VPN 연결
- Shortcuts 앱 (기본 설치)
- MiniPC에 SSH 키 등록 완료

## Quick Start (10분 온보딩)

### 1. SSH 키 생성

iPhone의 Shortcuts 앱에서 SSH 키를 생성한다:

1. Shortcuts 앱 → 새 Shortcut → `Run Script over SSH` 액션 추가
2. Host: `100.79.80.95`, User: `greenhead`
3. Authentication: `SSH Key` 선택
4. `Generate New Key` (Ed25519 권장)
5. 생성된 공개키를 복사하여 프로젝트 관리자에게 전달

### 2. MiniPC에 키 등록

`libraries/constants.nix`의 `sshKeys.iphoneShortcuts` 값을 실제 공개키로 교체한 뒤 `nrs` 적용.

### 3. Shortcut 빌드

아래 "Shortcut 플로우 상세" 섹션을 따라 Shortcut을 구성한다.

### 4. 검증

1. Tailscale VPN 연결 확인
2. Shortcut 실행 → `bugfix` 프리셋 선택 → 클립보드 확인
3. `feature-dev-full` 프리셋 선택 → 변수 3개 입력 → 클립보드 확인

## SSH 명령 레퍼런스

### PATH/locale 설정 템플릿

iOS Shortcuts의 `Run Script over SSH`는 non-interactive shell이므로 PATH를 명시 설정해야 한다:

```bash
export LC_ALL=en_US.UTF-8; export PATH="/run/current-system/sw/bin:/etc/profiles/per-user/greenhead/bin:/home/greenhead/.nix-profile/bin:/home/greenhead/.local/bin:$PATH"
```

### 명령 예시

```bash
# preset 목록 조회
prompt-render --list-presets --format json
# → {"ok":true,"presets":["bugfix","code-review",...]}

# 렌더링 (변수 없는 preset)
prompt-render --preset bugfix --non-interactive --format json --stdout-only
# → {"ok":true,"preset":"bugfix","rendered":"...","missing":[],"invalid":[],"error":""}

# 렌더링 (변수 누락 → 변수 목록 반환)
prompt-render --preset feature-dev-full --non-interactive --format json --stdout-only
# → {"ok":false,"preset":"feature-dev-full","rendered":"","missing":["DA_MODEL_1","DA_MODEL_2","DA_TOOL"],...}

# 렌더링 (변수 전달)
prompt-render --preset feature-dev-full --var DA_TOOL='codex exec' --var DA_MODEL_1='gpt-5.3-codex' --var DA_MODEL_2='gpt-5.3-codex' --non-interactive --format json --stdout-only
```

## Shortcut 플로우 상세

> **iOS Shortcuts 주의사항** (실제 빌드 중 확인된 사항):
>
> - **줄바꿈 주입**: `Choose from List`에서 선택된 값에 `\n`이 붙는다. SSH 명령에서 `printf '%s' ... | tr -d '\n\r'`로 제거해야 한다.
> - **Boolean 비교 불가**: JSON의 `ok: true`를 Shortcuts 조건문에서 문자열 `"true"`로 비교할 수 없다. 대신 `rendered` 필드가 "값이 있음(has any value)"인지로 분기한다.
> - **사전 파싱 필수**: 매 SSH 응답마다 `입력에서 사전 가져오기`(Get Dictionary from Input) 액션이 필요하다. SSH 결과에서 직접 `사전 값 가져오기`를 할 수 없다.
> - **유형 지정**: `사전 값 가져오기`에서 `rendered`를 추출할 때 유형을 반드시 **텍스트**로 설정해야 한다. 기본값(파일)이면 클립보드에 빈 값이 복사된다.

### Step 1: preset 목록 조회

```text
[Run Script over SSH]
  Host: 100.79.80.95 | User: greenhead | Auth: SSH Key
  Script: export LC_ALL=en_US.UTF-8; export PATH="/run/current-system/sw/bin:/etc/profiles/per-user/greenhead/bin:/home/greenhead/.nix-profile/bin:/home/greenhead/.local/bin:$PATH"; prompt-render --list-presets --format json
```

### Step 2: JSON 파싱 + 에러 체크

```text
[Get Dictionary from Input] → SSH 결과를 Dictionary로 파싱

[Get Dictionary Value] key="ok"
[If] ok is empty:
  [Show Alert] "서버 응답 오류 — VPN/SSH 상태를 확인하세요"
  [Stop Shortcut]
[End If]
```

> `Get Dictionary from Input`이 비-JSON 응답을 받으면 빈 딕셔너리를 반환한다. `ok` 키가 빈 값이면 파싱 실패로 판단한다.

### Step 3: preset 선택

```text
[Get Dictionary Value] key="presets" → 배열
[Choose from List] prompt="프리셋 선택" → selectedPreset
```

### Step 4: 렌더링 시도

```text
[Run Script over SSH]
  Script: ...PATH설정...; prompt-render --preset "$(printf '%s' 'selectedPreset' | tr -d '\n\r')" --non-interactive --format json --stdout-only
```

> `Choose from List` 결과에 줄바꿈(`\n`)이 붙는 iOS Shortcuts 동작 특성 때문에, `printf | tr -d '\n\r'`로 줄바꿈을 제거한다. 이 패턴 없이 직접 `--preset 'selectedPreset'`로 전달하면 `preset not found: \nbugfix` 에러가 발생한다.

### Step 5: 결과 처리

```text
[Get Dictionary from Input]                        ← 두 번째 SSH 결과를 사전으로 파싱
[Get Dictionary Value] key="rendered" type=텍스트   ← 유형을 반드시 '텍스트'로 설정

[If] rendered has any value:                        ← Boolean이 아닌 rendered 존재 여부로 분기
  [Copy to Clipboard] rendered
  [Show Notification] "✓ 복사 완료"
[Otherwise]:
  [Get Dictionary Value] key="missing" → missingVars
```

> **주의**: 조건문에서 `ok == true` 비교를 사용하지 않는다. iOS Shortcuts는 JSON boolean을 문자열과 비교할 수 없어 항상 실패한다. `rendered` 필드의 존재 여부("값이 있음")로 분기하는 것이 안정적이다.

### Step 6: 변수 입력 (ok=false, missing 존재 시)

```text
[Set Variable] varArgs = ""
[Repeat with Each Item] in missingVars:
  [Ask for Input] prompt="Repeat Item 입력:" type=텍스트
  [Text] varArgs + " --var '" + Repeat Item + "=" + Provided Input + "'"
  [Set Variable] varArgs = Text결과
[End Repeat]

[Run Script over SSH]
  Script: ...PATH설정...; prompt-render --preset "$(printf '%s' 'selectedPreset' | tr -d '\n\r')" varArgs --non-interactive --format json --stdout-only

[Get Dictionary from Input]
[Get Dictionary Value] key="rendered" type=텍스트
[If] rendered has any value:
  [Copy to Clipboard] rendered
  [Show Notification] "✓ 복사 완료"
[Otherwise]:
  [Get Dictionary Value] key="error"
  [Show Alert] "오류: error"
[End If]
```

### 전체 액션 구조도

```text
 1  SSH (list-presets)
 2  입력에서 사전 가져오기
 3  presets 값 가져오기
 4  목록에서 선택
 5  SSH (render — printf|tr로 줄바꿈 제거)
 6  입력에서 사전 가져오기
 7  rendered 값 가져오기 (유형: 텍스트)
 8  조건문 (rendered 값이 있음)
 │  ├─ 참: 클립보드 복사 → 알림
 │  └─ 그렇지 않으면:
 │     A  missing 값 가져오기
 │     B  변수 설정 varArgs = ""
 │     C  각 항목 반복 (missing)
 │     │  C-1 입력 요청 (유형: 텍스트)
 │     │  C-2 텍스트 조합 (varArgs + --var 'KEY=VALUE')
 │     │  C-3 변수 설정 varArgs = 텍스트 결과
 │     D  반복 끝
 │     E  SSH (render + varArgs — printf|tr로 줄바꿈 제거)
 │     F  입력에서 사전 가져오기
 │     G  rendered 값 가져오기 (유형: 텍스트)
 │     H  클립보드 복사
 │     I  알림
 9  조건문 끝
```

## 에러 처리

| 상황 | 동작 |
|------|------|
| VPN 미연결 / SSH 접속 실패 | iOS 기본 에러 알림 (Shortcuts 레벨) |
| SSH 성공, 비정상 응답 | Get Dictionary 파싱 실패 → ok 빈 값 → "서버 응답 오류" 알림 |
| 서버 논리 에러 (preset 미발견 등) | ok=false, error 필드 표시 |
| 변수 누락 | ok=false, missing 배열 → 변수 입력 UI |

## Fallback: `push()` 사용법

VPN/SSH가 불가한 상황에서는 Mac 또는 MiniPC 터미널에서 `push()` 함수를 사용:

```bash
push "$(prompt-render --preset bugfix --non-interactive --stdout-only)"
```

> 1024자 제한 주의. 긴 프롬프트는 잘릴 수 있다.

## 트러블슈팅

| 증상 | 원인 | 해결 |
|------|------|------|
| SSH 연결 시간 초과 | VPN 미연결 | Tailscale 앱에서 VPN 연결 확인 |
| "Permission denied" | SSH 키 미등록 | `libraries/constants.nix` → `sshKeys.iphoneShortcuts` 확인 후 `nrs` |
| "command not found: prompt-render" | PATH 미설정 | SSH 명령에 PATH export 포함 확인 |
| "jq not found" JSON 에러 | Home Manager PATH 누락 | PATH에 `/etc/profiles/per-user/greenhead/bin` 포함 확인 |
| "preset not found: \nbugfix" | Choose from List 줄바꿈 주입 | SSH 명령에서 `printf '%s' ... \| tr -d '\n\r'`로 제거 |
| 클립보드에 빈 값 복사 | rendered 값 유형이 `파일` | `사전 값 가져오기`에서 유형을 **텍스트**로 설정 |
| 조건문이 항상 false | JSON boolean 비교 불가 | `ok == true` 대신 `rendered` 필드의 "값이 있음" 조건 사용 |
| Tailscale SSH 사용 시 에러 | Tailscale SSH 버그 ([#12485](https://github.com/tailscale/tailscale/issues/12485)) | 전통 sshd 사용 (기본 설정) |
| 클립보드 복사 안 됨 | Shortcut 권한 문제 | 설정 → Shortcuts → 권한 확인 |

## 보안 정책

- **Tailscale VPN 전용**: 공용 인터넷 노출 없음
- **비밀정보 하드코딩 금지**: SSH 키, API 키 등을 Shortcut에 직접 입력하지 않음
- **SSH 키 인증만 사용**: 비밀번호 인증 비활성화

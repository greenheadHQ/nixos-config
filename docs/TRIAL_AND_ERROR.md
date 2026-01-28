# Trial and Error 기록

이 문서는 nixos-config 저장소에서 시도했다가 실패한 작업들을 기록합니다.

## 목차

- [2026-01-28: OSC 52 클립보드 - Termius iOS 미지원](#2026-01-28-osc-52-클립보드---termius-ios-미지원)
- [2026-01-18: Termius 한국어 입력 시 터미널 UI 깨짐 문제](#2026-01-18-termius-한국어-입력-시-터미널-ui-깨짐-문제)
- [2026-01-17: rip (프로세스 종료 CLI) Flake input 추가 실패](#2026-01-17-rip-프로세스-종료-cli-flake-input-추가-실패)
  - [후속 문제: nix flake update로 의도치 않은 전체 업데이트](#후속-문제-nix-flake-update로-의도치-않은-전체-업데이트)
- [2026-01-13: Atuin 동기화 모니터링 시스템 구현 시행착오](#2026-01-13-atuin-동기화-모니터링-시스템-구현-시행착오)
- [2026-01-13: Atuin 계정 마이그레이션 실패](#2026-01-13-atuin-계정-마이그레이션-실패)
- [2026-01-11: Claude Code 유령 플러그인 해결](#2026-01-11-claude-code-유령-플러그인-해결)
- [2026-01-10: cat → bat alias 제거 (호환성 문제)](#2026-01-10-cat--bat-alias-제거-호환성-문제)
- [2026-01-10: VS Code customLabels에서 동적 앱 이름 추출 실패](#2026-01-10-vs-code-customlabels에서-동적-앱-이름-추출-실패)
- [2024-12-25: duti로 .html/.htm 기본 앱 설정 실패](#2024-12-25-duti로-htmlhtm-기본-앱-설정-실패)
- [2024-12-24: Anki 애드온 Nix 선언적 관리 시도 (보류)](#2024-12-24-anki-애드온-nix-선언적-관리-시도-보류)
  - [목표](#목표)
  - [시도한 방식들](#시도한-방식들)
    - [방식 1: AnkiWeb 직접 다운로드 (실패)](#방식-1-ankiweb-직접-다운로드-실패)
    - [방식 2: 로컬 소스 패키징 (반려)](#방식-2-로컬-소스-패키징-반려)
    - [방식 3: GitHub 저장소 활용 (보류)](#방식-3-github-저장소-활용-보류)
  - [방식 3의 실패 원인](#방식-3의-실패-원인)
  - [교훈](#교훈)
  - [대상 애드온 목록 (참고용)](#대상-애드온-목록-참고용)
  - [결론](#결론)

---

## 2026-01-28: OSC 52 클립보드 - Termius iOS 미지원

> **환경**:
> - **miniPC OS**: NixOS 26.05 (nixos-unstable)
> - **클라이언트**: iPhone (Termius), MacBook Pro (Ghostty)
> - **목표**: SSH 세션에서 `pbcopy`/`xclip` 명령으로 로컬 클립보드에 복사

### 배경

미니PC는 headless NixOS 서버라서 X11/Wayland가 없어 실제 xclip/wl-copy가 작동하지 않음.
SSH 세션에서 클립보드를 사용하려면 **OSC 52 escape sequence**가 유일한 방법.

### 시도한 것

1. **zsh 함수로 pbcopy/xclip/wl-copy 오버라이드**
   - SSH 세션에서만 활성화되도록 `$SSH_TTY` 체크
   - tmux 내부에서는 DCS passthrough 사용
   - tmux.conf에 `allow-passthrough on` 추가

2. **실제 스크립트 파일로 변경**
   - Claude Code `/copy` 명령이 zsh 함수를 인식 못함
   - `~/.local/bin/pbcopy`, `xclip`, `wl-copy`로 스크립트 설치
   - 이후 `/copy` 명령은 작동함

### 결과

- **Mac Ghostty**: OSC 52 지원 → **성공**
- **iPhone Termius**: OSC 52 미지원 → **실패**

### 교훈

1. **터미널 앱의 OSC 52 지원 여부 먼저 확인**
   - Ghostty, iTerm2, Kitty: 지원
   - Termius: **미지원**
   - Blink Shell: 지원 (유료)

2. **Termius의 한계**
   - 이미 한국어 입력 문제도 있었음 (2026-01-18 기록 참조)
   - OSC 52 미지원으로 클립보드 연동도 불가
   - iOS에서 SSH 클라이언트로 Termius 대신 **Blink Shell** 고려 필요

3. **headless 서버 클립보드의 근본적 한계**
   - 서버 측에서 할 수 있는 건 OSC 52 전송뿐
   - 클라이언트(터미널 앱)가 지원하지 않으면 방법 없음

### 대안

- **Blink Shell** (iOS, $19.99) - OSC 52 지원 확인됨
- **Secure ShellFish** (iOS) - 지원 여부 미확인
- 당분간 iPhone에서는 수동 복사 (텍스트 선택 → 복사)

---

## 2026-01-18: Termius 한국어 입력 시 터미널 UI 깨짐 문제

> **환경**:
> - **miniPC OS**: NixOS 24.11 (nixos-unstable-small)
> - **클라이언트**: iPhone 16 Pro (iOS 18.2.1), MacBook Pro M3 Max (macOS 15.2)
> - **Termius 버전**: iOS 9.2.1 (9020001), Mac 9.2.1
> - **Tailscale 버전**: iOS 1.80.3, miniPC 1.78.1
> - **연결 방식**: SSH 및 Mosh (Tailscale VPN 경유)
> - **Shell**: zsh + Starship + Atuin + zsh-autosuggestion + zsh-syntax-highlighting

### 문제 현상

iPhone/Mac Termius에서 miniPC로 SSH/Mosh 접속 시:
1. **한국어 입력 시 터미널 UI 깨짐** - 커서 위치가 어긋남
2. **Starship 프롬프트가 엉뚱한 위치에 렌더링**됨
3. **Backspace로 삭제하면 안 되는 문자**(❯ 등)도 삭제됨
4. 영어 입력은 정상, **한국어 입력만 문제**

참고: Mac Ghostty 터미널에서는 동일 환경에서 한국어 입력이 정상 작동함.

### 시도한 방법들 (모두 실패)

#### 1. locale 영어로 변경

**가설**: 한국어 locale(`ko_KR.UTF-8`)이 문제일 수 있음

**변경 내용** (`modules/nixos/configuration.nix`):
```nix
# Before
i18n.defaultLocale = "ko_KR.UTF-8";
i18n.extraLocaleSettings = {
  LC_TIME = "ko_KR.UTF-8";
};

# After
i18n.defaultLocale = "en_US.UTF-8";
# extraLocaleSettings 제거
```

**결과**: ❌ CLI 메시지가 영어로 바뀌었지만, 한국어 입력 문제는 그대로

**유지**: locale은 영어로 유지 (사용자 선호)

#### 2. zsh COMBINING_CHARS 옵션 추가

**가설**: macOS에만 있는 `setopt COMBINING_CHARS`가 NixOS에 없어서 유니코드 처리가 다를 수 있음

**변경 내용** (`modules/shared/programs/shell/nixos.nix`):
```nix
programs.zsh.initContent = lib.mkMerge [
  (lib.mkBefore ''
    # 유니코드 결합 문자 처리 (wide character 지원)
    setopt COMBINING_CHARS
  '')
];
```

**결과**: ❌ 효과 없음

**유지**: 해가 되지 않으므로 유지

#### 3. Starship 이모지 → ASCII 대체

**가설**: Starship 프롬프트의 wide character(🌐, ❯ 등)가 터미널 커서 위치 계산을 방해

**변경 내용** (`modules/shared/programs/shell/default.nix`):
```nix
programs.starship.settings = {
  character = {
    success_symbol = "[>](bold green)";  # ❯ 대신 >
    error_symbol = "[>](bold red)";
  };
  hostname = {
    ssh_symbol = "";
    format = "in [$hostname]($style) ";  # 🌐 제거
  };
  # ... 기타 이모지 제거
};
```

**결과**: ❌ 효과 없음

**롤백**: 이모지 설정 제거, 기본값 복구

#### 4. Starship 완전 비활성화

**가설**: Starship 자체가 문제일 수 있음

**변경 내용**:
```nix
programs.starship.enable = lib.mkForce false;
```

**결과**: ❌ 기본 zsh 프롬프트에서도 동일 문제 발생

**롤백**: Starship 활성화 복구

#### 5. Atuin 비활성화

**가설**: Atuin이 zle(Zsh Line Editor)를 후킹하여 IME와 충돌

**변경 내용**:
```nix
programs.atuin.enable = lib.mkForce false;
```

**결과**: ❌ 효과 없음

**롤백**: Atuin 활성화 복구

#### 6. zsh-syntax-highlighting 비활성화

**가설**: 구문 강조가 입력 버퍼를 조작하여 IME와 충돌

**변경 내용**:
```nix
programs.zsh.syntaxHighlighting.enable = lib.mkForce false;
```

**결과**: ❌ 효과 없음

**롤백**: 활성화 복구

#### 7. zsh-autosuggestion 비활성화

**가설**: 자동 완성이 입력 버퍼를 조작하여 IME와 충돌

**변경 내용**:
```nix
programs.zsh.autosuggestion.enable = lib.mkForce false;
```

**결과**: ❌ 효과 없음 (Atuin, syntax-highlighting과 함께 모두 비활성화해도 동일)

**롤백**: 활성화 복구

### 추가 발견 사항

1. **Mac Termius에서도 동일 문제 발생**
   - iPhone만의 문제가 아니라 Termius 앱 자체의 문제
   - Mac에서 하드웨어 키보드로 한국어 입력해도 동일 문제 발생

2. **Termius CJK 설정 확인**
   - "CJK Input In Terminal" 옵션이 있지만, 이를 활성화해도 **문제 해결 안 됨**
   - 하드웨어 키보드에서도 소프트웨어 키보드와 동일한 문제 발생

3. **IME 조합 창(Pre-edit area) 미지원**
   - Mac Ghostty: 한글 조합 중인 글자가 별도 영역(pre-edit area)에서 처리됨
   - Termius: 조합 중인 글자가 바로 터미널에 전송되어 커서 위치가 어긋남

### 결론

**Termius 앱 자체가 한국어 IME를 제대로 처리하지 못함** (소프트웨어/하드웨어 키보드 모두)

NixOS 설정으로는 **해결 불가능**. Termius 앱의 근본적인 한계.

---

### 임시 해결책 (Workaround)

완전한 해결책은 없지만, 다음 방법으로 **사용 가능한 수준**으로 만들 수 있음:

#### 1. 화면 새로고침으로 렌더링 복구

**문제 상황**: 한국어 입력/출력 후 터미널 화면이 깨져 보임 (커서 위치 오류, 글자 겹침 등)

**해결 방법**:
1. 화면 하단 중앙-왼쪽의 **`<` 버튼** 탭 (세션 목록으로 이동)
2. 다시 해당 세션 탭하여 돌아옴
3. 화면이 **정상적으로 다시 렌더링**됨

**원리**: 세션에서 나갔다 돌아오면 Termius가 터미널 화면을 처음부터 다시 그림

**적용 시나리오**:
- Claude Code 등에서 **한국어가 실시간으로 출력**될 때 화면이 깨지는 경우
- 프롬프트가 엉뚱한 위치에 표시되는 경우
- 문자가 겹쳐 보이거나 커서 위치가 이상한 경우

#### 2. Termius Input 기능 사용 (한국어 입력 시 권장)

**문제 상황**: 프롬프트에 직접 한국어를 입력하면 실시간으로 화면이 깨짐

**해결 방법**:
1. 키보드 위의 **텍스트 입력 필드** (Termius Input) 활용
   - "Use voice typing here..." 라고 표시된 영역
2. 이 영역에서 한국어를 **전부 작성**
3. 오른쪽 **파란색 전송 버튼(↑)** 또는 **엔터키** 탭
4. 작성한 내용이 **한 번에 프롬프트에 붙여넣기**됨

**장점**:
- 한글 조합이 **입력 필드에서 완료**된 후 터미널에 전송됨
- 실시간 입력이 아니므로 커서 위치 오류 방지
- 이전 입력 내역도 확인 가능 (히스토리 기능)

**단점**:
- 실시간 타이핑 피드백이 없음
- 긴 명령어 입력 시 불편할 수 있음

#### 사용 시나리오별 가이드

| 시나리오 | 권장 방법 | 설명 |
|----------|-----------|------|
| **영어 명령어 입력** | 직접 입력 | 문제 없음 |
| **한국어가 포함된 명령어** | Termius Input 사용 | `echo "한글"` 등 |
| **Claude Code 프롬프트 입력** | Termius Input 사용 | 한국어 지시사항 입력 |
| **Claude Code 한국어 출력 후** | `<` 버튼으로 새로고침 | 출력 완료 후 화면 복구 |
| **일반 작업 (ls, cd 등)** | 직접 입력 | 영어만 사용하므로 문제 없음 |

#### 한계

1. **실시간 한국어 출력**은 여전히 깨짐
   - Claude Code가 한국어로 응답할 때 화면이 실시간으로 깨짐
   - 출력 완료 후 `<` 버튼으로 새로고침 필요

2. **완벽한 해결책 아님**
   - 매번 새로고침하는 불편함 존재
   - "바이브코딩" 경험이 다소 저하됨

3. **Termius 앱 업데이트 필요**
   - 근본적 해결은 Termius 개발팀의 IME 처리 개선 필요
   - 버그 리포트 제출 권장

---

### 대안 앱 (미검증)

다음 앱들이 대안으로 언급되지만, **실제 테스트하지 않았으므로 동일한 문제가 발생할 수 있음**:

| 앱 | 가격 | 특징 | 검증 여부 |
|----|------|------|-----------|
| **Blink Shell** | $19.99 | Chromium HTerm 기반, Mosh 네이티브 지원 | ❓ 미검증 |
| **Prompt 3** | $19.99 | Panic 개발 | ❓ 미검증 |
| **ServerCat** | 무료/Pro | 서버 모니터링 + SSH | ❓ 미검증 |

> **주의**: 인터넷에서 "인코딩 처리 우수"라고 언급되더라도, 한국어 IME 문제는 별개일 수 있음.
> 유료 앱 구매 전 무료 체험판이나 리뷰를 확인하거나, 직접 한국어 입력 테스트 후 결정 권장.

### 교훈

1. **터미널 앱의 IME 지원은 앱마다 다름** - NixOS/zsh 설정과 무관할 수 있음
2. **Mac에서 정상이라고 다른 앱에서도 정상인 것은 아님** - 앱별로 테스트 필요
3. **wide character 문제는 복잡함** - 터미널, shell, 프롬프트, IME 모두 관여
4. **하나씩 비활성화해서 원인 격리**하는 방법이 디버깅에 효과적
5. **하드웨어 키보드가 해결책이 아닐 수 있음** - Termius의 경우 소프트웨어/하드웨어 무관하게 동일 문제
6. **완벽한 해결이 없을 때는 workaround 문서화**가 중요

### 관련 이슈/참고 자료

- [Starship Issue #6923: Unicode prompt cursor positioning](https://github.com/starship/starship/issues/6923)
- [Blink Shell Issue #524: Broken unicode with mosh](https://github.com/blinksh/blink/issues/524)
- [Termius iOS Changelog](https://termius.com/changelog/ios-changelog) - CJK hardware keyboard 지원 언급
- [React Native iOS 15+ CJK Issue](https://github.com/facebook/react-native/issues/32503)

---

## 2026-01-17: rip (프로세스 종료 CLI) Flake input 추가 실패

> **환경**: nixpkgs nixos-unstable-small (2026-01-16), nix-darwin 26.05, macOS (Apple Silicon)
>
> [rip](https://github.com/cesarferreira/rip)은 터미널에서 프로세스를 퍼지 검색으로 찾아 종료하는 Rust CLI 도구입니다.

### 목표

rip을 Nix flake input으로 추가하여 선언적으로 관리하려 했습니다.

### 시도한 방식

**1단계: flake.nix에 input 추가**

```nix
# inputs 섹션
rip = {
  url = "github:cesarferreira/rip";
  inputs.nixpkgs.follows = "nixpkgs";  # nixpkgs 버전 통일
};

# specialArgs에 패키지 전달
specialArgs = {
  # ...
  rip = inputs.rip.packages.${system}.default;
};
```

**2단계: home.nix에서 사용**

```nix
{ ..., rip, ... }:
# ...
home.packages = with pkgs; [ ... ] ++ [ rip ];
```

### 발생한 오류

```
error: darwin.apple_sdk_11_0 has been removed as it was a legacy compatibility stub;
see <https://nixos.org/manual/nixpkgs/stable/#sec-darwin-legacy-frameworks>
for migration instructions
```

### 원인 분석

1. **rip의 flake.nix가 제거된 API 사용**: rip은 macOS 빌드 시 `darwin.apple_sdk.frameworks.{Security,SystemConfiguration}`을 사용하는데, 이는 내부적으로 `darwin.apple_sdk_11_0`을 참조함

2. **최신 nixpkgs에서 제거됨**: nixpkgs unstable에서 `darwin.apple_sdk_11_0`이 제거되고 `darwin.apple_sdk`로 통합됨

3. **follows 제거해도 동일한 문제**: rip의 자체 nixpkgs도 최신 버전이라 같은 오류 발생

### 가능했던 대안들

| 방식 | 장점 | 단점 |
|------|------|------|
| **Overlay로 직접 패키징** | Nix 순수성 유지, 수정된 apple_sdk 사용 가능 | 유지보수 필요, rip 업스트림 추적 어려움 |
| **Homebrew로 관리** | 간단, 바로 사용 가능 | Nix 순수성 저하 |
| **rip 프로젝트에 PR** | 근본적 해결 | 시간 소요, 머지 불확실 |

### 교훈

1. **외부 flake를 input으로 추가할 때는 먼저 호환성 확인 필요**
   - 특히 macOS에서 `darwin.apple_sdk` 관련 의존성이 있는 패키지는 주의
   - `nix build github:owner/repo` 등으로 사전 테스트 권장

2. **`inputs.nixpkgs.follows` 설정의 양면성**
   - 장점: nixpkgs 버전 통일로 빌드 캐시 효율화
   - 단점: 외부 프로젝트가 특정 nixpkgs 버전에 의존할 경우 호환성 깨짐

3. **nixpkgs 변경 사항 추적 중요**
   - `darwin.apple_sdk_11_0` 제거는 [nixpkgs#darwin-legacy-frameworks](https://nixos.org/manual/nixpkgs/stable/#sec-darwin-legacy-frameworks) 참고
   - 레거시 API 제거는 점진적으로 진행되므로 외부 프로젝트가 뒤처질 수 있음

4. **모든 것을 Nix로 관리할 필요는 없음**
   - Homebrew가 더 적합한 경우도 있음 (특히 빠르게 변하는 CLI 도구들)
   - "선언적 관리"와 "실용성" 사이의 균형 필요

### 결론

rip은 현재 최신 nixpkgs와 호환되지 않아 Nix로 관리하지 않기로 결정. 필요 시 Homebrew(`brew install cesarferreira/tap/rip`) 또는 Cargo(`cargo install rip-cli`)로 설치.

### 후속 문제: nix flake update로 의도치 않은 전체 업데이트

#### 상황

- rip input 롤백 과정에서 `nix flake update` 실행
- **의도**: rip만 제거
- **결과**: 4개 inputs 전부 업데이트 (nixpkgs, home-manager, nix-darwin, nix-vscode-extensions)

#### 원인

- `nix flake update`는 **모든** inputs를 최신으로 갱신하는 명령어
- rip만 제거하려면 다른 방법을 사용했어야 함

#### 올바른 방법

**특정 input만 업데이트:**

```bash
nix flake update <input-name>              # Nix 2.19+
nix flake lock --update-input <input-name> # 구버전 호환
```

**input 제거 (flake.nix에서 삭제 후):**

```bash
nix flake lock  # update가 아님! lock만 재생성
```

#### nix-darwin에서 변경사항 미리 확인하는 방법

```bash
# 1. 빌드만 수행 (적용 안 함)
darwin-rebuild build --flake .

# 2. nvd로 비교 (권장)
nvd diff /run/current-system ./result

# 3. 상세 분석 (크기 포함)
nix store diff-closures /run/current-system ./result
```

#### nvd vs nix store diff-closures 비교

**nvd (nix-visualize-diff)** - 권장:

| 항목 | 내용 |
|------|------|
| **역할** | Nix closure의 패키지 버전 변경을 시각화 |
| **설치** | `pkgs.nvd` (nixpkgs 포함) |
| **출력** | `[U*] firefox: 84.0.1 → 84.0.2` 형식, 색상 강조 |
| **장점** | 인간 중심 UX, 핵심 변경만 표시, 가독성 우수 |
| **단점** | 외부 도구 설치 필요, 크기 정보 없음 |

**nix store diff-closures**:

| 항목 | 내용 |
|------|------|
| **역할** | 두 closure 간 모든 차이 표시 (크기 포함) |
| **설치** | 불필요 (Nix 2.4+ 기본 제공) |
| **출력** | `dolphin: 20.08.1 → 20.08.2, +13.9 KiB` |
| **장점** | 기본 제공, 상세 정보, 스크립팅 친화적 |
| **단점** | 장황한 출력, 가독성 낮음 |

**추천**: 일반 사용은 nvd, 상세 분석은 nix store diff-closures

#### 교훈

1. `nix flake update`는 **모든** inputs를 최신으로 갱신
2. 특정 input만 조작하려면 `nix flake lock` 또는 `nix flake update <name>` 사용
3. 업데이트 전 `darwin-rebuild build` + `nvd diff`로 변경사항 미리 확인
4. flake.lock 변경 시 사용자 동의 필수

> **참고**: 이번 업데이트는 nvd 설치 전이라 사전 확인 없이 진행됨.
> nvd는 이번 커밋에서 추가하여 **다음 업데이트부터** 활용 예정.

---

## 2026-01-13: Atuin 동기화 모니터링 시스템 구현 시행착오

> **테스트 환경**: atuin 18.10.0, macOS (Apple Silicon)
>
> Atuin 동기화 상태를 모니터링하는 시스템을 구현하면서 발견한 중요한 사실들과 시행착오를 기록합니다.

### 목표

1. Hammerspoon 메뉴바에 🐢 아이콘으로 동기화 상태 표시
2. 동기화 지연 시 알림 전송 (Pushover, macOS 알림)
3. 설정값 중앙 관리 (하드코딩 제거)

### 시행착오 1: `last_sync_time` 파일이 업데이트되지 않음

**초기 구현**: `~/.local/share/atuin/last_sync_time` 파일의 내용을 파싱하여 마지막 동기화 시간 확인

**문제**: `atuin sync`를 실행해도 `last_sync_time` 파일이 업데이트되지 않음

```bash
# sync 전
$ cat ~/.local/share/atuin/last_sync_time
2026-01-13T07:26:31.004161Z

# sync 후 (변화 없음!)
$ atuin sync
0/0 up/down to record store
Sync complete! 53 items in history database

$ cat ~/.local/share/atuin/last_sync_time
2026-01-13T07:26:31.004161Z  # 동일
```

**원인**: atuin 18.x부터 **record-based sync (v2)**를 사용하면서 `last_sync_time` 파일은 더 이상 업데이트되지 않음. 이 파일은 레거시 sync v1용.

### 시행착오 2: `records.db` mtime도 업데이트되지 않음

**두 번째 시도**: `records.db` 파일의 수정 시간(mtime)을 사용

**문제**: `atuin sync` 실행 시 동기화할 데이터가 없으면 (0/0 up/down) 파일이 수정되지 않음

```bash
$ ls -la ~/.local/share/atuin/records.db
.rw-------@ 94k glen 13 Jan 16:54  # mtime 고정

$ atuin sync
0/0 up/down to record store
Sync complete!

$ ls -la ~/.local/share/atuin/records.db
.rw-------@ 94k glen 13 Jan 16:54  # 변화 없음
```

**원인**: 데이터베이스 파일은 실제 데이터 변경이 있을 때만 수정됨.

### 최종 해결: `atuin doctor`의 `last_sync` 값 사용

**세 번째 시도**: `atuin doctor` 명령의 JSON 출력에서 `last_sync` 값 추출

```bash
$ atuin doctor 2>&1 | grep -o '"last_sync": "[^"]*"'
"last_sync": "2026-01-13 8:12:42.22629 +00:00:00"
```

이 값은 atuin 내부에서 관리되며, sync가 실행될 때마다 정확하게 업데이트됨.

**구현**:

```lua
-- Lua (Hammerspoon)
local output = hs.execute("atuin doctor 2>&1")
local lastSyncStr = output:match('"last_sync":%s*"([^"]+)"')
```

```bash
# Bash (watchdog 스크립트)
LAST_SYNC_RAW=$(atuin doctor 2>&1 | grep -o '"last_sync": "[^"]*"' | cut -d'"' -f4)
```

### 시행착오 3: `auto_sync`가 백그라운드 주기 동기화가 아님

**오해**: `sync_frequency = "1m"` 설정이 1분마다 자동으로 백그라운드 sync를 실행한다고 생각

**실제 동작**: `auto_sync`는 **터미널에서 명령어를 실행한 후**에만 동작

```
# 잘못된 이해
sync_frequency = "1m"  → 1분마다 백그라운드 sync? ❌

# 실제 동작
sync_frequency = "1m"  → 명령어 실행 후, 마지막 sync로부터 1분이 지났으면 sync 시도 ✅
```

**결과**: 터미널을 사용하지 않으면 sync가 발생하지 않음 → 3분 전이 마지막 동기화인 이유

### 해결: daemon 모드 활성화

`~/.config/atuin/config.toml`에 daemon 설정 추가:

```toml
[sync]
records = true  # sync v2 활성화

[daemon]
enabled = true
sync_frequency = 60  # 초 단위 (문자열 "1m"이 아님!)
```

그리고 `atuin daemon`을 launchd로 자동 시작:

```nix
launchd.agents.atuin-daemon = {
  enable = true;
  config = {
    Label = "com.green.atuin-daemon";
    ProgramArguments = [ ".../atuin" "daemon" ];
    RunAtLoad = true;
    KeepAlive = true;
  };
};
```

### 시행착오 4: 하드코딩된 설정값

**문제**: 설정값이 여러 파일에 중복 정의됨

```lua
-- atuin_menubar.lua
local syncThresholdHours = 24
local logRetentionDays = 30
```

```nix
-- default.nix
syncThresholdHours = 24;
logRetentionDays = 30;
```

**해결**: Single Source of Truth 패턴 적용

```
default.nix (설정값 정의)
    │
    ├──▶ JSON 파일 생성 → Hammerspoon에서 읽기
    │
    └──▶ 환경변수 → watchdog 스크립트에서 읽기
```

### 시행착오 5: Hammerspoon에서 atuin 못 찾음

**문제**: 메뉴바에서 "지금 동기화" 버튼을 눌러도 로그에 "Attempting sync..." 메시지가 없음

**원인**: Hammerspoon의 PATH에 atuin 경로가 없음

```lua
-- 스크립트의 PATH
/run/current-system/sw/bin
$HOME/.nix-profile/bin
/opt/homebrew/bin
...

-- atuin 실제 경로 (누락!)
/etc/profiles/per-user/glen/bin/atuin
```

**해결**: PATH에 per-user 경로 추가

```bash
export PATH="/etc/profiles/per-user/$USER/bin:..."
```

### 최종 구현 결과

| 항목 | 초기 | 최종 |
|------|------|------|
| sync 상태 소스 | `last_sync_time` 파일 | `atuin doctor` 출력 |
| 임계값 | 24시간 | 5분 |
| 상태 체크 주기 | 1시간 | 10분 |
| 백그라운드 sync | 없음 | daemon 모드 (60초) |
| 설정 관리 | 하드코딩 | JSON + 환경변수 |
| 스크립트 이름 | `atuin-sync-monitor` | `atuin-watchdog` |

### 교훈

1. **공식 문서만으로는 부족함**: atuin의 `auto_sync`, `sync_frequency` 동작 방식은 문서에 명확히 설명되어 있지 않음. 실제 테스트와 소스 코드 분석이 필요.

2. **레거시 vs 현재**: `last_sync_time` 같은 파일이 존재해도 현재 버전에서 사용되는지 확인 필요. atuin은 sync v1 → v2로 전환하면서 많은 내부 구조가 변경됨.

3. **단일 소스 원칙**: 설정값이 여러 곳에 분산되면 디버깅이 어려움. 처음부터 중앙 관리 설계 권장.

4. **PATH 문제**: Nix 환경에서 Hammerspoon, launchd 등 외부 실행 환경은 쉘과 다른 PATH를 가짐. 명시적으로 설정 필요.

---

## 2026-01-13: Atuin 계정 마이그레이션 실패

> 테스트 환경: atuin 18.10.0 (nixpkgs), 18.11.0 (GitHub 릴리스), macOS Apple Silicon

### 목표

1. 기존 계정(glen)에서 새 계정(greenhead)으로 마이그레이션
2. 62,000개 이상의 히스토리 보존
3. 동기화 모니터링 시스템 구축

### 초기 상태

```bash
$ cat ~/.local/share/atuin/last_sync_time
2025-09-26T04:11:39.71577ZZ  # 약 4개월 전!

$ atuin status
Error: There was an error with the atuin sync service: Status 404.
```

- `atuin sync`는 "Sync complete!" 출력하지만 실제로 동기화 안 됨
- `last_sync_time` 업데이트 안 됨

### 시도 과정

#### 1단계: 새 계정 생성 시도

```bash
# 백업
cp ~/.local/share/atuin/{history.db,key,records.db} ~/.local/share/atuin/*.backup-20260113

# 로그아웃 후 새 계정 등록
atuin logout
atuin register -u greenhead -e <email>
```

**문제**: 새 계정으로 로그인해도 `atuin status`에서 동일한 404 오류

#### 2단계: 데이터 초기화 및 재시도

```bash
rm -f ~/.local/share/atuin/{history.db,key,session,host_id,records.db,...}
atuin login -u greenhead
```

**문제**: 서버에서 기존 히스토리 다운로드 시 encryption key 불일치

```
Error: attempting to decrypt with incorrect key.
currently using k4.lid.XXX..., expecting k4.lid.YYY...
```

#### 3단계: 백업 key 복원 시도

```bash
cp ~/.local/share/atuin/key.backup-20260113 ~/.local/share/atuin/key
atuin sync
```

**결과**:
- 서버에 두 개의 호스트 존재 (기존 + 새로 생성)
- 각 호스트가 다른 key로 암호화된 데이터 보유
- 어떤 key를 사용해도 일부 데이터 복호화 실패

#### 4단계: 버전 업그레이드 시도

```bash
# 18.11.0 직접 다운로드
curl -sLO https://github.com/atuinsh/atuin/releases/download/v18.11.0/atuin-aarch64-apple-darwin.tar.gz
./atuin-aarch64-apple-darwin/atuin status
```

**결과**: 동일한 404 오류. 클라이언트 버전 문제가 아님.

#### 5단계: 소스 코드 분석

```bash
git clone https://github.com/atuinsh/atuin.git ~/IdeaProjects/atuin-source
```

**발견** (`crates/atuin-server/src/router.rs`):

```rust
// Sync v1 routes - can be disabled in favor of record-based sync
if settings.sync_v1_enabled {
    routes = routes
        .route("/sync/status", get(handlers::status::status))
        // ...
}
```

**근본 원인**: Atuin 클라우드 서버(`api.atuin.sh`)가 Sync v1을 비활성화함
- `/sync/status` 엔드포인트가 더 이상 존재하지 않음
- `atuin status`는 v1 API를 사용하므로 404 반환
- `atuin sync`는 v2 API (`/api/v0/*`)를 사용하므로 정상 작동

### 최종 결과

| 항목 | 결과 |
|------|------|
| 계정 마이그레이션 | ❌ 포기 (key 충돌 해결 불가) |
| 기존 히스토리 보존 | ❌ 손실 (백업 파일 삭제됨) |
| 동기화 모니터링 | ✅ 구현 완료 |
| `atuin status` 404 | ⚠️ 서버 측 문제, 해결 불가 |

### 교훈

1. **백업은 여러 곳에**: 작업 중에 백업 파일이 삭제됨. 별도 경로에도 백업 필요.

2. **Encryption key는 신중하게**:
   - 새 계정 로그인 시 새 key가 자동 생성됨
   - 기존 key를 사용하려면 로그인 프롬프트에서 입력 필요
   - key가 다르면 서버 데이터 복호화 불가

3. **404 오류의 다양한 원인**:
   - 처음에는 세션/인증 문제로 추정
   - 실제로는 서버 API 비활성화 (Sync v1 deprecated)

4. **소스 코드 분석의 중요성**:
   - 에러 메시지만으로는 원인 파악 어려움
   - 실제 서버/클라이언트 코드를 읽어야 정확한 원인 발견

### 관련 파일

| 파일                                                        | 설명                  |
| ----------------------------------------------------------- | --------------------- |
| `modules/darwin/programs/atuin/default.nix`                 | launchd 에이전트 설정 |
| `modules/darwin/programs/atuin/files/atuin-sync-monitor.sh` | 모니터링 스크립트     |

### 향후 계획

- [ ] Atuin GitHub에 이슈 제출 (status 404 문제)
- [ ] 집 맥북에서 동일한 설정 적용
- [ ] 기존 히스토리는 포기, 새로 시작

---

## 2026-01-11: Claude Code 유령 플러그인 해결

> 테스트 환경: Claude Code 2.1.4, macOS

### 배경

`settings.json`의 `enabledPlugins`에서 플러그인 프로퍼티를 직접 삭제하면 **유령 플러그인(ghost plugin)** 문제가 발생:

| 상태 | 증상 |
|------|------|
| `/plugin` 명령 | 플러그인이 "설치됨"으로 표시 |
| 설정 변경 | 활성화/비활성화 토글 불가 |
| 플러그인 기능 | 동작하지 않음 |

### 시도 1: 마켓플레이스 재설치 (실패)

```bash
claude plugin marketplace remove claude-plugins-official
claude plugin marketplace add anthropics/claude-plugins-official
```

**결과**: ❌ 유령 플러그인 여전히 존재

마켓플레이스를 재설치해도 기존 `enabledPlugins` 상태와의 동기화 문제는 해결되지 않음.

### 해결: settings.json에 유령 플러그인 직접 명시

**원리**: Claude Code가 플러그인을 인식하려면 `enabledPlugins`에 해당 플러그인이 존재해야 함. 유령 상태에서는 CLI도 플러그인을 찾지 못함.

**해결 순서**:

1. `settings.json`에 유령 플러그인을 다시 명시:
   ```json
   "enabledPlugins": {
     "ghost-plugin-name@marketplace": true
   }
   ```

2. Claude Code 재시작 (또는 `/plugin` 명령으로 확인)

3. CLI로 플러그인 제거:
   ```bash
   claude plugin uninstall ghost-plugin-name@marketplace --scope user
   ```

4. 정상적으로 제거됨 확인

### 교훈

1. **플러그인 제거는 반드시 CLI 사용**
   - `settings.json` 직접 편집으로 플러그인을 삭제하면 동기화 문제 발생
   - `claude plugin uninstall` 명령 사용 필수

2. **유령 플러그인 복구 방법**
   - `settings.json`에 유령 플러그인을 다시 추가하여 Claude Code가 인식하게 만든 후 CLI로 제거
   - 마켓플레이스 재설치로는 해결 불가

3. **Nix 선언적 관리 시 주의**
   - `mkOutOfStoreSymlink`로 `settings.json` 관리 시, 직접 편집이 가능하므로 실수 가능
   - 플러그인 관련 변경은 항상 Claude Code CLI 사용 권장

---

## 2026-01-10: cat → bat alias 제거 (호환성 문제)

> 테스트 환경: bat 0.26.1, macOS cat

### 배경

`cat` 명령어를 `bat`으로 alias하여 기본 파일 출력에 구문 강조를 적용하려 했음.

```nix
# modules/shared/programs/shell/default.nix
home.shellAliases = {
  # 파일 출력 (bat 사용)
  cat = "bat";
};
```

### 기대

`bat`이 `cat`의 완전한 상위호환이라고 가정:

- 모든 `cat` 옵션이 `bat`에서도 동일하게 작동
- 기존 스크립트나 명령어가 영향받지 않음

### 실패 원인

**`bat`은 `cat`의 상위호환이 아님.** 일부 옵션은 호환되지만, 핵심 진단 옵션들이 에러를 발생시킴.

macOS cat 옵션: `cat [-belnstuv]`

| 옵션 | macOS cat 동작 | bat 0.26.1 동작 |
|------|----------------|-----------------|
| `-v` | 비출력 문자 표시 (`^A`, `^[` 등) | ❌ 에러: `unexpected argument '-v' found` |
| `-e` | 줄 끝에 `$` 표시 + `-v` 암시 | ❌ 에러 |
| `-t` | 탭을 `^I`로 표시 + `-v` 암시 | ❌ 에러 |
| `-b` | 비어있지 않은 줄에만 번호 | ❌ 에러 |
| `-n` | 모든 줄에 번호 | ✅ 동일 (`-n, --number`) |
| `-s` | 연속 빈 줄 압축 | ✅ 동일 (`-s, --squeeze-blank`) |
| `-u` | 버퍼링 비활성화 | ✅ 동일 (`-u, --unbuffered`) |
| `-A` | ❌ macOS에서 미지원 (GNU cat 전용) | ✅ 지원 (`-A, --show-all`) |

**실제 문제 상황:**

```bash
# CSI u 모드 진단 시 키 입력 테스트
cat -v
# 기대: 입력 대기 후 비출력 문자 표시
# 실제 (alias 적용 시): 에러 발생
#   error: unexpected argument '-v' found
#     tip: to pass '-v' as a value, use '-- -v'
```

### 해결

alias 제거:

```nix
home.shellAliases = {
  # cat = "bat";  # 삭제: -v, -e, -t, -b 옵션 비호환
};
```

`bat`은 독립적으로 사용하고, `cat`은 원본 유지.

### 교훈

1. **CLI 도구 alias 전에 옵션 호환성 확인 필수**
   - "상위호환"이라는 가정은 위험
   - 특히 시스템 유틸리티(`cat`, `ls`, `grep` 등)는 옵션 체계가 표준화되어 있음

2. **alias가 기존 스크립트/문서에 영향을 줄 수 있음**
   - 문서에 `cat -v` 같은 명령어가 있으면 alias로 인해 오작동
   - 디버깅 시 혼란 야기

3. **대체 도구는 명시적으로 호출하는 것이 안전**
   - `bat file.txt` (명시적)
   - `cat file.txt` (alias로 bat 호출) ← 혼란 유발

4. **부분 호환은 더 위험할 수 있음**
   - `-n`, `-s`, `-u`는 호환되어 평소에는 문제없이 작동
   - 특정 상황(진단, 디버깅)에서만 `-v` 등을 사용할 때 갑자기 실패
   - "잘 되다가 갑자기 안 됨" → 원인 파악이 어려움

---

## 2026-01-10: VS Code customLabels에서 동적 앱 이름 추출 실패

> 테스트 환경: Cursor 2.3.33 (VS Code 1.93.0 기반)

### 배경

Next.js Page Router + Turbopack 모노레포 구조에서 에디터 탭 레이블을 커스터마이징하려 했음. 여러 앱(`web`, `admin`, `mobile` 등)의 `pages/` 폴더에서 동일한 파일명(`index.tsx`)이 열릴 때 구분하기 어려운 문제.

**목표**: `apps/admin/pages/settings/index.tsx` → `(admin) settings/index.tsx`

### 시도 1: Named Capture Group 문법 (실패)

정규식의 Named Capture Group을 사용하여 앱 이름을 동적으로 추출하려 시도.

```json
"**/apps/${app:([^/]+)}/pages/**/index.{ts,tsx}": "(${app}) ${dirname}/index.${extname}"
```

**결과**: 동작하지 않음.

**원인**: VS Code의 `customLabels.patterns`는 Named Capture Group이나 정규식 캡처를 **지원하지 않음**.

### 시도 2: `**` 와일드카드 + `${dirname(N)}` 조합 (실패)

`**` 패턴으로 가변 깊이 경로를 매칭하고, `${dirname(N)}`으로 특정 위치의 폴더명을 추출하려 시도.

```json
"**/apps/*/pages/**/index.{ts,tsx}": "(${dirname(3)}) ${dirname}/index.${extname}"
```

**결과**: 앱 이름이 아닌 다른 폴더명이 표시됨.

| 경로 | 기대 결과 | 실제 결과 |
|------|----------|----------|
| `apps/admin/pages/settings/index.tsx` | `(admin) settings/index.tsx` | `(apps) settings/index.tsx` |
| `apps/admin/pages/a/b/index.tsx` | `(admin) b/index.tsx` | `(pages) b/index.tsx` |

**원인**: `${dirname(N)}`은 **파일 기준 절대 인덱싱**이므로, `**`가 매칭하는 경로 깊이에 따라 N번째 폴더가 달라짐.

### VS Code customLabels의 한계

**지원되는 변수 (전부)**:

| 변수 | 설명 |
|------|------|
| `${filename}` | 확장자 제외 파일명 |
| `${extname}` | 확장자 |
| `${dirname}` | 직접 상위 폴더명 |
| `${dirname(N)}` | N번째 상위 폴더명 (파일 기준 절대 인덱싱) |

**지원되지 않는 기능**:

- Named Capture Group (`${name:pattern}`)
- 정규식 캡처 (`$1`, `$2`)
- 패턴 매칭 위치 기반 변수 추출
- `**` 와일드카드와 상대적 인덱싱 조합

### 해결 방법 (우회)

앱별로 명시적인 패턴을 작성하는 수밖에 없음.

```json
"**/apps/web/pages/**/index.{ts,tsx}": "(web) ${dirname}/index.${extname}",
"**/apps/admin/pages/**/index.{ts,tsx}": "(admin) ${dirname}/index.${extname}",
"**/apps/mobile/pages/**/index.{ts,tsx}": "(mobile) ${dirname}/index.${extname}"
```

**단점**: 앱이 추가될 때마다 패턴을 수동으로 추가해야 함.

### 교훈

1. **VS Code customLabels는 단순한 템플릿 치환만 지원**
   - 정규식 캡처, 동적 변수 추출 등 고급 기능 없음
   - glob 패턴은 파일 매칭용일 뿐, 값 추출용이 아님

2. **`${dirname(N)}`은 절대 인덱싱**
   - 파일 위치 기준으로 고정된 깊이만 참조 가능
   - `**` 와일드카드와 함께 사용하면 예측 불가능한 결과

3. **모노레포에서는 앱별 명시적 패턴이 필요**
   - 동적으로 앱 이름을 추출하는 방법 없음
   - 앱 목록이 자주 변경되지 않는다면 수동 관리가 현실적

---

## 2024-12-25: duti로 .html/.htm 기본 앱 설정 실패

### 배경

macOS에서 텍스트/코드 파일(.txt, .md, .js 등)을 더블클릭 시 Xcode 대신 Cursor로 열리도록 `duti`를 사용하여 설정.

### 시도한 내용

```nix
codeExtensions = [
  "txt" "text" "md" "mdx" "js" "jsx" "ts" "tsx" "mjs" "cjs"
  "json" "yaml" "yml" "toml" "html" "htm" "css" "scss" "sass" "less"
  # ... 기타 확장자
];

home.activation.setCursorAsDefaultEditor = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
  ${lib.concatMapStringsSep "\n" (ext:
    "${pkgs.duti}/bin/duti -s ${cursorBundleId} .${ext} all"
  ) codeExtensions}
'';
```

### 결과

```
failed to set com.todesktop.230313mzl4w4u92 as handler for public.html (error -54)
```

- **error -54**: macOS 권한 에러 (`permErr`)
- `.html`, `.htm` 확장자만 실패, 나머지는 성공

### 원인 분석

1. **Safari가 `public.html` UTI를 시스템 수준에서 선점**
   - macOS는 Safari를 HTML 파일의 기본 핸들러로 강하게 보호
   - `duti`가 `public.html` UTI 설정 시도 시 권한 거부됨

2. **duti의 확장자 설정 동작**
   - `.html` 확장자 설정 시 내부적으로 `public.html` UTI도 함께 설정 시도
   - UTI 설정 실패 시 에러 출력 (치명적이지 않음)

### 해결 방법

**방법 1: 확장자 목록에서 html/htm 제거 (적용)**

```nix
codeExtensions = [
  "txt" "text" "md" "mdx" "js" "jsx" "ts" "tsx" "mjs" "cjs"
  "json" "yaml" "yml" "toml" "css" "scss" "sass" "less"  # html, htm 제거
  # ...
];
```

**방법 2: Finder에서 수동 설정 (필요시)**

1. `.html` 파일 우클릭 → 정보 가져오기 (Cmd+I)
2. "다음으로 열기" → Cursor 선택 → "모두 변경" 클릭

### 교훈

1. **macOS Launch Services는 시스템 앱(Safari, Preview 등)을 보호함**
   - 특정 UTI는 사용자가 변경할 수 없도록 잠겨 있음
   - CLI 도구로 강제 변경 불가

2. **duti 에러는 치명적이지 않음**
   - 개별 확장자 설정 실패해도 다른 확장자에 영향 없음
   - activation 전체가 중단되지 않음

3. **HTML 파일은 브라우저로 여는 것이 macOS 기본 정책**
   - 개발자 워크플로우와 충돌하는 부분
   - 필요시 수동 설정으로 대응

---

## 2024-12-24: Anki 애드온 Nix 선언적 관리 시도 (보류)

### 목표

Anki 애드온 10개를 Nix로 선언적 관리하여 재현 가능한 환경 구축.

### 시도한 방식들

#### 방식 1: AnkiWeb 직접 다운로드 (실패)

AnkiWeb에서 애드온을 직접 다운로드하여 관리하는 방식.

```
https://ankiweb.net/shared/download/{addon_id}
```

**실패 원인:** AnkiWeb의 다운로드 URL은 직접 접근을 차단함. 브라우저 세션/쿠키가 필요하여 `fetchurl`로 다운로드 불가.

---

#### 방식 2: 로컬 소스 패키징 (반려)

애드온 소스 코드를 nixos-config 저장소에 직접 포함하여 관리하는 방식.

```
modules/darwin/programs/anki/
└── sources/
    ├── 24411424/
    ├── 31746032/
    └── ...
```

**반려 사유:** 각 애드온의 소스코드(수백 개 파일)를 전부 git으로 관리해야 하므로 저장소 규모가 너무 커짐. diff도 과도하게 많이 발생.

---

#### 방식 3: GitHub 저장소 활용 (보류)

`fetchFromGitHub`를 사용하여 GitHub에서 애드온 소스를 다운로드하는 방식.

```nix
pkgs.fetchFromGitHub {
  owner = "addon-author";
  repo = "addon-repo";
  rev = "<commit-hash>";
  sha256 = "...";
};
```

**생성했던 파일 구조:**

```
modules/darwin/programs/anki/
├── default.nix          # 메인 모듈
├── addons.nix           # fetchFromGitHub 애드온 정의
└── files/               # 설정 파일
    ├── customize-shortcuts-meta.json
    ├── add-hyperlink-config.json
    ├── note-linker-config.json
    └── add-table-config.json
```

### 방식 3의 실패 원인

#### 1. GitHub 저장소 구조 불일치

대부분의 Anki 애드온 GitHub 저장소는 개발용 구조로 되어 있음:
- `src/` 디렉토리에 소스 코드
- `forms6/` (Qt Designer UI 파일에서 빌드되는 Python 모듈)이 빌드되어야 함
- AnkiWeb 배포판에만 빌드된 파일이 포함됨

| 애드온 | 문제점 |
|---|---|
| Add Table (1237621971) | `forms6` 모듈 누락 |
| Add Hyperlink (318752047) | `forms6` 모듈 누락 |
| Customize Shortcuts (24411424) | Qt 버전 호환성 문제 |

#### 2. 저장소별 srcDir 상이

각 저장소마다 실제 애드온 파일 위치가 다름:
- `custom_shortcuts/` (24411424)
- `src/` (31746032, 318752047, 1237621971)
- `src/image_occlusion_enhanced/` (1374772155)
- `src/enhanced_cloze/` (1990296174)
- `.` 루트 (1077002392, 1124670306)

### 교훈

1. **AnkiWeb 배포판 vs GitHub 소스는 다르다**
   - GitHub 소스에는 빌드 과정에서 생성되는 파일(`forms6/` 등)이 없음
   - `fetchFromGitHub` 방식은 대부분의 애드온에서 작동하지 않음

2. **작업 전 항상 백업**
   - 데이터를 삭제하기 전에 반드시 백업 생성
   - 특히 설정 파일, 커스텀 설정이 있는 경우

3. **Anki 애드온 관리의 현실적 대안**
   - AnkiWeb에서 직접 설치/관리 (기존 방식)
   - AnkiWeb API를 사용한 다운로드 (불안정할 수 있음)
   - 애드온별 릴리스 아티팩트 사용 (있는 경우에만)

### 대상 애드온 목록 (참고용)

| ID | 이름 |
|---|---|
| 24411424 | Customize Keyboard Shortcuts |
| 31746032 | AnkiWebView Inspector |
| 318752047 | Add Hyperlink |
| 805891399 | Extended Editor for Field |
| 1077002392 | Anki Note Linker |
| 1124670306 | Set Added Date |
| 1237621971 | Add Table |
| 1374772155 | Image Occlusion Enhanced |
| 1990296174 | Enhanced Cloze |
| 2491935955 | Quick Colour Changing |

### 결론

Anki 애드온의 Nix 선언적 관리는 **현실적으로 어려움**. AnkiWeb에서 직접 관리하는 것이 가장 안정적.

---

## 2026-01-14: Atuin Watchdog 개선 및 Daemon 비활성화

### 배경

회사 환경에서 atuin daemon 재시작 후에도 동기화 지연이 지속되는 문제 발생. 원인 파악 및 해결 과정 기록.

### 타임라인 (사실 기반)

| 시점 | 커밋 | 내용 |
|------|------|------|
| 2026-01-13 17:55 | b44bea2 | daemon 모드 활성화, atuin doctor 사용 시작 |
| 2026-01-14 08:54 | fb8de27 | "동기화 지연 (1948분 초과)" 문제 발견, daemon 자동 복구 기능 추가 |
| 2026-01-14 11:00경 | 이번 세션 | daemon 여전히 불안정, CLI sync로 완전 대체 결정 |

**주목할 점**: b44bea2에서 daemon을 활성화한 후 약 15시간 만에 1948분(32시간) 동기화 지연이 발견됨. 이는 **daemon이 활성화 직후부터 정상 동작하지 않았을 가능성**을 시사함.

### 핵심 발견: daemon sync vs CLI sync의 차이

소스코드 분석을 통해 중요한 차이점 발견:

**daemon sync** (`atuin-daemon/src/server/sync.rs:85`):
```rust
// sync 성공 후 save_sync_time() 호출
tokio::task::spawn_blocking(Settings::save_sync_time).await??;
```

**CLI sync (v2)** (`crates/atuin/src/command/client/sync.rs`):
```rust
pub async fn run(...) -> Result<()> {
    if settings.sync.records {
        // v2 경로: save_sync_time() 호출 없음
        sync::sync(&settings, &db).await?;
    } else {
        // v1 경로: save_sync_time() 있음
        atuin_client::sync::sync(&settings, false, &db).await?;
    }
}
```

**결론**:
- daemon이 정상 동작하면 `last_sync_time` 파일이 업데이트됨
- CLI sync (v2)는 `save_sync_time()`을 호출하지 않음 (버그로 추정되나 확실하지 않음)

### 이전 커밋(b44bea2)이 동작했던 이유에 대한 분석

**사실**:
- b44bea2 커밋에서는 daemon 모드를 활성화하고, `atuin doctor`의 `last_sync` 값을 사용
- daemon sync 코드에는 `save_sync_time()` 호출이 존재함

**추측**:
- daemon이 정상 동작했다면 `save_sync_time()`이 호출되어 `last_sync_time` 파일이 업데이트되었을 것
- 하지만 fb8de27 커밋(활성화 후 약 15시간)에서 1948분 지연이 발견된 것으로 보아, **daemon이 처음부터 정상 동작하지 않았을 가능성**이 높음
- "정상 동작 후 문제 발생"이 아니라 "활성화 직후부터 문제 발생"이었을 수 있음

### 관찰된 daemon 불안정 증상

**확인된 사실** (이번 세션에서 직접 확인):

```bash
$ launchctl print gui/$(id -u)/com.green.atuin-daemon
runs = 218
last exit code = 1
```

- daemon이 218번 재시작됨
- 마지막 종료 코드가 1 (에러)

**추측되는 원인** (확인되지 않음):
- 네트워크 연결 불안정 시 복구 실패
- 시스템 슬립/웨이크 후 복구 실패
- 서버 측 일시적 장애 후 재연결 실패
- atuin daemon 자체의 experimental 특성으로 인한 불안정

**참고**: atuin 공식 문서에서 daemon을 "experimental" 기능으로 분류하고 있음. maintainer도 불안정하다고 언급한 적 있음 (정확한 출처 필요).

### 문제 1: Watchdog이 에러를 무시함

**증상**: watchdog이 sync 실패를 감지하지 못함

**원인**: 기존 코드가 에러를 무시

```bash
# 기존 코드
atuin sync 2>/dev/null || echo "Warning: sync command failed"
```

**해결**: 에러 로깅 및 상세 출력 추가

```bash
sync_output=$(atuin sync 2>&1)
sync_exit_code=$?
if [[ $sync_exit_code -ne 0 ]]; then
    log_error "Sync failed (exit code: $sync_exit_code)"
    log_error "Sync output: $sync_output"
fi
```

### 문제 2: 네트워크 문제와 daemon 문제 구분 불가

**증상**: 네트워크가 안 되는데 daemon을 재시작하려고 시도

**해결**: sync 시도 전 네트워크 확인 추가

```bash
check_network_connectivity() {
    # DNS 확인
    if ! host "$ATUIN_SYNC_SERVER" >/dev/null 2>&1; then
        log_error "DNS resolution failed"
        return 1
    fi

    # HTTPS 연결 확인
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 "https://$ATUIN_SYNC_SERVER")

    if [[ "$http_code" == "000" ]]; then
        log_error "No response from server"
        return 1
    fi

    return 0
}
```

### 문제 3: Atuin daemon 불안정

**증상**: daemon이 exit code 1로 218번 재시작됨

```bash
$ launchctl print gui/$(id -u)/com.green.atuin-daemon
runs = 218
last exit code = 1
```

**원인 분석**:
- atuin daemon은 아직 experimental 기능
- maintainer도 불안정하다고 언급
- 장시간 실행 시 좀비 상태로 전환

**해결**: daemon 비활성화, launchd로 주기적 sync 실행

```nix
# daemon 비활성화 (config.toml)
# daemon = { enabled = true; ... }  # 주석 처리

# launchd로 2분마다 sync
launchd.agents.atuin-sync = {
  config = {
    ProgramArguments = [ "/bin/bash" "-c" "atuin sync && ..." ];
    StartInterval = 120;
  };
};
```

### 문제 4: CLI sync (v2)가 last_sync_time 미업데이트

**증상**: `atuin sync` 성공해도 `last_sync_time` 파일이 업데이트되지 않음

**원인**: atuin 소스코드 분석 결과, sync.records = true (v2) 경로에서 `save_sync_time()` 미호출

```rust
// crates/atuin/src/command/client/sync.rs
pub async fn run(...) -> Result<()> {
    if settings.sync.records {
        sync::sync(&settings, &db).await?;  // save_sync_time() 없음!
    } else {
        atuin_client::sync::sync(...).await?;  // save_sync_time() 있음
    }
}
```

**해결**: launchd에서 sync 성공 후 직접 파일 업데이트

```bash
atuin sync && printf '%s' "$(date -u +'%Y-%m-%dT%H:%M:%S.000000Z')" > ~/.local/share/atuin/last_sync_time
```

### 문제 5: last_sync_time 파일 형식 오류

**증상**: `atuin doctor`가 "no last sync" 반환

**원인**: 줄바꿈 문자가 포함되면 파싱 실패

```bash
# 잘못된 방식
echo "2026-01-14T02:45:00.000000Z" > last_sync_time  # 줄바꿈 포함!

# 올바른 방식
printf '%s' "2026-01-14T02:45:00.000000Z" > last_sync_time  # 줄바꿈 없음
```

### 문제 6: launchd 에이전트가 즉시 실행되지 않음

**증상**: `StartInterval = 120` 설정 시 첫 interval이 지난 후에야 실행됨

**해결**: `RunAtLoad = true` 추가

```nix
launchd.agents.atuin-sync = {
  config = {
    RunAtLoad = true;      # 로드 시 바로 첫 실행
    StartInterval = 120;   # 이후 2분마다
  };
};
```

### 교훈

1. **에러를 무시하지 말 것**
   - `2>/dev/null`은 디버깅을 불가능하게 만듦
   - 에러 출력을 로그 파일에 기록하는 것이 필수

2. **네트워크 문제 우선 확인**
   - 앱 문제인지 네트워크 문제인지 구분 필요
   - sync 실패 시 무조건 daemon/앱 재시작이 아닌, 네트워크 확인 선행

3. **experimental 기능에 대한 대비**
   - "experimental"로 표시된 기능은 실제로 불안정할 수 있음
   - 대안(fallback)을 미리 마련해두는 것이 좋음
   - 이번 경우: daemon 대신 launchd + CLI sync 조합으로 대체

4. **소스코드 분석의 중요성**
   - 문서만으로는 동작을 확신할 수 없음
   - `save_sync_time()` 미호출 같은 미묘한 차이는 소스코드에서만 확인 가능
   - 버그인지 의도된 동작인지 판단하려면 소스코드 분석 필수

5. **파일 형식의 엄격함**
   - 줄바꿈 하나가 파싱 실패 유발 (`echo` vs `printf '%s'`)
   - 시간 형식, 타임존 등 정확히 맞춰야 함

6. **launchd 동작 이해**
   - `StartInterval`만으로는 즉시 실행 안 됨
   - `RunAtLoad = true` 추가해야 로드 시 첫 실행

7. **커밋 메시지와 타임라인의 중요성**
   - fb8de27 커밋 메시지에 "1948분 동기화 지연"이 기록됨
   - 이 정보로 "daemon이 처음부터 문제였다"는 것을 역추적할 수 있었음
   - 문제 상황을 커밋 메시지에 상세히 기록하는 것이 나중에 도움이 됨

### 최종 아키텍처

```
launchd
├── com.green.atuin-sync      # 2분마다: atuin sync + last_sync_time 업데이트
└── com.green.atuin-watchdog  # 10분마다: 네트워크 확인 + 상태 체크 + 복구 + 알림
```

**왜 이 구조인가:**
- daemon은 불안정 → launchd의 `StartInterval`로 주기적 sync 대체
- CLI sync (v2)는 `last_sync_time` 미업데이트 → launchd에서 직접 파일 업데이트
- watchdog은 상태 체크 + 복구 전담 (sync 자체는 담당하지 않음)

### 발견한 atuin 동작 특성

> **주의**: 아래 내용이 "버그"인지 "의도된 동작"인지는 확인되지 않음. upstream에 확인 필요.

#### 1. sync 경로별 save_sync_time() 호출 여부 (중요!)

atuin에는 여러 sync 경로가 존재하며, 각각 `save_sync_time()` 호출 여부가 다름.

**전체 비교표**:

| sync 경로 | save_sync_time() | 소스코드 위치 | 트리거 |
|-----------|------------------|---------------|--------|
| CLI `atuin sync` (v2) | ❌ 미호출 | `crates/atuin/src/command/client/sync.rs` | 수동 실행, launchd 등 |
| CLI `atuin sync` (v1) | ✅ 호출 | 동일 파일, v1 경로 | (레거시) |
| history end (auto_sync) | ✅ 호출 | `crates/atuin/src/command/client/history.rs:460-462` | 터미널 명령 실행 후 |
| daemon sync | ✅ 호출 | `atuin-daemon/src/server/sync.rs:85` | daemon 내부 스케줄러 |

**핵심 발견 (2026-01-14 추가 분석)**:

처음에는 "CLI sync (v2)가 save_sync_time()을 호출하지 않는다"는 것만 파악했으나, 추가 분석 결과 **history end의 auto_sync는 save_sync_time()을 호출한다**는 것을 발견함.

**소스코드 증거** (`crates/atuin/src/command/client/history.rs:457-462`):

```rust
if settings.should_sync()? {
    #[cfg(feature = "sync")]
    {
        if settings.sync.records {
            let (_, downloaded) = record::sync::sync(settings, &store).await?;
            Settings::save_sync_time()?;  // <-- 여기서 호출!

            crate::sync::build(settings, &store, db, Some(&downloaded)).await?;
        } else {
            // v1 경로
        }
    }
}
```

**CLI sync (v2)와의 비교** (`crates/atuin/src/command/client/sync.rs`):

```rust
pub async fn run(...) -> Result<()> {
    if settings.sync.records {
        sync::sync(&settings, &db).await?;  // save_sync_time() 없음!
    } else {
        atuin_client::sync::sync(&settings, false, &db).await?;
    }
}
```

**실제 테스트 결과** (2026-01-14 12:19):

```bash
$ cat ~/.local/share/atuin/last_sync_time
2026-01-14T03:18:46.000000Z

$ atuin sync
Uploading 1 records to 019bb5a9bc45768099cfb54cf73beb4a/history
2/0 up/down to record store
Sync complete! 51976 items in history database, force: false

$ cat ~/.local/share/atuin/last_sync_time
2026-01-14T03:18:46.000000Z  # 변경 없음!
```

CLI `atuin sync` 실행 전후로 파일이 변경되지 않음. 반면, 터미널에서 일반 명령어를 실행하면 auto_sync가 트리거되어 파일이 업데이트됨.

**auto_sync 동작 방식**:

1. 터미널에서 명령 실행 (예: `ls`, `git status` 등)
2. atuin이 history end 처리
3. `should_sync()` 체크: 마지막 sync 이후 `sync_frequency` (기본 1분) 지났는가?
4. 조건 충족 시 sync 실행 + `save_sync_time()` 호출
5. `last_sync_time` 파일 업데이트

**`should_sync()` 함수** (`crates/atuin-client/src/settings.rs:629-645`):

```rust
pub fn should_sync(&self) -> Result<bool> {
    if !self.auto_sync || !PathBuf::from(self.session_path.as_str()).exists() {
        return Ok(false);
    }

    if self.sync_frequency == "0" {
        return Ok(true);
    }

    match parse_duration(self.sync_frequency.as_str()) {
        Ok(d) => {
            let d = time::Duration::try_from(d)?;
            Ok(OffsetDateTime::now_utc() - Settings::last_sync()? >= d)
        }
        Err(e) => Err(eyre!("failed to check sync: {}", e)),
    }
}
```

**시사점**:

1. **터미널 사용 시**: auto_sync가 `sync_frequency` 간격으로 sync + save_sync_time() 호출
2. **터미널 미사용 시**: auto_sync 트리거 안 됨 → launchd의 주기적 sync 필요
3. **launchd의 CLI sync**: save_sync_time() 미호출 → 직접 파일 업데이트 workaround 필요

**결론**:

launchd에서 `atuin sync` 실행 후 직접 파일을 업데이트하는 workaround는:
- 터미널 사용 시: 불필요 (auto_sync가 처리)
- 터미널 미사용 시: 필요 (CLI sync가 파일 미업데이트)

따라서 현재 설정 (launchd에서 sync + 파일 업데이트)은 **터미널 미사용 시를 위한 백업**으로 유효함.

**추측**: CLI sync (v2)에서 save_sync_time() 미호출은 버그일 가능성이 높음. history end 경로에서는 호출하면서 CLI 경로에서만 누락된 것은 일관성이 없음.

#### 2. daemon 불안정

**관찰된 현상**:
- launchd에서 218번 재시작됨 (runs = 218)
- exit code 1로 반복 종료
- 프로세스는 실행 중이지만 sync를 수행하지 않는 "좀비" 상태 발생

**추측되는 원인** (확인되지 않음):
- experimental 기능의 특성
- 네트워크/슬립/서버 장애 시 복구 실패

**atuin 문서 참고**: daemon은 "experimental" 기능으로 분류됨.

### 향후 고려사항

1. **atuin upstream 이슈 확인/보고**
   - CLI sync (v2)의 `save_sync_time()` 미호출이 버그인지 확인
   - daemon 불안정 관련 기존 이슈가 있는지 확인

2. **daemon 안정화 시 재검토**
   - atuin 버전 업그레이드 시 daemon 안정성 재평가
   - 안정화되면 daemon으로 복귀 가능 (더 효율적)

3. **모니터링 로그 주기적 확인**
   - `~/.local/share/atuin/watchdog.log` 확인
   - 새로운 패턴의 문제 발생 시 조기 발견

---

## 2026-01-14: Atuin 모니터링 시스템 대청소

### 배경: 왜 이렇게 복잡해졌나?

이 섹션은 atuin 동기화 문제 해결 과정에서 시스템이 어떻게 복잡해졌고, 왜 대청소가 필요했는지 기록합니다.

### 전체 히스토리 (시간순)

#### 1단계: v1 API 시절 (문제 없음)

- atuin을 처음 사용하기 시작
- v1 API로 정상적으로 집 <-> 회사 간 히스토리 동기화
- 별다른 설정 없이 기본값으로 동작

#### 2단계: 동기화 실패 시작 (원인 모름)

**증상**:
- 어느 날부터 집 <-> 회사 맥북 간 히스토리 공유가 안 됨
- `atuin status`가 404 오류 반환

**당시 추측** (잘못됨):
- "서버 문제인가?"
- "네트워크 문제인가?"
- "daemon을 사용하면 해결될까?"

**실제 원인** (나중에 파악):
- Atuin 서버가 v1 API를 deprecated하고 v2로 전환
- 내 설정에 `sync.records = true` (v2 활성화)가 없었음
- 단순히 이 한 줄만 추가하면 해결됐을 문제

#### 3단계: daemon 활성화 시도 (2026-01-13)

**시도한 것**:
```nix
daemon = {
  enabled = true;
  sync_frequency = 60;
};
```

**결과**:
- 처음에는 동작하는 것처럼 보임
- 하지만 15시간 후 "1948분 동기화 지연" 발견
- daemon이 처음부터 정상 동작하지 않았을 가능성 높음

#### 4단계: watchdog + 자동 복구 추가 (2026-01-14 오전)

**시도한 것**:
- daemon 상태 모니터링
- 동기화 지연 시 daemon 자동 재시작
- 네트워크 확인 로직
- 지수 백오프 재시도 (5초 → 10초 → 20초)

**결과**:
- 여전히 문제 해결 안 됨
- daemon이 218번 재시작되는 것 확인 (runs = 218, exit code = 1)

#### 5단계: daemon 포기, CLI sync로 대체 (2026-01-14 오전)

**시도한 것**:
- daemon 비활성화
- launchd로 2분마다 `atuin sync` 실행
- CLI sync가 `last_sync_time`을 업데이트하지 않는 버그 발견
- workaround: sync 성공 후 직접 파일 업데이트

**결과**:
- 동작은 하지만 시스템이 매우 복잡해짐

#### 6단계: 핵심 발견 - auto_sync의 존재 (2026-01-14 오후)

**발견**:
- atuin에는 내장 `auto_sync` 기능이 있음
- 터미널에서 명령 실행 시 `sync_frequency` 간격으로 자동 sync
- **history end의 auto_sync는 `save_sync_time()`을 호출함!**

**소스코드 증거** (`crates/atuin/src/command/client/history.rs:460-462`):
```rust
if settings.sync.records {
    let (_, downloaded) = record::sync::sync(settings, &store).await?;
    Settings::save_sync_time()?;  // ← 여기서 호출!
}
```

**깨달음**:
- 우리가 만든 launchd sync는 불필요했음
- auto_sync가 이미 모든 것을 처리하고 있었음
- 단지 `sync.records = true`만 추가하면 됐음

#### 7단계: 대청소 (2026-01-14 오후)

**제거한 것**:
- `launchd.agents.atuin-sync` (불필요)
- watchdog의 복구 로직 (auto_sync가 담당)
- 복잡한 설정들 (maxRetryCount, initialBackoffSeconds, networkCheckTimeout 등)

**남긴 것**:
- `sync.records = true` (v2 sync 활성화) - **근본 해결책**
- `auto_sync = true` (기본값)
- watchdog (상태 체크 + 알림만)
- Hammerspoon 메뉴바 (상태 표시)

### 코드 변화량

| 파일 | 변경 전 | 변경 후 | 감소 |
|------|--------|--------|------|
| default.nix | 80줄 | 47줄 | -33줄 |
| atuin-watchdog.sh | 311줄 | 155줄 | -156줄 |
| atuin_menubar.lua | 297줄 | 273줄 | -24줄 |
| **총계** | 688줄 | 475줄 | **-213줄 (31% 감소)** |

### 최종 아키텍처 (단순화됨)

```
auto_sync (atuin 내장)
    └── 터미널 명령 실행 시 1분 간격으로 자동 sync

Hammerspoon 메뉴바
    └── 1분마다 상태 표시 업데이트

watchdog (launchd, 10분마다)
    └── 상태 체크 + 지연 시 알림
```

### 핵심 교훈

#### 1. 근본 원인을 찾아라

**잘못된 접근**:
- "동기화가 안 된다" → "daemon을 써보자" → "daemon이 불안정하다" → "watchdog으로 복구하자" → "CLI sync로 대체하자"

**올바른 접근**:
- "동기화가 안 된다" → "왜?" → "v1 API가 deprecated됐다" → "`sync.records = true` 추가" → 끝

**교훈**: 문제의 근본 원인을 파악하지 않고 증상만 치료하면 시스템이 불필요하게 복잡해진다.

#### 2. 기존 기능을 먼저 확인하라

**잘못된 접근**:
- "sync가 필요하다" → "launchd로 주기적 sync를 만들자"

**올바른 접근**:
- "sync가 필요하다" → "atuin에 이미 auto_sync가 있나?" → "있다!" → "그럼 그걸 쓰자"

**교훈**: 새로운 기능을 추가하기 전에 기존 도구가 이미 제공하는 기능을 확인하라.

#### 3. 단순함을 유지하라

**복잡했던 구조**:
```
daemon (불안정) + launchd sync (백업) + watchdog (복구) + 메뉴바
```

**단순해진 구조**:
```
auto_sync (내장) + watchdog (모니터링) + 메뉴바
```

**교훈**: 복잡한 해결책은 대개 문제를 제대로 이해하지 못했다는 신호다.

#### 4. 문서를 읽어라

이번 문제의 해결책은 atuin 공식 문서에 있었다:
- https://docs.atuin.sh/cli/sync-v2/ → `sync.records = true`
- https://docs.atuin.sh/reference/sync/ → auto_sync 설명

**교훈**: 문제가 발생하면 공식 문서를 먼저 확인하라.

#### 5. 소스코드를 읽어라

문서만으로 불충분할 때:
- CLI sync vs history end의 `save_sync_time()` 호출 차이
- 이런 미묘한 동작 차이는 소스코드에서만 확인 가능

**교훈**: 도구의 정확한 동작을 알고 싶다면 소스코드를 읽어라.

### 이 경험에서 배운 것

1. **v1 → v2 마이그레이션 문서 확인**: API 버전 변경 시 마이그레이션 가이드 확인 필수
2. **experimental 기능 주의**: daemon은 experimental로 표시됨, 프로덕션에서 주의
3. **auto_sync의 존재**: atuin은 이미 auto_sync를 제공, 별도 sync 스케줄러 불필요
4. **sync 경로별 동작 차이**: CLI sync와 history end의 동작이 다름 (버그일 수 있음)

### 향후 참고사항

1. **atuin 업그레이드 시**: 릴리즈 노트 확인, 특히 sync 관련 변경사항
2. **동기화 문제 발생 시**: 먼저 `sync.records` 설정 확인
3. **daemon 사용 고려 시**: experimental 상태 확인, 안정화되면 재검토 가능

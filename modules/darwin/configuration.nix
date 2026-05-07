# macOS 시스템 설정 (nix-darwin)
{
  config,
  pkgs,
  lib,
  username,
  hostType,
  constants,
  ...
}:

let
  # symbolic hotkeys plist XML 헬퍼
  #
  # nix-darwin CustomUserPreferences는 AppleSymbolicHotKeys dict 전체를 replace하여
  # 기존 항목(사용자 오버라이드 포함)을 삭제한다. 또한 enabled=false + nested value
  # 조합을 올바르게 직렬화하지 못한다.
  # 대신 postActivation에서 defaults write -dict-add로 개별 항목만 수정하여
  # dict 내 기존 key를 보존하고, root 컨텍스트에서 activateSettings를 호출한다.
  mkHotkey =
    {
      enabled,
      ascii,
      keyCode,
      modifiers,
    }:
    ''
      <dict>
        <key>enabled</key>
        <${if enabled then "true" else "false"}/>
        <key>value</key>
        <dict>
          <key>parameters</key>
          <array>
            <integer>${toString ascii}</integer>
            <integer>${toString keyCode}</integer>
            <integer>${toString modifiers}</integer>
          </array>
          <key>type</key>
          <string>standard</string>
        </dict>
      </dict>'';

  mkDisabledNoValue = ''
    <dict>
      <key>enabled</key>
      <false/>
    </dict>'';

  asUser = "launchctl asuser \"$(id -u -- ${username})\" sudo --user=${username} --set-home --";
in
{
  imports = [
    ./programs/homebrew.nix # Homebrew 패키지 관리 (GUI 앱)
    ./programs/sshd # SSH 서버 보안 설정
    ./programs/mosh # mosh 서버 (Termius 등에서 사용)
  ];
  # 폰트 설치 (nix-darwin이 /Library/Fonts/Nix Fonts에 자동 링크)
  #
  # [주의] Sarasa Mono K Nerd Font를 사용하지 않는 이유:
  # Sarasa는 Iosevka(라틴) + Source Han Sans(CJK) 합성 폰트로 CJK:ASCII = 2:1 너비 비율이
  # 정확하여 한영 혼용 정렬에 유리하지만, 치명적인 단점이 있음:
  #
  # 1) 저DPI 모니터에서 심각한 가독성 저하
  #    - MacBook Pro 16" Liquid Retina XDR (254 PPI): 깔끔하게 렌더링됨
  #    - DELL S2725DS 27" QHD (109 PPI): 글자가 자글자글(fuzzy/jagged)하게 보임
  #    - 복합 합성 폰트(여러 폰트 파일을 합친 구조)는 서브픽셀 힌팅이 저DPI에서
  #      제대로 동작하지 않아 단일 폰트 대비 렌더링 품질이 크게 떨어짐
  #    - 경험적 기준: ~200 PPI 이상에서만 복합 합성 폰트가 깨끗하게 보임
  #      일반 외장 모니터 PPI 참고:
  #        24" FHD(1080p) = 92 PPI  → 자글자글할 가능성 높음
  #        27" QHD(1440p) = 109 PPI → 실제로 자글자글하게 확인됨
  #        27" 4K(2160p)  = 163 PPI → 개선되지만 완벽하지 않을 수 있음
  #        32" 4K(2160p)  = 137 PPI → 개선되지만 완벽하지 않을 수 있음
  #      → 비-Retina 외장 모니터(~200 PPI 미만)에서는 Sarasa 류의 합성 폰트 사용을 피할 것.
  #        단일 설계 폰트(JetBrains Mono, Fira Code 등)는 저DPI에서도 깔끔하게 렌더링됨.
  #
  # 2) CJK 2:1 너비 비율의 실질적 이점 부재
  #    - ASCII 아트를 주로 LLM이 생성하는데, LLM이 폰트의 글자 폭 규칙을 인지하지 못하므로
  #      2:1 비율이어도 부정확한 결과물이 생성됨. Skill 신설은 context 토큰 비용 대비 비효율적.
  #
  # 향후 Sarasa와 유사한 합성 폰트(예: M+ 계열, Monaspace + CJK 합성 등)를 고려할 때
  # 반드시 사용 중인 모든 모니터의 PPI를 확인하고, ~200 PPI 미만 모니터가 있다면 사용을 피할 것.
  # 이 폰트를 다시 설치하려면 git log에서 이 커밋을 참조할 것.
  #
  # [현재 폰트 전략]
  # 영문: JetBrainsMono Nerd Font (Nix 설치, 단일 설계 폰트로 저DPI에서도 깔끔)
  # 한글: D2Coding (Nix 설치, 네이버 코딩 전용 한글 폰트, 앱별 font-family 폴백으로 지정)
  fonts.packages = [
    pkgs.nerd-fonts.jetbrains-mono
    pkgs.d2coding
  ];

  # Touch ID for sudo
  security.pam.services.sudo_local.touchIdAuth = true;

  # darwin-rebuild를 Touch ID 없이 실행 (nrs 자동화용)
  # 보안: NixOS는 이미 wheelNeedsPassword=false (ALL 명령 NOPASSWD). 이것은 더 제한적.
  security.sudo.extraConfig = ''
    ${username} ALL=(root) NOPASSWD: /run/current-system/sw/bin/darwin-rebuild
  '';

  # 사용자 설정
  users.users.${username} = {
    shell = pkgs.zsh;
    home = "/Users/${username}";
    # SSH 원격 접속 허용 키
    openssh.authorizedKeys.keys = [
      constants.sshKeys.macbook # Termius 등 외부 기기에서 접속
    ]
    ++ lib.optionals (hostType == "personal") [
      # MiniPC는 Tailscale IP 전용 — work Mac에는 불필요
      constants.sshKeys.minipc
    ];
  };

  # 환경 설정
  environment = {
    shells = [ pkgs.zsh ];
  };

  # zsh 활성화 (darwin-rebuild PATH 설정에 필수)
  programs.zsh.enable = true;

  # macOS 시스템 기본값
  system.defaults = {
    # Dock 설정
    dock = {
      autohide = true;
      show-recents = false;
      tilesize = constants.macos.dock.tileSize;
      mru-spaces = false;
      mineffect = "suck";
    };

    # Finder 설정
    finder = {
      AppleShowAllFiles = true;
      AppleShowAllExtensions = true;
    };

    # 전역 설정
    NSGlobalDomain = {
      # AppleInterfaceStyle = "Dark";  # Light 모드는 null 또는 주석처리
      AppleShowAllFiles = true;
      AppleShowAllExtensions = true;

      # 키보드: 키 반복 속도 가장 빠르게, 반복 지연 시간 제일 짧게
      InitialKeyRepeat = constants.macos.keyboard.initialKeyRepeat; # 반복 지연 시간 (최소값: 15)
      KeyRepeat = constants.macos.keyboard.keyRepeat; # 키 반복 속도 (최소값: 1, 가장 빠름) [GUI에서는 2 이하로 내릴 수 없음]

      # 마우스: 자연스러운 스크롤 비활성화
      "com.apple.swipescrolldirection" = false;

      # 자동 수정 비활성화
      NSAutomaticCapitalizationEnabled = false;
      NSAutomaticDashSubstitutionEnabled = false;
      NSAutomaticPeriodSubstitutionEnabled = false;
      NSAutomaticQuoteSubstitutionEnabled = false;
      NSAutomaticSpellingCorrectionEnabled = false;

      # 기능 키(F1-F12)를 표준 기능키로 사용 (밝기/볼륨 대신)
      "com.apple.keyboard.fnState" = true;
    };

    # 네트워크 볼륨에 .DS_Store 생성 방지
    CustomUserPreferences."com.apple.desktopservices" = {
      DSDontWriteNetworkStores = true;
    };

    # App Switcher를 모든 모니터에 표시
    CustomUserPreferences."com.apple.Dock" = {
      appswitcher-all-displays = true;
    };

    # 키보드 단축키 (com.apple.symbolichotkeys)
    #
    # [주의] CustomUserPreferences가 아닌 postActivation에서 관리.
    # nix-darwin CustomUserPreferences."com.apple.symbolichotkeys"는 defaults write로
    # AppleSymbolicHotKeys dict 전체를 교체(replace)하여 기존 항목(사용자 오버라이드 포함)을 삭제한다.
    # 또한 enabled=false + nested value 조합을 올바르게 직렬화하지 못한다.
    # 대신 postActivation에서 defaults write -dict-add로 개별 항목만 수정한다.

    # 윈도우 매니저
    WindowManager = {
      EnableStandardClickToShowDesktop = false;
    };
  };

  # 시스템 설정 즉시 적용 (activation 스크립트)
  #
  # 실행 순서:
  #   1. nix-darwin defaults write (system.defaults.*) → Dock, Finder 등 plist 적용
  #   2. Home Manager activation → Shottr 설정, 라이센스 등 적용
  #   3. postActivation (이 스크립트) → symbolic hotkeys + activateSettings + Shottr 재시작
  #
  # symbolic hotkeys와 Shottr 재시작을 postActivation에서 처리하는 이유:
  #   - HM activation의 activateSettings -u는 launchctl asuser + sudo 컨텍스트에서
  #     WindowServer와 통신하지 못해 적용되지 않음 (root 컨텍스트에서만 정상 동작)
  #   - Shottr는 activateSettings 이후에 재시작해야 올바른 symbolic hotkey 상태로 기동됨
  system.activationScripts.postActivation.text = ''
    # 입력소스 전환 툴팁 비활성화
    sudo defaults write /Library/Preferences/FeatureFlags/Domain/UIKit.plist \
      redesigned_text_cursor -dict-add Enabled -bool NO 2>/dev/null || true

    # === macOS 키보드 단축키 (Symbolic Hotkeys) ===
    #
    # defaults write -dict-add로 개별 항목만 수정하여 dict 내 기존 key를 보존.
    # CustomUserPreferences."com.apple.symbolichotkeys"는 dict 전체를 교체하므로 사용하지 않음.
    #
    # Symbolic Hotkeys ID:
    #   28-31: 스크린샷 (28=화면→파일, 29=화면→클립보드, 30=선택→파일, 31=선택→클립보드)
    #   32-34: Mission Control (32=Mission Control, 33=앱 윈도우, 34=데스크탑 보기)
    #   60-61: 입력 소스 (60=이전, 61=다음)
    #   64-65: Spotlight (64=검색, 65=Finder 검색)
    #   184: 스크린샷 도구모음
    #
    # parameters: [ ASCII/keyCode, virtualKeyCode, modifierFlags ]
    #   modifierFlags: Shift+Cmd=1179648, Ctrl+Shift+Cmd=1441792, Fn=8388608, Opt+Cmd=1572864

    # --- 스크린샷 (Shottr 연동) ---
    # Shottr 호환: disabled 항목에 반드시 value 블록을 포함해야 macOS WindowServer가
    # CopySymbolicHotKeys에서 해당 키 조합을 정상 해제함.
    # value 없이 enabled=false만 설정하면 키 이벤트가 Shottr에 도달하지 못함.
    # 28: ⇧⌘3 화면→파일 — 비활성화 (Shottr Area에 양보)
    ${asUser} defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add \
      "28" '${
        mkHotkey {
          enabled = false;
          ascii = 51;
          keyCode = 20;
          modifiers = 1179648;
        }
      }'
    # 29: ⌃⇧⌘3 화면→클립보드 — 활성화
    ${asUser} defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add \
      "29" '${
        mkHotkey {
          enabled = true;
          ascii = 51;
          keyCode = 20;
          modifiers = 1441792;
        }
      }'
    # 30: ⇧⌘4 선택→파일 — 비활성화 (⇧⌘4 클립보드 전용으로 사용)
    ${asUser} defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add \
      "30" '${
        mkHotkey {
          enabled = false;
          ascii = 52;
          keyCode = 21;
          modifiers = 1179648;
        }
      }'
    # 31: ⇧⌘4 선택→클립보드 — 활성화
    ${asUser} defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add \
      "31" '${
        mkHotkey {
          enabled = true;
          ascii = 52;
          keyCode = 21;
          modifiers = 1179648;
        }
      }'
    # 184: ⇧⌘5 스크린샷 도구모음 — 활성화
    ${asUser} defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add \
      "184" '${
        mkHotkey {
          enabled = true;
          ascii = 53;
          keyCode = 23;
          modifiers = 1179648;
        }
      }'

    # --- Mission Control ---
    # 32: Mission Control (F3) — 활성화
    ${asUser} defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add \
      "32" '${
        mkHotkey {
          enabled = true;
          ascii = 65535;
          keyCode = 99;
          modifiers = 8388608;
        }
      }'

    # --- 입력 소스 ---
    # 60: 이전 입력 소스 (⌃Space) — 비활성화
    ${asUser} defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add \
      "60" '${mkDisabledNoValue}'
    # 61: 다음 입력 소스 (F18) — 활성화 (Hammerspoon Capslock→F18 연동)
    ${asUser} defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add \
      "61" '${
        mkHotkey {
          enabled = true;
          ascii = 65535;
          keyCode = 79;
          modifiers = 8388608;
        }
      }'

    # --- Spotlight (Raycast 사용으로 비활성화) ---
    # 64: Spotlight 검색 (⌘Space) — 비활성화
    ${asUser} defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add \
      "64" '${mkDisabledNoValue}'
    # 65: Finder 검색 윈도우 (⌥⌘Space) — 활성화
    ${asUser} defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add \
      "65" '${
        mkHotkey {
          enabled = true;
          ascii = 32;
          keyCode = 49;
          modifiers = 1572864;
        }
      }'

    # 캐시 초기화 + 설정 즉시 적용
    # cfprefsd kill로 디스크 plist에서 강제 재읽기 후 activateSettings로 WindowServer에 반영
    killall cfprefsd 2>/dev/null || true
    sleep 1

    # 키보드 단축키 등 설정 즉시 적용 (PrivateFramework - macOS 업데이트 시 경로 변경 가능)
    if [ -x /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings ]; then
      /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
    else
      echo "경고: activateSettings를 찾을 수 없습니다. 키보드 단축키 적용을 위해 재부팅이 필요할 수 있습니다."
      echo "경로 변경 확인: /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/"
    fi

    # activateSettings가 스크롤 방향을 롤백시키므로 명시적으로 재설정
    defaults write -g com.apple.swipescrolldirection -bool false

    # Hammerspoon 재시작은 nrs.sh의 restart_hammerspoon()에서 처리 (kill+open)
    # 여기서 hs.reload()를 호출하면 nrs.sh와 이중 리로드되어 알림 2회 발생
    # 직접 darwin-rebuild를 실행한 경우 수동으로 hsr 또는 앱 재시작 필요

    # Shottr 재시작 (activateSettings로 symbolic hotkeys 반영 후)
    # Shottr 미설치/GUI 세션 없음(SSH) 등에서 실패해도 activation을 중단하지 않음
    if pgrep -x Shottr >/dev/null 2>&1; then
      killall Shottr 2>/dev/null || true
      sleep 1
      ${asUser} /usr/bin/open -a Shottr 2>/dev/null || echo "경고: Shottr 재시작 실패 (GUI 세션 없음?)"
    fi
  '';

  system.primaryUser = username;
  system.stateVersion = 6; # 마이그레이션 버전 (최초 설치 시점 기준, 변경 금지)
}

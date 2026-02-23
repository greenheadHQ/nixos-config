# macOS 시스템 설정 (nix-darwin)
{
  config,
  pkgs,
  username,
  constants,
  ...
}:

{
  imports = [
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
  fonts.packages = [
    pkgs.nerd-fonts.jetbrains-mono
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
      constants.sshKeys.minipc # MiniPC에서 접속
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

    # 키보드 단축키 설정 (com.apple.symbolichotkeys)
    #
    # Symbolic Hotkeys ID 설명:
    #   - 각 숫자는 macOS 시스템 단축키의 고유 식별자 (Apple 내부 ID)
    #   - 시스템 환경설정 > 키보드 > 키보드 단축키의 각 항목에 대응
    #
    # 현재 시스템의 전체 ID 목록 확인:
    #   defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys | grep -E '^\s+[0-9]+ ='
    #
    # 주요 ID 참조 (비공식, 커뮤니티 문서 기반):
    #   28-31: 스크린샷 (28=화면→파일, 29=화면→클립보드, 30=선택→파일, 31=선택→클립보드)
    #   32-34: Mission Control (32=Mission Control, 33=앱 윈도우, 34=데스크탑 보기)
    #   60-61: 입력 소스 (60=이전, 61=다음)
    #   64-65: Spotlight (64=검색, 65=Finder 검색)
    #
    # parameters 배열: [ ASCII/keyCode, virtualKeyCode, modifierFlags ]
    #   modifierFlags: Control=262144, Shift=131072, Option=524288, Command=1048576, Fn=8388608
    #
    CustomUserPreferences."com.apple.symbolichotkeys" = {
      AppleSymbolicHotKeys = {
        # === 스크린샷 설정 ===
        # 28: 화면→파일 (⇧⌘3) - 비활성화
        "28" = {
          enabled = false;
        };
        # 30: 선택→파일 (⇧⌘4) - 비활성화
        "30" = {
          enabled = false;
        };

        # 29: 화면→클립보드 (⌃⇧⌘3) - 활성화
        "29" = {
          enabled = true;
          value = {
            parameters = [
              51
              20
              1441792
            ];
            type = "standard";
          };
        };
        # 31: 선택→클립보드 (⇧⌘4) - 활성화
        "31" = {
          enabled = true;
          value = {
            parameters = [
              52
              21
              1179648
            ];
            type = "standard";
          };
        };

        # === Mission Control 설정 ===
        # 32: Mission Control (F3) - 활성화
        "32" = {
          enabled = true;
          value = {
            parameters = [
              65535
              99
              8388608
            ];
            type = "standard";
          };
        };

        # === 입력 소스 설정 ===
        # 60: 이전 입력 소스 (⌃Space) - 비활성화
        "60" = {
          enabled = false;
        };
        # 61: 다음 입력 소스 (F18) - 활성화 (Hammerspoon Capslock→F18 연동)
        "61" = {
          enabled = true;
          value = {
            parameters = [
              65535
              79
              8388608
            ];
            type = "standard";
          };
        };

        # === Spotlight 설정 (Raycast 사용으로 비활성화) ===
        # 64: Spotlight 검색 (⌘Space) - 비활성화
        "64" = {
          enabled = false;
        };
        # 65: Finder 검색 윈도우 (⌥⌘Space) - 활성화
        "65" = {
          enabled = true;
          value = {
            parameters = [
              32
              49
              1572864
            ];
            type = "standard";
          };
        };
      };
    };

    # 윈도우 매니저
    WindowManager = {
      EnableStandardClickToShowDesktop = false;
    };
  };

  # 시스템 설정 즉시 적용 (activation 스크립트)
  system.activationScripts.postActivation.text = ''
    # 입력소스 전환 툴팁 비활성화
    sudo defaults write /Library/Preferences/FeatureFlags/Domain/UIKit.plist \
      redesigned_text_cursor -dict-add Enabled -bool NO 2>/dev/null || true

    # 키보드 단축키 등 설정 즉시 적용 (PrivateFramework - macOS 업데이트 시 경로 변경 가능)
    if [ -x /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings ]; then
      /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u
    else
      echo "경고: activateSettings를 찾을 수 없습니다. 키보드 단축키 적용을 위해 재부팅이 필요할 수 있습니다."
      echo "경로 변경 확인: /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/"
    fi

    # activateSettings가 스크롤 방향을 롤백시키므로 명시적으로 재설정
    defaults write -g com.apple.swipescrolldirection -bool false

    # Hammerspoon 설정 리로드 (F18 리매핑과 연동)
    /Applications/Hammerspoon.app/Contents/Frameworks/hs/hs -c "hs.reload()" 2>/dev/null || true
  '';

  system.primaryUser = username;
  system.stateVersion = 6; # 마이그레이션 버전 (최초 설치 시점 기준, 변경 금지)
}

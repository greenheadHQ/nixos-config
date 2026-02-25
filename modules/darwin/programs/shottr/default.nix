# Shottr 설정 (macOS)
#
# Shottr 앱 고유 설정만 관리. macOS symbolic hotkeys(스크린샷 단축키)와
# Shottr 재시작은 modules/darwin/configuration.nix의 postActivation에서 처리.
# 이유: HM activation의 activateSettings -u가 launchctl asuser + sudo 컨텍스트에서
# WindowServer와 통신하지 못하므로, root 컨텍스트의 postActivation에서 실행해야 함.
#
# NOTE: home.activation 스크립트에서 /usr/bin/defaults, /usr/bin/killall 등 절대 경로를 사용하는 이유:
# Home Manager activation은 최소한의 PATH로 실행되어 /usr/bin이 포함되지 않는다.
# 반면 system.activationScripts (nix-darwin 시스템 레벨)는 일반 PATH를 가지므로
# defaults를 그대로 쓸 수 있다. home.activation에서는 반드시 절대 경로 필수.
{
  config,
  lib,
  constants,
  ...
}:

let
  homeDir = config.home.homeDirectory;
  shottrDomain = "cc.ffitch.shottr";
  shottrDefaultFolder = "${homeDir}/${constants.macos.paths.shottrDefaultFolderRelative}";
  shottrLicensePath = "${config.xdg.configHome}/shottr/license";
in
{
  # 경로 가드: 폴더/북마크 이슈를 조기에 알림
  home.activation.checkShottrFolderAndWarn = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -d "${shottrDefaultFolder}" ]; then
      echo "Warning: Shottr default folder not found: ${shottrDefaultFolder}"
      echo "FolderActions activation should create this path."
    fi

    current_folder="$(/usr/bin/defaults read "${shottrDomain}" defaultFolder 2>/dev/null || true)"
    if [ -n "$current_folder" ] && [ "$current_folder" != "${shottrDefaultFolder}" ]; then
      echo "Warning: Shottr current folder differs from declared folder."
      echo "  current: $current_folder"
      echo "  target : ${shottrDefaultFolder}"
      echo "If save fails after switch, re-select the folder once in Shottr UI."
      echo "Note: defaultFolderBookmark(data) is intentionally not managed by Nix."
    fi
  '';

  # Shottr 앱 고유 설정 적용
  #
  # Carbon modifier flags:
  #   cmdKey=256(0x100) shiftKey=512(0x200) optionKey=2048(0x800) controlKey=4096(0x1000)
  # Carbon key codes:
  #   1=18(0x12) 2=19(0x13) 3=20(0x14) O=31(0x1F)
  home.activation.applyShottrCoreSettings = lib.hm.dag.entryAfter [ "checkShottrFolderAndWarn" ] ''
    /usr/bin/defaults write "${shottrDomain}" defaultFolder "${shottrDefaultFolder}"
    /usr/bin/defaults write "${shottrDomain}" saveFormat "Auto"
    /usr/bin/defaults write "${shottrDomain}" KeyboardShortcuts_fullscreen -string '{"carbonModifiers":768,"carbonKeyCode":18}'   # ⇧⌘1
    /usr/bin/defaults write "${shottrDomain}" KeyboardShortcuts_area -string '{"carbonKeyCode":20,"carbonModifiers":768}'          # ⇧⌘3
    /usr/bin/defaults write "${shottrDomain}" KeyboardShortcuts_scrolling -string '{"carbonModifiers":768,"carbonKeyCode":19}'     # ⇧⌘2
    /usr/bin/defaults write "${shottrDomain}" KeyboardShortcuts_ocr -string '{"carbonModifiers":6400,"carbonKeyCode":31}'          # ⌃⌥⌘O

    # Manual Scrolling Capture 활성화
    # Auto Scroll Capture는 Terminal, VS Code 등 비표준 스크롤 앱에서 화면이 짤림.
    # Manual 모드는 사용자가 직접 스크롤하며 캡처하므로 이런 앱에서도 정상 동작.
    # ref: https://shottr.cc/kb/faq
    # ref: https://hurricane-flower-fdf.notion.site/Manual-Scrolling-Capture-120d943b739b80bf868dd1009eeadc17
    /usr/bin/defaults write "${shottrDomain}" scrollingManualEnabled -bool true
  '';

  # 라이센스 pre-fill (agenix secret → defaults write)
  # Keychain 없는 새 맥북에서 Activate 버튼 1회 클릭만으로 활성화 가능
  #
  # macOS에서 agenix는 launchd agent(activate-agenix, RunAtLoad)로 시크릿을 복호화한다.
  # setupLaunchAgents가 agenix agent를 로드한 뒤 짧은 대기로 복호화 완료를 기다린다.
  # 라이센스는 defaults DB에 한번 기록되면 영구 보존되므로 실패해도 큰 문제 없음.
  home.activation.applyShottrLicenseFromSecret =
    lib.hm.dag.entryAfter [ "applyShottrCoreSettings" "setupLaunchAgents" ]
      ''
        _waited=0
        while [ ! -f "${shottrLicensePath}" ] && [ "$_waited" -lt 5 ]; do
          sleep 1
          _waited=$(( _waited + 1 ))
        done

        if [ ! -f "${shottrLicensePath}" ]; then
          echo "Note: Shottr license secret not yet available. License pre-fill skipped."
        else
          kc_license="$(sed -n 's/^KC_LICENSE=//p' "${shottrLicensePath}" | tail -n 1 | tr -d '\r')"
          kc_vault="$(sed -n 's/^KC_VAULT=//p' "${shottrLicensePath}" | tail -n 1 | tr -d '\r')"

          if [ -n "$kc_license" ]; then
            /usr/bin/defaults write "${shottrDomain}" kc-license -string "$kc_license"
          fi
          if [ -n "$kc_vault" ]; then
            /usr/bin/defaults write "${shottrDomain}" kc-vault -string "$kc_vault"
          fi
        fi
      '';

  # Shottr 재시작은 configuration.nix postActivation에서 처리.
  # activateSettings -u가 root 컨텍스트에서만 WindowServer와 통신 가능하므로,
  # postActivation에서 symbolic hotkeys 적용 → cfprefsd kill → activateSettings → Shottr 재시작
  # 순서로 실행한다. HM activation에서는 Shottr 앱 설정만 작성하고 재시작하지 않는다.
}

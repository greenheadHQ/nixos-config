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
  pkgs,
  constants,
  ...
}:

let
  homeDir = config.home.homeDirectory;
  shottrDomain = "cc.ffitch.shottr";
  shottrDefaultFolder = "${homeDir}/${constants.macos.paths.shottrDefaultFolderRelative}";
  shottrPreferencesTarget = "${homeDir}/${constants.macos.paths.shottrPreferencesTargetRelative}";
  shottrLicensePath = "${config.xdg.configHome}/shottr/license";
  # `defaults`가 sandbox app container를 읽고 쓸 때 responsible app의 AppData TCC prompt가
  # 발생할 수 있다. 원격 nrs가 GUI 응답을 기다리며 멈추지 않도록 각 호출을 bounded하게 하고,
  # 한 번 timeout되면 같은 activation의 나머지 Shottr write를 건너뛴다.
  shottrDefaultsTimeoutBin = "${pkgs.coreutils}/bin/timeout";
  shottrDefaultsHelper = ''
    ${builtins.readFile ../../../../scripts/secrets/shottr-deadlines.sh}
    ${builtins.readFile ./defaults-helper.sh}
  '';
  shottrCfPreferencesWriter = import ./cfpreferences-writer-package.nix { inherit pkgs; };
in
{
  # 경로 가드: 폴더/북마크 이슈를 조기에 알림
  home.activation.checkShottrFolderAndWarn = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -d "${shottrDefaultFolder}" ]; then
      echo "Warning: Shottr default folder not found: ${shottrDefaultFolder}"
      echo "FolderActions activation should create this path."
    fi

    ${shottrDefaultsHelper}
    SHOTTR_DEFAULTS_WRITES_BLOCKED=0
    shottr_defaults_read current_folder \
      "${shottrDefaultsTimeoutBin}" /usr/bin/defaults "${shottrDomain}" defaultFolder
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
    ${shottrDefaultsHelper}
    shottr_defaults_write "${shottrDefaultsTimeoutBin}" /usr/bin/defaults "${shottrDomain}" defaultFolder "${shottrDefaultFolder}"
    shottr_defaults_write "${shottrDefaultsTimeoutBin}" /usr/bin/defaults "${shottrDomain}" saveFormat "Auto"
    shottr_defaults_write "${shottrDefaultsTimeoutBin}" /usr/bin/defaults "${shottrDomain}" KeyboardShortcuts_fullscreen -string '{"carbonModifiers":768,"carbonKeyCode":18}'   # ⇧⌘1
    shottr_defaults_write "${shottrDefaultsTimeoutBin}" /usr/bin/defaults "${shottrDomain}" KeyboardShortcuts_area -string '{"carbonKeyCode":20,"carbonModifiers":768}'          # ⇧⌘3
    shottr_defaults_write "${shottrDefaultsTimeoutBin}" /usr/bin/defaults "${shottrDomain}" KeyboardShortcuts_scrolling -string '{"carbonModifiers":768,"carbonKeyCode":19}'     # ⇧⌘2
    shottr_defaults_write "${shottrDefaultsTimeoutBin}" /usr/bin/defaults "${shottrDomain}" KeyboardShortcuts_ocr -string '{"carbonModifiers":6400,"carbonKeyCode":31}'          # ⌃⌥⌘O

    # Manual Scrolling Capture 활성화
    # Auto Scroll Capture는 Terminal, VS Code 등 비표준 스크롤 앱에서 화면이 짤림.
    # Manual 모드는 사용자가 직접 스크롤하며 캡처하므로 이런 앱에서도 정상 동작.
    # ref: https://shottr.cc/kb/faq
    # ref: https://hurricane-flower-fdf.notion.site/Manual-Scrolling-Capture-120d943b739b80bf868dd1009eeadc17
    shottr_defaults_write "${shottrDefaultsTimeoutBin}" /usr/bin/defaults "${shottrDomain}" scrollingManualEnabled -bool true
  '';

  # 라이센스 pre-fill (agenix secret → container CFPreferences)
  # Keychain 없는 새 맥북에서 Activate 버튼 1회 클릭만으로 활성화 가능
  #
  # macOS에서 agenix는 launchd agent(activate-agenix, RunAtLoad)로 시크릿을 복호화한다.
  # setupLaunchAgents가 agenix agent를 로드한 뒤 짧은 대기로 복호화 완료를 기다린다.
  # 라이센스는 defaults DB에 한번 기록되면 영구 보존되므로 실패해도 큰 문제 없음.
  home.activation.applyShottrLicenseFromSecret =
    lib.hm.dag.entryAfter [ "applyShottrCoreSettings" "setupLaunchAgents" ]
      ''
        ${shottrDefaultsHelper}
        _waited=0
        while [ ! -f "${shottrLicensePath}" ] && [ "$_waited" -lt 5 ]; do
          sleep 1
          _waited=$(( _waited + 1 ))
        done

        if [ ! -f "${shottrLicensePath}" ]; then
          echo "Note: Shottr license secret not yet available. License pre-fill skipped."
        else
          # Hostile/inherited activation environments may enable allexport or
          # pre-export either spelling. Scrub the parent first, then keep the
          # entire secret read/write interval in a subshell with allexport off.
          unset kc_license kc_vault KC_LICENSE KC_VAULT
          (
            set +x
            set +a
            unset kc_license kc_vault KC_LICENSE KC_VAULT
            kc_license="$(sed -n 's/^KC_LICENSE=//p' "${shottrLicensePath}" | tail -n 1 | tr -d '\r')"
            kc_vault="$(sed -n 's/^KC_VAULT=//p' "${shottrLicensePath}" | tail -n 1 | tr -d '\r')"
            export -n kc_license kc_vault

            if [ -n "$kc_license" ]; then
              shottr_defaults_write_stdin \
                "${shottrDefaultsTimeoutBin}" \
                "${shottrCfPreferencesWriter}/bin/shottr-cfpreferences-writer" \
                "${shottrPreferencesTarget}" \
                kc-license \
                < <(builtin printf '%s' "$kc_license")
            fi
            if [ -n "$kc_vault" ]; then
              shottr_defaults_write_stdin \
                "${shottrDefaultsTimeoutBin}" \
                "${shottrCfPreferencesWriter}/bin/shottr-cfpreferences-writer" \
                "${shottrPreferencesTarget}" \
                kc-vault \
                < <(builtin printf '%s' "$kc_vault")
            fi
            unset kc_license kc_vault KC_LICENSE KC_VAULT
          )
        fi
      '';

  # Shottr 재시작은 configuration.nix postActivation에서 처리.
  # activateSettings -u가 root 컨텍스트에서만 WindowServer와 통신 가능하므로,
  # postActivation에서 symbolic hotkeys 적용 → cfprefsd kill → activateSettings → Shottr 재시작
  # 순서로 실행한다. HM activation에서는 Shottr 앱 설정만 작성하고 재시작하지 않는다.
}

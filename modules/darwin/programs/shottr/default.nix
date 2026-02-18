# Shottr 설정 (macOS)
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

  # 핵심 설정 선언 적용
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

    /usr/bin/killall cfprefsd 2>/dev/null || true
  '';

  # 라이센스 pre-fill (agenix secret → defaults write)
  # Keychain 없는 새 맥북에서 Activate 버튼 1회 클릭만으로 활성화 가능
  home.activation.applyShottrLicenseFromSecret =
    lib.hm.dag.entryAfter [ "applyShottrCoreSettings" ]
      ''
        if [ ! -f "${shottrLicensePath}" ]; then
          echo "Note: Shottr license secret not found. License pre-fill skipped."
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
}

# Shortcuts 선언적 관리 — Cherri DSL 기반 빌드 파이프라인
#
# .cherri 소스 → substituteInPlace(상수 주입) → cherri --skip-sign(unsigned)
#   → shortcuts sign --mode anyone(signed) → open(import 다이얼로그 1클릭)
#
# personal Mac에서만 활성화 (work Mac에는 Tailscale/MiniPC 접근 불필요)
#
# NOTE: home.activation 스크립트에서 /usr/bin/* 절대 경로를 사용하는 이유:
# Home Manager activation은 최소한의 PATH로 실행되어 /usr/bin이 포함되지 않는다.
# ref: modules/darwin/programs/shottr/default.nix (L8-11 주석)
{
  lib,
  pkgs,
  inputs,
  constants,
  hostType,
  ...
}:

let
  cherri = inputs.cherri.packages.${pkgs.system}.default;

  # SSH 접속 정보 (MiniPC)
  sshHost = constants.network.minipcTailscaleIP; # "100.79.80.95"
  sshUser = "greenhead"; # nixosHosts."greenhead-minipc" 고정 username (flake.nix L101)
  sshPort = "22";
  # \\$PATH: Nix "..." → \$PATH → bash double-quote 내에서 literal $PATH로 전달
  sshPathExport = "export LC_ALL=en_US.UTF-8; export PATH='/run/current-system/sw/bin:/etc/profiles/per-user/${sshUser}/bin:/home/${sshUser}/.nix-profile/bin:/home/${sshUser}/.local/bin:\\$PATH'; ";

  shortcutName = "Prompt Render"; # .cherri의 #define name과 일치해야 함

  # Nix derivation: .cherri → unsigned .shortcut
  promptRenderShortcut = pkgs.stdenv.mkDerivation {
    pname = "prompt-render-shortcut";
    version = "1.0.0";
    src = ./sources;
    nativeBuildInputs = [ cherri ];

    buildPhase = ''
      # 상수 주입 (4개 플레이스홀더)
      substituteInPlace prompt-render.cherri \
        --replace-fail "@SSH_HOST@" "${sshHost}" \
        --replace-fail "@SSH_USER@" "${sshUser}" \
        --replace-fail "@SSH_PORT@" "${sshPort}" \
        --replace-fail "@SSH_PATH_EXPORT@" "${sshPathExport}"

      # --skip-sign: Nix sandbox에서 Apple ID 접근 불가
      # NOTE: --derive-uuids 사용 금지 — 모든 conditional/each의 GroupingIdentifier를
      #   동일 UUID로 만들어 Shortcuts.app이 if/else/endif 블록을 구분 불가 (PR #133)
      # NOTE: --output 플래그 미작동 확인 (Cherri v2.1.0) → 기본 출력명 사용
      cherri prompt-render.cherri --skip-sign
    '';

    installPhase = ''
      mkdir -p $out
      cp *_unsigned.shortcut $out/prompt-render.shortcut
    '';
  };
in
lib.mkIf (hostType == "personal") {
  # Home Manager activation: 서명 + import
  # ref: modules/darwin/programs/shottr/default.nix (L49-93) 의 home.activation 패턴
  home.activation.importShortcuts = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    _shortcut_name="${shortcutName}"

    # 멱등성: 이미 설치된 경우 skip
    # shortcuts list: 줄 단위로 이름 출력. -qxF: exact line match, fixed string (부분 매칭 방지)
    if /usr/bin/shortcuts list 2>/dev/null | /usr/bin/grep -qxF "$_shortcut_name"; then
      echo "Shortcut '$_shortcut_name' already exists, skipping import."
    else
      # 서명된 파일명이 Shortcuts.app 표시 이름이 됨 → 의미있는 이름 사용
      _temp_dir="$(/usr/bin/mktemp -d)"
      _temp_signed="$_temp_dir/${shortcutName}.shortcut"

      # 서명 (non-fatal: Apple ID 미로그인 시 경고만 출력)
      # --mode anyone: macOS 14.4+ 에서 유일하게 작동하는 모드
      # stderr의 "ERROR: Unrecognized attribute string flag '?'" 경고는 무해 (이슈 #131 확인)
      if /usr/bin/shortcuts sign \
        --mode anyone \
        --input "${promptRenderShortcut}/prompt-render.shortcut" \
        --output "$_temp_signed" 2>/dev/null; then
        echo "Shortcut '$_shortcut_name' signed. Opening for import..."
        /usr/bin/open "$_temp_signed"
        echo "Note: Click 'Add Shortcut' in the dialog to complete import."
      else
        echo "Warning: Shortcut signing failed. Ensure Apple ID is signed in."
        echo "  Manual import: shortcuts sign --mode anyone --input ${promptRenderShortcut}/prompt-render.shortcut --output /tmp/signed.shortcut && open /tmp/signed.shortcut"
      fi
    fi
  '';
}

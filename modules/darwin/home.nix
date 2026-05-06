# Home Manager 설정 (macOS)
{
  config,
  pkgs,
  lib,
  inputs,
  username,
  nixosConfigPath,
  nixosConfigDefaultPath,
  hostType,
  constants,
  ...
}:

let
  # backup 확장자 — backupFileExtension(nix)과 backupCommand 셸 스크립트의 fallback 양쪽에
  # 동일 값으로 흘러야 하므로 한 곳에 binding한다.
  hmBackupExt = "backup";
in
{
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  # home-manager backup 정책 (mkOutOfStoreSymlink atomic-rename collision 회피):
  #   - backupCommand는 home-manager activation 단계에서 non-symlink target에 한해 호출됨
  #     (symlink target은 home-manager가 자체적으로 처리하고 backupCommand는 호출되지 않는다).
  #     따라서 본 셸 스크립트는 regular file/directory 두 케이스만 분기한다.
  #     · regular file 충돌: rm -f로 unlink (사용자 명시 동의 — atomic-rename으로 깨진
  #       ephemeral 변경분의 보존 가치 0. 시나리오 B(사용자가 깨진 시간 동안 의도 변경)도
  #       silent loss 흡수 범위로 동의됨).
  #     · directory 충돌: rm -rf 위험 회피 위해 timestamped backup으로 보존.
  #   - backupFileExtension은 셸 스크립트 안에서 timestamp 확장자로 재사용되며,
  #     backupCommand 롤백 시 기존 backup 동작 fallback 역할도 한다.
  #   - 배경: Claude Code 등 외부 프로세스의 atomic rename(rename(2))으로
  #     mkOutOfStoreSymlink target이 일반 파일/디렉터리로 변해 다음 nrs에서
  #     stale .backup collision으로 막히는 사고를 자가 치유한다.
  home-manager.backupFileExtension = hmBackupExt;
  home-manager.backupCommand = pkgs.writeShellScript "hm-cleanup-stale-conflict" ''
    set -e
    # home-manager activation은 보통 "$targetPath"를 인자로 호출하지만, 메인터넌스 환경에서
    # 인자 없이 호출되는 경로가 실측 관찰됨(정확한 source 경로 미확인). default 빈 문자열로
    # 방어 처리하고 인자 없으면 early exit.
    target="''${1:-}"
    [ -n "$target" ] || exit 0
    if [ -d "$target" ] && [ ! -L "$target" ]; then
      # HOME_MANAGER_BACKUP_EXT는 home-manager가 backupFileExtension에서 export.
      # fallback은 위 hmBackupExt 동일 값으로 nix interpolation.
      dest="$target.''${HOME_MANAGER_BACKUP_EXT:-${hmBackupExt}}.$(date +%s)"
      mv -- "$target" "$dest"
      echo "[home-manager] backed up directory conflict: $target -> $dest" >&2
    else
      echo "[home-manager] cleaning conflict at: $target" >&2
      rm -f -- "$target"
    fi
  '';

  # Home Manager 모듈에 nixosConfigPath, nixosConfigDefaultPath, hostType, constants 전달
  home-manager.extraSpecialArgs = {
    inherit
      inputs
      nixosConfigPath
      nixosConfigDefaultPath
      hostType
      constants
      ;
  };

  home-manager.users.${username} =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      packages = import ../../libraries/packages.nix { inherit pkgs; };
    in
    {
      home.username = username;
      # mkForce: nix-darwin에서 users.users.${name}.home이 null이므로 강제 설정 필요
      home.homeDirectory = lib.mkForce "/Users/${username}";

      # 프로그램별 모듈 임포트
      imports = [
        # Secrets 관리 (agenix)
        inputs.agenix.homeManagerModules.default
        ../shared/programs/secrets

        # 공유 프로그램
        ../shared/programs/broot
        ../shared/programs/claude # shared로 이동됨
        ../shared/programs/codex # Codex CLI 호환 레이어
        ../shared/programs/direnv # 디렉토리별 개발 환경 자동 활성화
        ../shared/programs/git
        ../shared/programs/lazygit
        ../shared/programs/shell # 공통 shell 설정
        ../shared/programs/shell/darwin.nix # macOS 전용 shell 추가
        ../shared/programs/tmux
        ../shared/programs/neovim
        ../shared/programs/cheat # 터미널 cheatsheet 즉시 조회
        ../shared/programs/yazi # TUI 파일 매니저

        # macOS 전용
        ./programs/hammerspoon
        ./programs/vscode
        ./programs/folder-actions
        ./programs/ghostty
        ./programs/cmux
        ./programs/shottr
        ./programs/keybindings
        ./programs/ssh
      ];

      # CLI 도구 패키지 (libraries/packages.nix에서 공통 관리)
      home.packages = packages.shared ++ packages.darwinOnly;

      home.stateVersion = "25.05";
    };
}

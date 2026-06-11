# Homebrew 패키지 관리 (GUI 앱)
# 공통 cask(ghostty)는 모든 darwin 호스트에서 활성화
# personal 전용 앱은 hostType 가드로 분리
{
  config,
  pkgs,
  lib,
  hostType,
  ...
}:

{
  homebrew = lib.mkMerge [
    # ── 공통: 모든 darwin 호스트 ─────────────────────────────────
    {
      enable = true;

      # Homebrew Formula (CLI 도구) — 공통
      brews = [
        "playwright-cli" # AI 에이전트 브라우저 자동화 CLI (Playwright 기반, 토큰 효율적)
      ];

      # [Nix 전환이 불가능한 앱]
      # ghostty: pkgs.ghostty-bin은 CLI 바이너리만 제공하고 macOS .app 번들을 포함하지 않음.
      #          Ghostty.app은 Homebrew Cask로만 설치 가능.
      casks = [
        "ghostty"
      ];
    }

    # ── personal 전용 ───────────────────────────────────────────
    (lib.mkIf (hostType == "personal") {
      # 선언되지 않은 앱 정리
      onActivation = {
        autoUpdate = true;
        upgrade = true; # brew upgrade 활성화 — auto_updates cask 포함 여부는 아래 greedyCasks 정책을 따름
        cleanup = "none"; # 선언되지 않은 앱을 자동 삭제하지 않음
      };

      # [업그레이드 정책]
      # upgrade=true: nrs 실행 시 자체 업데이터가 없는 cask와 formula를 brew upgrade.
      # greedyCasks=false: auto_updates가 있는 cask(1Password 등)는 brew upgrade 대상에서 제외한다.
      #   해당 앱은 자체 업데이터가 최신을 유지하므로, nrs activation마다 대용량 .dmg를
      #   재다운로드할 이유가 없다 (greedyCasks=true 시절 Docker Desktop 등 수백 MB를 매번 재다운로드했다).
      #   cask 목록 등재 = 설치 보장은 그대로이며, 강제 동기화만 끈다.
      greedyCasks = false;

      # Homebrew Tap (서드파티 저장소)
      taps = [
        "laishulu/homebrew" # macism (macOS 입력 소스 전환 CLI)
      ];

      # Homebrew Formula (CLI 도구) — personal 전용
      brews = [
        "laishulu/homebrew/macism" # macOS 입력 소스 전환 (Neovim 한영 전환 자동화)
        "sox" # 오디오 처리 (Claude Code /voice 모드)
      ];

      # Homebrew Cask (GUI 앱)
      #
      # [adopt 가이드] 새 Mac 또는 직접 설치된 앱이 있는 경우
      #
      # nix-darwin은 이 목록으로 `brew bundle`을 실행하고, brew bundle은 cask 설치 시
      # `--force`가 없으면 `--adopt`를 자동으로 붙인다 (Homebrew bundle/cask.rb).
      # 따라서 /Applications에 동일 앱이 이미 있어도 대개 자동 adopt되어 에러 없이 통과한다 —
      # 기존 앱을 삭제·백업하지 않고 Homebrew 관리로 등록한다.
      # (auto_updates cask[Raycast·1Password 등]는 버전 비교 없이 기존 앱을 채택하고,
      #  그 외 cask만 source와 번들 버전을 비교한다 — Homebrew cask/artifact/moved.rb)
      #
      # 단 기존 앱과 source의 번들 버전이 다르면 adopt가 거부될 수 있다. 이때는:
      #   1) 기존 앱을 최신으로 맞춘 뒤 다시 nrs → 버전 일치로 자동 adopt
      #   2) 이 목록에서 해당 cask 제거 → 선언적 관리 포기
      #   3) 수동으로 먼저 전환: brew install --cask --adopt raycast 1password ...
      #
      # cleanup="none"이므로 미adopt 앱이 남아있어도 삭제되지는 않지만,
      # brew가 해당 앱의 존재를 모르므로 업데이트/관리가 불가능한 상태로 남는다.
      #
      # [Nix 패키지로 전환한 앱]
      # shottr → libraries/packages.nix darwinOnly로 이동 (pkgs.shottr가 macOS .app 번들 포함)
      #
      # [Nix 전환이 불가능한 앱]
      # fork: 상용 Git GUI, nixpkgs에 없음
      # [Homebrew에서 제거한 앱]
      # docker-desktop: 자체 업데이터가 강력하고 이 프로젝트에서 선언적 관리 이점이 없음.
      #        greedyCasks 시절 nrs activation마다 Docker.dmg(수백 MB)를 재다운로드하던 주원인.
      #        기존 /Applications/Docker.app은 cleanup="none"이라 유지되며 자체 업데이트에 위임.
      # figma: 자체 업데이터가 적극적으로 버전을 변경하여 Homebrew가 관리하는 버전과 불일치 발생.
      #        adopt 시 버전 불일치로 설치 거부됨. 자체 업데이터에 위임.
      # slack: 수동 설치 선호. 자체 업데이터에 위임.
      # codex: declarative nix overlay로 전환 — modules/shared/programs/codex/default.nix (#890).
      #        cleanup="none"이라 cask 목록 제거만으론 미삭제되므로 codex activation의
      #        cleanupLegacyCodexCli가 `brew uninstall --cask codex`로 정리한다.
      #
      casks = [
        "raycast"
        "rectangle"
        "hammerspoon"
        "homerow"
        "fork"
        "monitorcontrol"
        # 1Password 비밀번호/SSH 키/PAT 통합 (PRD #780 Phase 1)
        # - 1password: 데스크탑 앱 (vault, SSH agent, biometric)
        # - 1password-cli: op CLI (op_get helper + Shell Plugin 지원)
        "1password"
        "1password-cli"
      ];

      # Mac App Store 앱 (mas 필요)
      # masApps = {
      #   # "앱이름" = 앱스토어ID;
      # };
    })
  ];

  # ── Homebrew tap trust ──────────────────────────────────────
  # Homebrew는 third-party tap의 formula/cask 로드 시 명시적 trust를 기본 요구한다
  # (HOMEBREW_REQUIRE_TAP_TRUST default: true — env_config.rb). trust 미등록 tap의
  # formula가 brew bundle 대상이면 "Refusing to load formula ..."로 activation이 실패한다.
  # opt-out(HOMEBREW_NO_REQUIRE_TAP_TRUST)은 "will be removed in a later release"라 비채택.
  #
  # brew bundle(activationScripts.homebrew)보다 먼저 실행되는 extraActivation에서
  # 선언된 taps를 brew trust로 등록한다 — 이 목록에 tap을 선언하는 행위 자체를
  # 신뢰 의사 표명으로 간주한다. trust.json은 additive로만 관리한다: 선언 해제된
  # tap을 untrust로 회수하지 않는다 (cleanup = "none"과 동일한 보수성. 수동 trust한
  # tap을 activation이 임의 회수하지 않기 위함).
  #
  # 실행 형태는 nix-darwin의 brew bundle 호출과 동일하게 맞춘다 (sudo --user --set-home):
  # brew는 root 실행을 거부하고, trust.json 경로가 $HOME 기준(~/.homebrew/trust.json,
  # sudo env_reset으로 XDG_CONFIG_HOME 미전파)이므로 bundle이 읽는 파일과 일치해야 한다.
  # trust 서브커맨드가 없는 구버전 Homebrew에서는 감지 후 no-op (멱등: 재등록 시
  # "Already trusted" 출력, exit 0).
  system.activationScripts.extraActivation.text =
    let
      cfg = config.homebrew;
      tapNames = map (tap: tap.name) cfg.taps;
      brewTrust = ''PATH="${cfg.prefix}/bin:$PATH" sudo --preserve-env=PATH --user=${lib.escapeShellArg cfg.user} --set-home "${cfg.prefix}/bin/brew" trust'';
    in
    lib.mkIf (cfg.enable && tapNames != [ ]) ''
      # Homebrew tap trust — brew bundle 이전에 선언 tap 신뢰 등록
      if [ -f "${cfg.prefix}/bin/brew" ]; then
        if ${brewTrust} --help >/dev/null 2>&1; then
          echo >&2 "Trusting declared Homebrew taps..."
          ${brewTrust} --tap ${lib.escapeShellArgs tapNames}
        fi
      fi
    '';
}

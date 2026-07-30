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

# ── Homebrew tap trust ──────────────────────────────────────
# Homebrew는 third-party tap의 formula/cask 로드 시 명시적 trust를 기본 요구한다
# (HOMEBREW_REQUIRE_TAP_TRUST default: true — env_config.rb). trust 미등록 tap의
# formula가 brew bundle 대상이면 "Refusing to load formula ..."로 activation이 실패한다.
# opt-out(HOMEBREW_NO_REQUIRE_TAP_TRUST)은 "will be removed in a later release"라 비채택.
#
# 선언된 taps를 brew bundle/cleanup보다 먼저 brew trust로 등록한다 — 이 목록에 tap을
# 선언하는 행위 자체를 신뢰 의사 표명으로 간주한다. trust.json은 additive로만 관리한다:
# 선언 해제된 tap을 untrust로 회수하지 않는다 (cleanup = "none"과 동일한 보수성.
# 수동 trust한 tap을 activation이 임의 회수하지 않기 위함).
#
# 실행 형태는 nix-darwin의 brew bundle 호출과 동일하게 맞춘다 (sudo --user --set-home
# + 동일 env): brew는 root 실행을 거부하고, trust.json 경로가 $HOME 기준
# (~/.homebrew/trust.json, sudo env_reset으로 XDG_CONFIG_HOME 미전파)이므로 bundle이
# 읽는 파일과 일치해야 한다. extraEnv가 HOMEBREW_USER_CONFIG_HOME처럼 trust store
# 위치를 바꾸는 경우에도 두 단계가 같은 trust.json을 보도록 env 구성을 bundle과 맞춘다.
# trust 서브커맨드가 없는 구버전 Homebrew에서는 감지 후 no-op (멱등: 재등록 시
# "Already trusted" 출력, exit 0).
let
  cfg = config.homebrew;

  # github.com 기본형 URL을 canonical "owner/repo" tap 이름으로 정규화한다
  # (Homebrew Tap.remote_to_reference와 동일 의도 — scheme://, user@, SCP 콜론,
  # .git, trailing slash 변형 흡수). GitHub 기본형(homebrew-* repo)이 아니면 null.
  # 정규화 순서는 Homebrew Tap.normalize_remote와 동일: strip → downcase →
  # trailing slash 전체 제거 → .git 제거. 반환값은 lowercase다.
  canonicalGitHubName =
    url:
    let
      lowered = lib.toLower (lib.trim url);
      noSlash = builtins.match "(.*[^/])/*" lowered;
      stripped = lib.removeSuffix ".git" (if noSlash == null then lowered else builtins.elemAt noSlash 0);
      # 캡처 순서: [ scheme userinfo owner repo ]
      m = builtins.match "([a-z][a-z0-9+.-]*://)?([^@/]+@)?github\\.com[:/]([^/]+)/homebrew-(.+)" stripped;
      owner = builtins.elemAt m 2;
      repo = builtins.elemAt m 3;
    in
    if m == null then null else "${owner}/${repo}";

  # Homebrew Bundle dsl.rb의 HOMEBREW_TAP_ARGS_REGEX와 동일한 tap name 형식.
  # 캡처 순서: [ owner homebrew-접두(optional) repo ]. downcase된 입력에 적용한다.
  tapNameRegex = "([a-z0-9_-]+)/(homebrew-)?([a-z0-9_-]+)";

  # 선언된 tap 이름을 Homebrew Bundle sanitize_tap_name(dsl.rb의
  # HOMEBREW_TAP_ARGS_REGEX)과 동일하게 canonical name으로 정규화한다:
  # downcase 후 repo 부분의 선택적 leading "homebrew-" 제거.
  # bundle은 "user/homebrew-repo" 선언을 "user/repo" tap으로 처리하므로,
  # trust 측 계산도 같은 identity를 기준으로 해야 한다. 반환값은 lowercase다.
  # 형식 불일치 name은 null — 아래 assertions가 eval 시점에 거부한다.
  sanitizeTapName =
    name:
    let
      m = builtins.match tapNameRegex (lib.toLower name);
      owner = builtins.elemAt m 0;
      repo = builtins.elemAt m 2;
    in
    if m == null then null else "${owner}/${repo}";

  # trust principal 결정 — 항상 remote URL 형태로 넘긴다:
  # - clone_target tap: 그 URL 자체가 principal (Homebrew Tap#matches_reference?는
  #   user/repo reference를 default GitHub remote에만 매칭).
  # - 일반 tap: 선언이 의미하는 default GitHub remote URL을 명시적으로 trust한다.
  #   이름으로 trust하면 brew trust가 설치된 tap의 "현재" remote를 principal로
  #   저장하므로(Trust.trust_name → Tap#reference), 로컬에서 remote가 drift된 tap을
  #   조용히 신뢰하게 된다. URL은 remote_to_reference가 canonical name으로 정규화해
  #   선언 의도를 고정하고, drift된 tap은 bundle 단계에서 untrusted로 fail-loud한다.
  # 형식 불일치 name은 null 전파 (assertions가 거부) — elemAt 범위 오류 같은
  # 불친절한 eval 에러 대신 명확한 assertion 메시지가 먼저 도달하도록 total 함수로 둔다.
  defaultRemote =
    name:
    let
      sanitized = sanitizeTapName name;
      parts = lib.splitString "/" sanitized;
      owner = lib.elemAt parts 0;
      repo = lib.elemAt parts 1;
    in
    if sanitized == null then null else "https://github.com/${owner}/homebrew-${repo}";
  trustTargets = lib.filter (t: t != null) (
    map (tap: if tap.clone_target != null then tap.clone_target else defaultRemote tap.name) cfg.taps
  );

  # trust 명령의 env는 "그 직후 trust.json을 읽는 소비자"와 정확히 일치해야 한다 —
  # XDG_CONFIG_HOME류 변수가 trust store 위치 자체를 바꾸기 때문이다. nix-darwin은
  # bundle에는 extraEnv를 적용하지만 cleanup check에는 HOMEBREW_NO_AUTO_UPDATE=1만
  # 하드코딩하므로, prelude도 소비자별로 env를 달리 구성한다.
  #
  # trust 서브커맨드 존재는 프로세스 기동(--help probe, ruby ~1초) 대신 cmd 파일로
  # 감지한다. Homebrew repository layout이 두 가지다: Apple Silicon은 prefix가 곧
  # repo(/opt/homebrew/Library/...), Intel은 prefix/Homebrew가 repo
  # (/usr/local/Homebrew/Library/...).
  #
  # updateBeforeTrust: trust를 모르는 구버전 brew + autoUpdate 구성에서는 직후
  # bundle이 auto-update로 brew를 갱신한 뒤 trust 강제가 켜져 거부된다 (이번 회귀의
  # 원인 경로와 동일 구조). 그 경우 trust 등록 전에 먼저 update해 1회성 실패를
  # 제거한다. cleanup check prelude는 구버전 brew가 trust를 강제하지 않아 불필요.
  mkTrustScript =
    {
      env,
      updateBeforeTrust ? false,
    }:
    let
      runBrew = ''PATH="${cfg.prefix}/bin:$PATH" sudo --preserve-env=PATH --user=${lib.escapeShellArg cfg.user} --set-home env ${lib.concatStringsSep " " env} "${cfg.prefix}/bin/brew"'';
      trustCmdExists = ''{ [ -f "${cfg.prefix}/Library/Homebrew/cmd/trust.rb" ] || [ -f "${cfg.prefix}/Homebrew/Library/Homebrew/cmd/trust.rb" ]; }'';
    in
    ''
      # Homebrew tap trust — brew bundle/cleanup 이전에 선언 tap 신뢰 등록
      if [ -f "${cfg.prefix}/bin/brew" ]; then
        ${lib.optionalString updateBeforeTrust ''
          if ! ${trustCmdExists}; then
            echo >&2 "brew trust unavailable — updating Homebrew first..."
            ${runBrew} update || true
          fi
        ''}
        if ${trustCmdExists}; then
          echo >&2 "Trusting declared Homebrew taps..."
          ${runBrew} trust --tap ${lib.escapeShellArgs trustTargets}
        fi
      fi
    '';

  trustEnabled = cfg.enable && trustTargets != [ ];
  # bundle용: brewBundleCmd와 동일한 env 구성 (HOMEBREW_NO_AUTO_UPDATE + extraEnv)
  bundleTrustScript = mkTrustScript {
    env =
      lib.optional (!cfg.onActivation.autoUpdate) "HOMEBREW_NO_AUTO_UPDATE=1"
      ++ lib.mapAttrsToList (k: v: "${k}=${lib.escapeShellArg v}") cfg.onActivation.extraEnv;
    updateBeforeTrust = cfg.onActivation.autoUpdate;
  };
  # cleanup check용: nix-darwin cleanup check의 hardcoded env와 동일하게 구성
  checkTrustScript = mkTrustScript { env = [ "HOMEBREW_NO_AUTO_UPDATE=1" ]; };
in
{
  homebrew = lib.mkMerge [
    # ── 공통: 모든 darwin 호스트 ─────────────────────────────────
    {
      enable = true;

      # Homebrew Formula (CLI 도구) — 공통
      #
      # [일시적 Homebrew 우회 — upstream 수정 시 Nix로 환원]
      # 아래 casks의 [Nix 전환이 불가능한 앱]과 달리, 이 항목은 영구 제약이 아니라
      # upstream 버그가 고쳐지면 되돌리는 임시 예외다.
      #
      # awscli: nixpkgs darwin의 libffi(Apple libffi-40 기반)가 macOS 27에서 실행 불가.
      #   nixpkgs는 purity를 위해 시스템 /usr/lib/libffi-trampolines.dylib 대신 자기 자신의
      #   trampolines dylib을 dlopen하도록 closures.c를 패치하는데(postPatch의 /usr/lib → $out/lib),
      #   그 dylib은 trampoline.S만으로 링크된 특수 형태라 macOS 27 dyld의 chained fixups 검증에
      #   걸린다 ("seg_count exceeds number of segments"). dlopen이 실패하면 closures.c의
      #   assert(trampoline_handle)에서 abort하므로, nix python의 ctypes/cffi 콜백을 쓰는 패키지가
      #   통째로 죽는다 (awscli2·awscli v1 모두 `aws --version`조차 실행 불가).
      #   nixpkgs-unstable에도 아직 수정이 없고, libffi overlay로 고치면 508개 파생물을 소스
      #   빌드해야 해 이 저장소의 cache hit 최우선 정책(flake.nix CIR)과 충돌한다.
      #   Homebrew bottle은 arm64 네이티브 + 시스템 dyld 경로라 정상 동작한다.
      #   재검토(이슈 #1194): nixpkgs가 이 libffi 문제를 고치면 pkgs.awscli2로 되돌린다.
      #   저장소 루트에서 아래를 실행해 버전이 출력되면 해결된 것이다. `--inputs-from .`이 없으면
      #   flake registry의 nixpkgs를 평가해 이 저장소가 고정한 revision과 다른 것을 검사하게 된다:
      #     nix run --inputs-from . nixpkgs#awscli2 -- --version
      brews = [
        "awscli" # AWS CLI v2 (aarch64 네이티브)
        # playwright-cli: nixpkgs 미수록 (playwright/-driver/-mcp/-test만 존재). 수록되면 Nix로 환원한다.
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

  # tap 선언 형식/조합을 eval 시점에 거부한다 (런타임 silent 실패 방지).
  # homebrew.enable=false인 host는 trust hook이 비활성이므로 검사하지 않는다
  # (nix-darwin homebrew activation 자체도 mkIf cfg.enable로 게이트됨).
  #
  # 1) name 형식: Bundle HOMEBREW_TAP_ARGS_REGEX 불일치 name(슬래시 없음, 3개
  #    세그먼트 등)은 trust principal 계산이 불가능하고, 묵인하면 의도하지 않은
  #    principal을 조용히 trust하거나 불친절한 eval 에러가 난다.
  # 2) clone_target alias: GitHub 기본형 URL인데 canonical name이 선언명과 다르면
  #    brew trust가 URL을 canonical name으로 정규화해 저장하므로 URL principal이
  #    보존되지 않고, 설치된 custom remote tap은 name reference 매칭을 거부당해
  #    trust 등록 후에도 untrusted로 남는다.
  assertions = lib.concatMap (tap: [
    {
      assertion = !cfg.enable || builtins.match tapNameRegex (lib.toLower tap.name) != null;
      message = ''
        homebrew.taps: "${tap.name}"은 Homebrew Bundle의 tap name 형식
        (user/repo 또는 user/homebrew-repo)이 아니라 trust principal을
        계산할 수 없다. user/repo 형식으로 선언하라.'';
    }
    {
      assertion =
        !cfg.enable
        || tap.clone_target == null
        || (
          let
            canonical = canonicalGitHubName tap.clone_target;
          in
          # canonicalGitHubName과 sanitizeTapName 모두 lowercase를 반환한다
          canonical == null || canonical == sanitizeTapName tap.name
        );
      message = ''
        homebrew.taps: "${tap.name}"의 clone_target(${toString tap.clone_target})은
        GitHub 기본형 URL이라 brew trust가 canonical name으로 정규화해 저장하는데,
        선언된 tap 이름과 달라 설치된 tap에 trust가 매칭되지 않는다. tap 이름을
        canonical name으로 선언하거나 GitHub 기본형이 아닌 remote를 사용하라.'';
    }
  ]) cfg.taps;

  # nix-darwin의 homebrew activation slot(activationScripts.homebrew.text)에 mkBefore로
  # prepend하여, groups/users 이후라는 기존 brew 실행 순서 계약을 유지하면서 bundle보다
  # 먼저 trust를 등록한다.
  system.activationScripts.homebrew.text = lib.mkIf trustEnabled (lib.mkBefore bundleTrustScript);

  # cleanup = "check"는 checks 단계(activation 순서상 homebrew slot보다 앞)에서
  # brew bundle cleanup을 실행해 formula를 로드하므로(nix-darwin homebrew 모듈이
  # system.checks.text에 등록), 같은 trust prelude를 checks에도 mkBefore로 prepend한다.
  # darwin-rebuild check 모드에서도 trust 등록이 수행되는 부수효과가 있으나,
  # 멱등·additive·선언 의도 범위 내 쓰기라 수용한다.
  system.checks.text = lib.mkIf (trustEnabled && cfg.onActivation.cleanup == "check") (
    lib.mkBefore checkTrustScript
  );
}

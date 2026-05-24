# Codex CLI 설정 (공통)
# 바이너리: macOS/NixOS 공통 — mise npm backend(npm:@openai/codex)로 설치 관리.
#   버전 pinning 없음(@latest) + 자동 업데이트 없음(멱등 가드로 재호출 차단).
#   설치/정리: home.activation.{cleanupLegacyCodexCli, installCodexCli, cleanupManualNodeCodex}.
# Claude Code 스킬을 Codex에서도 사용할 수 있도록 심볼릭 링크 관리
# trust는 런타임 mutation(사용자 승인, 디렉토리당 1회)이 SoT. template은 trust를
# 하드코딩하지 않으며, ~/.codex/config.toml은 activation의 syncCodexConfig가
# template-declared leaf는 template wins, template 밖의 top-level 키/sibling leaf/
# [projects.*]/template 없는 mcp_servers.<이름>은 preserve하는 방식으로 merge한 regular file.
# (상세 policy는 home.activation.syncCodexConfig 위 주석 참조.)
{
  config,
  pkgs,
  lib,
  nixosConfigPath,
  ...
}:

let
  # Codex config template. Nix 상대경로(./files/...)를 쓰면 현재 flake 소스 트리에서
  # store로 복사되므로, worktree에서 `nrs --flake .` 로 빌드해도 그 worktree의 최신
  # 파일이 seed로 반영된다. `nixosConfigPath`(=항상 메인 체크아웃 경로) 기반 문자열을
  # 쓰면 worktree 변경이 누락된다.
  codexConfigSeedPath =
    if pkgs.stdenv.isDarwin then ./files/config.darwin.toml else ./files/config.toml;
  # activation에서 repo-managed 키와 사용자 소유 섹션을 merge하는 Python 스크립트.
  # 동일하게 store path로 copy되므로 현 flake 기준으로 동작한다.
  codexSyncScript = ./files/sync-codex-config.py;
  # tomlkit 포함 python3. 정의는 `libraries/python-runtimes.nix` 단일 소스 (flake.nix의
  # `packages.${system}.pythonWithTomlkit` output도 같은 파일을 import하여 store path를 공유).
  pythonWithTomlkit =
    (import ../../../../libraries/python-runtimes.nix { inherit pkgs; }).pythonWithTomlkit;
  # Claude 파일 경로 (공유 소스)
  claudeFilesPath = "${nixosConfigPath}/modules/shared/programs/claude/files";

  # ─── Shared skill 노출 정책 (direct Codex 글로벌, #486) ───
  # SoT: 아래 두 리스트. 독립 감사는 scripts/ai/verify-ai-compat.sh가 수행한다.

  # 노출 대상 — SoT: 아래 exposedCodexSkills 리스트
  exposedCodexSkills = [
    "analyzing-da-sessions"
    "create-issue"
    "create-pr"
    "grill-me"
    "parallel-audit"
    "playwright-cli"
    "review-pr-feedback"
    "run-da"
    "syncing-codex-harness"
    "write-handoff"
  ];

  # 의도적 비노출 — SoT: 아래 intentionallyNotExposed 리스트. 정책 선언 전용.
  # Nix evaluation에서 직접 소비되지 않으며 (lazy eval로 자동 생략),
  # verify-ai-compat.sh가 독립 감사 오라클로 이 목록을 재확인한다.
  # 이 리스트 멤버가 ~/.codex/skills/ 에 존재하면 verify가 FAIL한다.
  intentionallyNotExposed = [
    # set-icons: Claude UI(status bar) 전용
    "set-icons"
    # using-claude-p: Claude -p/--print 사용 가이드 (Codex 무관)
    "using-claude-p"
    # using-codex-exec: Codex 자기 참조 방지 (PR #212)
    "using-codex-exec"
    # codex-fan-out: Codex 세션은 native subagent fan-out이 기본 경로이므로 자기 참조가 된다.
    # 이 스킬은 Claude/headless 세션에서 codex exec subprocess를 구동하는 패턴용.
    "codex-fan-out"
  ];

  mkCodexSkillEntry = name: {
    name = ".codex/skills/${name}";
    value.source = config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/${name}";
  };
  codexSkillEntries = builtins.listToAttrs (map mkCodexSkillEntry exposedCodexSkills);
in
{
  # ─── 글로벌 설정 (~/.codex/) ───

  home.file = {
    # 글로벌 AGENTS.md - Claude의 CLAUDE.md와 동일 소스 공유
    ".codex/AGENTS.md".source = config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/CLAUDE.md";

    # run-da Arbiter selective consistency harness. run-da 스킬이 Codex에도 노출되므로
    # Claude와 동일 source를 Codex scope에도 미러링하여 `~/.codex/scripts/fleiss-kappa.py`를
    # 런타임에서 사용 가능하게 한다.
    ".codex/scripts/fleiss-kappa.py".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/scripts/fleiss-kappa.py";

    # Codex 0.124+ stable hooks (issue #585 / epic #584).
    # Claude `~/.claude/hooks/*` 무변경 보장이 필요하므로 Codex 전용 사본을 분리한다.
    # 사본은 modules/shared/programs/codex/files/hooks/ 에서 mkOutOfStoreSymlink로 노출.
    # Stop hook은 _stop-dispatcher.sh 단일 entry로 inline [[hooks.Stop]]에 등록되며
    # dispatcher가 record-last-stop → nrs-session-cleanup을 순차 호출한다.
    ".codex/hooks/record-prompt-submit.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${nixosConfigPath}/modules/shared/programs/codex/files/hooks/record-prompt-submit.sh";
    ".codex/hooks/record-last-stop.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${nixosConfigPath}/modules/shared/programs/codex/files/hooks/record-last-stop.sh";
    ".codex/hooks/nrs-session-cleanup.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${nixosConfigPath}/modules/shared/programs/codex/files/hooks/nrs-session-cleanup.sh";
    ".codex/hooks/_stop-dispatcher.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${nixosConfigPath}/modules/shared/programs/codex/files/hooks/_stop-dispatcher.sh";
    # PostToolUse pinning-alert hook (issue #603) — apply_patch envelope + Edit/Write/NotebookEdit warn-only.
    ".codex/hooks/pinning-alert.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${nixosConfigPath}/modules/shared/programs/codex/files/hooks/pinning-alert.sh";
    ".codex/hooks/pinning-guard.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${nixosConfigPath}/modules/shared/programs/codex/files/hooks/pinning-guard.sh";
    ".codex/lib/pinning-patterns.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${nixosConfigPath}/modules/shared/programs/claude/files/lib/pinning-patterns.sh";
    ".codex/lib/hook-runtime.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${nixosConfigPath}/modules/shared/programs/claude/files/lib/hook-runtime.sh";
  }
  # 글로벌 스킬 (Claude와 동일 소스 공유) — exposedCodexSkills에서 자동 생성
  // codexSkillEntries;

  # ─── ~/.codex/config.toml 동기화 (activation) ───
  # Ownership policy: template이 선언한 leaf만 overwrite (재귀, leaf 단위).
  # template이 선언하지 않은 나머지는 preserve:
  #   - [projects.*]                    (runtime trust — codex CLI가 append; template에서 선언 금지)
  #   - template 밖의 top-level 키       (사용자/새 Codex CLI 테이블)
  #   - template 선언 테이블 안의 sibling leaf (예: [features].my_extra_flag)
  #   - [mcp_servers.<template에 없는 이름>]  (codex mcp add 등)
  # 결과는 regular file (mode 0600). symlink 기반 관리와 달리 codex CLI의 config write가
  # repo 원본에 write-through되지 않아 git working tree가 오염되지 않는다.
  # 동일 ownership policy는 `sync-codex-config.py check` 모드가 drift 검증에 재사용한다
  # (writer와 checker가 _walk_template_leaves를 공유하여 정책 drift를 차단).
  home.activation.syncCodexConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    config_dir="$HOME/.codex"
    $DRY_RUN_CMD mkdir -p "$config_dir"
    $DRY_RUN_CMD ${pythonWithTomlkit}/bin/python3 \
      ${codexSyncScript} \
      "${codexConfigSeedPath}" \
      "$config_dir/config.toml"
  '';

  # ─── Codex CLI 설치 (mise npm backend — macOS + NixOS 공통) ───
  # nix(GitHub 바이너리)/brew cask 대신 mise npm backend(npm:@openai/codex)로 통일한다.
  # 3단계 DAG: 레거시 정리 → 설치 → 수동 npm 잔재 정리. 전부 non-fatal로,
  # mise/node 부재나 네트워크 실패가 nrs(home-manager activation) 전체를 깨지 않게 한다.

  # (1) 레거시 Codex CLI 정리
  #   - NixOS: ~/.local/bin/codex (과거 GitHub releases ELF; HM 미추적 regular file)
  #   - macOS: brew cask codex (homebrew cleanup="none"이라 cask 목록 제거만으론 미삭제)
  #     darwin wrapper ~/.local/bin/codex(symlink)는 home.file 항목 제거로 HM이 자동 정리.
  home.activation.cleanupLegacyCodexCli = lib.hm.dag.entryAfter [ "writeBoundary" ] (
    lib.optionalString pkgs.stdenv.isLinux ''
      legacy_bin="$HOME/.local/bin/codex"
      if [ -f "$legacy_bin" ] && [ ! -L "$legacy_bin" ]; then
        if ${pkgs.file}/bin/file -b "$legacy_bin" | ${pkgs.gnugrep}/bin/grep -q ELF; then
          echo "Removing legacy GitHub-release Codex CLI at $legacy_bin"
          $DRY_RUN_CMD rm -f "$legacy_bin"
        fi
      fi
    ''
    + lib.optionalString pkgs.stdenv.isDarwin ''
      # Apple Silicon 전용 경로 — Intel Mac(/usr/local/bin/brew)은 이 프로젝트 범위 밖.
      # brew 부재 시 아래 -x 가드로 no-op.
      brew_bin="/opt/homebrew/bin/brew"
      if [ -x "$brew_bin" ] && "$brew_bin" list --cask codex >/dev/null 2>&1; then
        echo "Uninstalling Homebrew cask codex (migrated to mise npm backend)"
        $DRY_RUN_CMD "$brew_bin" uninstall --cask codex \
          || echo "Warning: 'brew uninstall --cask codex' failed (non-fatal)"
      fi
    ''
  );

  # (2) mise npm backend로 Codex CLI 설치
  #   - node 보장: 글로벌 node가 없을 때만 mise use -g node@lts. node는 npm backend 전반의
  #     공통 선행조건이지만, 현재 npm backend 도구가 codex 하나뿐이라 별도 ensureMiseNode 모듈로
  #     분리하지 않고 여기서 보장한다(YAGNI). npm backend 도구가 늘면 그때 공통 activation으로 분리.
  #     node@lts: 버전을 pin하지 않고 최초 설치 시점의 최신 LTS를 받는다. 이후에는 그 버전이 유지되며
  #     사용자가 명시적으로 mise upgrade 하기 전까지 자동 갱신되지 않는다(자동 추적이 아니라 1회 고정).
  #     NixOS는 소스 빌드 회피를 위해 prebuilt 강제(MISE_*_COMPILE=0; shell/nixos.nix와 동일 의도).
  #   - 멱등 가드: command -v codex / mise which codex 는 수동 npm·legacy 바이너리에 속으므로 쓰지 않고,
  #     mise config 등록 + 실제 installed된 backend(mise ls --json의 installed:true)로 판정한다.
  #     기존 사용자의 수동 npm 글로벌 codex는 config 미등록이라 가드에 안 잡히므로, 마이그레이션
  #     최초 1회는 @latest로 설치되어 버전 점프가 생길 수 있다(의도된 전환; 이후 nrs는 가드로 skip).
  home.activation.installCodexCli = lib.hm.dag.entryAfter [ "cleanupLegacyCodexCli" ] ''
    mise_bin="${pkgs.mise}/bin/mise"
    if [ ! -x "$mise_bin" ]; then
      echo "Warning: mise not found; skipping Codex CLI install (non-fatal)"
    else
      # NixOS는 mise의 node 소스 빌드를 막고 prebuilt를 강제한다(shell/nixos.nix와 동일 의도). macOS는 불필요.
      ${lib.optionalString pkgs.stdenv.isLinux "export MISE_NODE_COMPILE=0 MISE_ALL_COMPILE=0"}
      # 글로벌 node 보장. mise which는 로컬 .mise.toml에도 반응하므로 -g --current로 글로벌만 확인한다.
      node_ok=1
      if ! "$mise_bin" ls -g --current node 2>/dev/null | grep -q .; then
        echo "Installing node@lts via mise (Codex CLI dependency)..."
        $DRY_RUN_CMD "$mise_bin" use -g node@lts \
          || { node_ok=0; echo "Warning: 'mise use -g node@lts' failed; skipping Codex CLI install (non-fatal)"; }
      fi
      if [ "$node_ok" = 1 ]; then
        # config 등록 + installed:true인 backend만 "이미 관리됨"으로 판정한다.
        # length>0만 보면 config 등록 후 install 실패한 [{installed:false}] 상태에 속아 영구 미설치로 고착된다.
        if "$mise_bin" ls -g --current --json npm:@openai/codex 2>/dev/null \
            | ${pkgs.jq}/bin/jq -e '[.[] | select(.installed == true)] | length > 0' >/dev/null 2>&1; then
          echo "Codex CLI already managed by mise npm backend"
        else
          echo "Installing Codex CLI via mise npm backend (npm:@openai/codex)..."
          $DRY_RUN_CMD "$mise_bin" use -g npm:@openai/codex \
            || echo "Warning: Codex CLI install via mise skipped (non-fatal)"
        fi
      fi
    fi
  '';

  # (3) mise node 글로벌의 수동 npm @openai/codex 잔재 제거 (일회성 마이그레이션)
  #   전환 전 수동 `npm install -g @openai/codex`로 깔린 잔재를 정리한다. mise npm backend 정착
  #   이후에는 재발생하지 않으므로 한동안 멱등 no-op으로 남는다(향후 제거 가능).
  #   PATH상 node/<ver>/bin이 mise shims보다 우선이라, 남기면 backend shim을 가린다.
  #   node 버전이 동적이라 mise 기본 data dir의 installs 트리를 스캔한다(MISE_DATA_DIR 커스텀
  #   환경은 경로가 달라질 수 있으나 이 프로젝트 범위 밖).
  home.activation.cleanupManualNodeCodex = lib.hm.dag.entryAfter [ "installCodexCli" ] ''
    installs_dir="$HOME/.local/share/mise/installs/node"
    if [ -d "$installs_dir" ]; then
      for node_prefix in "$installs_dir"/*; do
        # 실제 버전 디렉토리만 — lts/24/latest 등 symlink 별칭은 같은 실체를 가리키므로 skip(중복 uninstall 방지).
        { [ -d "$node_prefix" ] && [ ! -L "$node_prefix" ]; } || continue
        [ -d "$node_prefix/lib/node_modules/@openai/codex" ] || continue
        npm_bin="$node_prefix/bin/npm"
        [ -x "$npm_bin" ] || continue
        # mise node의 npm은 `exec node "$npm_cli"` 형태 bash 래퍼다(node로 직접 실행하면 파싱 실패).
        # 래퍼가 PATH에서 node와 mise(reshim)를 찾으므로 둘을 PATH 앞에 두고 npm을 직접 실행한다.
        echo "Removing manually-installed npm global @openai/codex under $node_prefix"
        $DRY_RUN_CMD env PATH="$node_prefix/bin:${pkgs.mise}/bin:$PATH" "$npm_bin" uninstall -g @openai/codex \
          || echo "Warning: manual codex cleanup failed under $node_prefix (non-fatal)"
      done
    fi
  '';

  # ─── 프로젝트 심볼릭 링크 (activation script) ───
  # 이전 시도(5ef4e67)의 sync-codex-from-claude.sh 로직을 Nix activation으로 이식
  # nrs 실행 시 자동으로 .agents/skills/ 동기화

  home.activation.createCodexProjectSymlinks = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    PROJECT_DIR="${nixosConfigPath}"
    SOURCE_SKILLS="$PROJECT_DIR/.claude/skills"
    TARGET_SKILLS="$PROJECT_DIR/.agents/skills"

    # ── AGENTS.md → CLAUDE.md 심링크 ──
    if [ ! -L "$PROJECT_DIR/AGENTS.md" ] || [ "$(readlink "$PROJECT_DIR/AGENTS.md")" != "CLAUDE.md" ]; then
      $DRY_RUN_CMD ln -sfn "CLAUDE.md" "$PROJECT_DIR/AGENTS.md"
    fi

    # ── .agents/skills/ 디렉토리 생성 ──
    $DRY_RUN_CMD mkdir -p "$TARGET_SKILLS"

    # ── 스킬 투영 (디렉토리 심링크) ──
    # Codex CLI는 디렉토리 심링크를 따라감 (PR #8801)
    # 파일 심링크는 무시하므로 반드시 디렉토리 단위로 심링크
    # Claude Code 전용 스킬은 Codex 프로젝션에서 제외 (자기 참조 방지, #212)
    # NOTE: 아래 변수는 repo-local `.claude/skills/` → `.agents/skills/` 투영 축 전용이다.
    # shared global `~/.codex/skills/` exposure 정책(exposedCodexSkills / intentionallyNotExposed)과
    # 별개의 축이며, SoT는 위 let 블록이다 (#486).
    CODEX_EXCLUDE_SKILLS="using-codex-exec"
    for source_skill_dir in "$SOURCE_SKILLS"/*/; do
      [ -d "$source_skill_dir" ] || continue
      [ -f "$source_skill_dir/SKILL.md" ] || continue

      skill_name="$(basename "$source_skill_dir")"

      # Claude Code 전용 스킬 제외
      case " $CODEX_EXCLUDE_SKILLS " in
        *" $skill_name "*) continue ;;
      esac
      target_link="$TARGET_SKILLS/$skill_name"
      expected="../../.claude/skills/$skill_name"

      # 이미 올바른 심링크면 스킵
      if [ -L "$target_link" ] && [ "$(readlink "$target_link")" = "$expected" ]; then
        continue
      fi

      # 미래 방어: git이 추적하는 실디렉토리를 심링크로 덮어쓰지 않음
      # 향후 디렉토리→심링크 전환이 발생할 때, git pull 전에 nrs가 실행되어
      # HEAD와 파일시스템이 불일치하는 것을 방지 (PR#38 사후 분석에서 도출)
      if [ -d "$target_link" ] && [ ! -L "$target_link" ]; then
        if ${pkgs.git}/bin/git -C "$PROJECT_DIR" ls-files --error-unmatch "$target_link/SKILL.md" >/dev/null 2>&1; then
          echo "Skipping .agents/skills/$skill_name: git-tracked directory (run 'git pull' first)"
          continue
        fi
      fi

      # 미추적 디렉토리 또는 잘못된 심링크 제거 후 생성
      $DRY_RUN_CMD rm -rf "$target_link"
      $DRY_RUN_CMD ln -sfn "$expected" "$target_link"
    done

    # ── 고아 심링크 정리 ──
    if [ -d "$TARGET_SKILLS" ]; then
      for entry in "$TARGET_SKILLS"/*; do
        [ -L "$entry" ] || [ -d "$entry" ] || continue
        skill_name="$(basename "$entry")"
        if [ ! -d "$SOURCE_SKILLS/$skill_name" ]; then
          echo "Removing orphan projected skill: .agents/skills/$skill_name"
          $DRY_RUN_CMD rm -rf "$entry"
        fi
      done
    fi
  '';
}

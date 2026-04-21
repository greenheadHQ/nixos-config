# Codex CLI 설정 (공통)
# 바이너리: macOS=brew cask, NixOS=GitHub releases 직접 다운로드
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
    "create-issue"
    "create-pr"
    "documenting-intent"
    "parallel-audit"
    "plan-with-questions"
    "playwright-cli"
    "prd"
    "review-implementation"
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

    # write-handoff helper: Codex 세션에서도 LLM이 직접 호출 가능하도록 프로비저닝 (#486 F8)
    # Claude와 동일 source를 공유한다.
    ".codex/scripts/write-handoff-repo-slug.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/scripts/write-handoff-repo-slug.sh";
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

  # ─── NixOS: Codex CLI 바이너리 설치 (GitHub releases) ───
  # macOS는 brew cask로 관리 (modules/darwin/programs/homebrew.nix)
  home.activation.installCodexCli = lib.mkIf pkgs.stdenv.isLinux (
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if ! command -v codex >/dev/null 2>&1; then
        echo "Installing Codex CLI from GitHub releases..."
        TAG="$(${pkgs.curl}/bin/curl -sI --connect-timeout 5 --max-time 10 \
          "https://github.com/openai/codex/releases/latest" \
          | ${pkgs.gnugrep}/bin/grep -i '^location:' | ${pkgs.gnused}/bin/sed 's|.*/tag/||; s/\r//')"
        if [ -n "$TAG" ]; then
          BINARY="codex-x86_64-unknown-linux-musl"
          URL="https://github.com/openai/codex/releases/download/''${TAG}/''${BINARY}.tar.gz"
          mkdir -p "$HOME/.local/bin"
          ${pkgs.curl}/bin/curl -fsSL "$URL" | ${pkgs.gnutar}/bin/tar --use-compress-program=${pkgs.gzip}/bin/gzip -x -C /tmp
          mv "/tmp/''${BINARY}" "$HOME/.local/bin/codex"
          chmod +x "$HOME/.local/bin/codex"
          echo "Codex CLI ''${TAG#rust-v} installed to ~/.local/bin/codex"
        else
          echo "Warning: Could not fetch Codex CLI release tag (skipping install)"
        fi
      else
        echo "Codex CLI already installed at $(command -v codex)"
      fi
    ''
  );

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

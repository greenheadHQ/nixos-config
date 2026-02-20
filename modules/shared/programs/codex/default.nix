# Codex CLI 설정 (공통)
# 바이너리: macOS=brew cask, NixOS=GitHub releases 직접 다운로드
# Claude Code 스킬을 Codex에서도 사용할 수 있도록 심볼릭 링크 관리
# 이전 시도(5ef4e67)에서 trust 미설정으로 실패 → config.toml에 trust 필수
{
  config,
  pkgs,
  lib,
  nixosConfigPath,
  ...
}:

let
  codexFilesPath = "${nixosConfigPath}/modules/shared/programs/codex/files";
  # Claude 파일 경로 (공유 소스)
  claudeFilesPath = "${nixosConfigPath}/modules/shared/programs/claude/files";
in
{
  # ─── 글로벌 설정 (~/.codex/) ───

  home.file = {
    # Codex config.toml - 양방향 수정 가능 (codex mcp add 등 반영)
    # ⚠️ trust 설정 포함 — 이것이 .agents/skills/ 발견의 전제조건
    ".codex/config.toml".source = config.lib.file.mkOutOfStoreSymlink "${codexFilesPath}/config.toml";

    # 글로벌 AGENTS.md - Claude의 CLAUDE.md와 동일 소스 공유
    ".codex/AGENTS.md".source = config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/CLAUDE.md";

    # 글로벌 스킬 (Claude와 동일 소스 공유)
    ".codex/skills/maintaining-skills".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/maintaining-skills";
    ".codex/skills/managing-github-issues".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/managing-github-issues";
    ".codex/skills/syncing-codex-harness".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/syncing-codex-harness";
  };

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
    for source_skill_dir in "$SOURCE_SKILLS"/*/; do
      [ -d "$source_skill_dir" ] || continue
      [ -f "$source_skill_dir/SKILL.md" ] || continue

      skill_name="$(basename "$source_skill_dir")"
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

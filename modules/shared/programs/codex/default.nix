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

    # 글로벌 스킬: agent-browser (Claude와 동일 소스 공유)
    ".codex/skills/agent-browser".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/agent-browser";
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
          ${pkgs.curl}/bin/curl -fsSL "$URL" | tar xz -C /tmp
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

  home.activation.createCodexProjectSymlinks =
    lib.hm.dag.entryAfter
      [
        "writeBoundary"
        "createImmichPhotoSkill" # viewing-immich-photo 스킬이 먼저 생성되어야 함
      ]
      ''
        PROJECT_DIR="${nixosConfigPath}"
        SOURCE_SKILLS="$PROJECT_DIR/.claude/skills"
        TARGET_SKILLS="$PROJECT_DIR/.agents/skills"

        # ── AGENTS.md → CLAUDE.md 심링크 ──
        if [ ! -L "$PROJECT_DIR/AGENTS.md" ] || [ "$(readlink "$PROJECT_DIR/AGENTS.md")" != "CLAUDE.md" ]; then
          $DRY_RUN_CMD ln -sfn "CLAUDE.md" "$PROJECT_DIR/AGENTS.md"
        fi

        # ── .agents/skills/ 디렉토리 생성 ──
        $DRY_RUN_CMD mkdir -p "$TARGET_SKILLS"

        # ── 스킬 투영 (심링크 + openai.yaml 생성) ──
        SYNC_SH="${nixosConfigPath}/modules/shared/programs/claude/files/skills/syncing-codex-harness/references/sync.sh"
        for source_skill_dir in "$SOURCE_SKILLS"/*/; do
          [ -d "$source_skill_dir" ] || continue
          [ -f "$source_skill_dir/SKILL.md" ] || continue

          skill_name="$(basename "$source_skill_dir")"
          target_skill_dir="$TARGET_SKILLS/$skill_name"

          $DRY_RUN_CMD mkdir -p "$target_skill_dir"

          # SKILL.md는 "실파일 복사"로 투영
          # 일부 Codex 환경에서 symlinked SKILL.md가 project-scope 스캔에서 누락될 수 있음
          skill_target="$target_skill_dir/SKILL.md"
          skill_source="$source_skill_dir/SKILL.md"
          if [ -L "$skill_target" ] || [ ! -f "$skill_target" ] || ! cmp -s "$skill_source" "$skill_target"; then
            $DRY_RUN_CMD rm -f "$skill_target"
            $DRY_RUN_CMD cp "$skill_source" "$skill_target"
          fi

          # references, scripts, assets 심링크 (존재 시)
          for child in references scripts assets; do
            if [ -e "$source_skill_dir/$child" ]; then
              expected_child="../../../.claude/skills/$skill_name/$child"
              if [ ! -L "$target_skill_dir/$child" ] || [ "$(readlink "$target_skill_dir/$child")" != "$expected_child" ]; then
                $DRY_RUN_CMD ln -sf "$expected_child" "$target_skill_dir/$child"
              fi
            fi
          done

          # agents/openai.yaml 생성 (sync.sh 단일 소스)
          $DRY_RUN_CMD mkdir -p "$target_skill_dir/agents"
          yaml_file="$target_skill_dir/agents/openai.yaml"
          PATH="${pkgs.gawk}/bin:$PATH" bash "$SYNC_SH" generate-openai-yaml \
            "$source_skill_dir/SKILL.md" "$yaml_file" "$skill_name"
        done

        # ── 깨진/고아 심링크 정리 ──
        if [ -d "$TARGET_SKILLS" ]; then
          for target_dir in "$TARGET_SKILLS"/*/; do
            [ -d "$target_dir" ] || continue
            skill_name="$(basename "$target_dir")"
            if [ ! -d "$SOURCE_SKILLS/$skill_name" ]; then
              echo "Removing orphan projected skill: .agents/skills/$skill_name"
              $DRY_RUN_CMD rm -rf "$target_dir"
            fi
          done
        fi
      '';
}

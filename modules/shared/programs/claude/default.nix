# Claude Code 설정 (공통)
# Homebrew로 앱 설치, Nix로 설정 관리
{
  config,
  pkgs,
  lib,
  nixosConfigPath,
  ...
}:

let
  claudeDir = ./files;
  # mkOutOfStoreSymlink용 절대 경로 (양방향 수정 가능)
  claudeFilesPath = "${nixosConfigPath}/modules/shared/programs/claude/files";
in
{
  # Worktree 심링크 정리: .wt/ 아래 Claude 관리 경로(files/*)를 가리키는 stale 심링크 제거
  # checkLinkTargets 전에 실행하여 cmp 디렉토리 비교 에러 방지
  # 배경: PR #28에서 nixosConfigPath가 worktree 경로로 동적 변경 → 심링크가 .wt/를 가리킴
  # 이 activation은 해당 회귀를 한 번 정리한 뒤에도 안전한 no-op으로 남음
  # 주의: 아래 glob 목록은 home.file의 Claude 엔트리(skills/hooks/상위 *.json/*.md)와 동기화 필요.
  # 새 하위 디렉토리 엔트리를 추가하면 여기에도 반영해야 stale 링크 누락을 막을 수 있음.
  home.activation.cleanStaleWorktreeSymlinks = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    for link in "$HOME/.claude/skills/"* "$HOME/.claude/hooks/"* "$HOME/.claude/"*.json "$HOME/.claude/"*.md; do
      if [ -L "$link" ]; then
        target=$(readlink "$link")
        case "$target" in
          "${nixosConfigPath}/.wt/"*/modules/shared/programs/claude/files/*)
            $DRY_RUN_CMD rm "$link"
            $VERBOSE_ECHO "Removed stale worktree symlink: $link -> $target"
            ;;
        esac
      fi
    done
  '';

  # Binary Claude Code 설치 (Node.js 버전 의존성 없음)
  home.activation.installClaudeCode = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -f "$HOME/.local/bin/claude" ]; then
      echo "Installing Claude Code binary..."
      ${pkgs.curl}/bin/curl -fsSL https://claude.ai/install.sh | ${pkgs.bash}/bin/bash
    else
      echo "Claude Code already installed at $HOME/.local/bin/claude"
    fi
  '';

  # ~/.claude/ 디렉토리 관리 (선택적 파일만)
  home.file = {
    # 메인 설정 파일 - 양방향 수정 가능 (nixos-config 직접 참조)
    # Claude Code에서 플러그인 설치/설정 변경 시 nixos-config에 바로 반영됨
    ".claude/settings.json".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/settings.json";

    # MCP 설정 - 양방향 수정 가능
    ".claude/mcp.json".source = config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/mcp.json";

    # User-scope 지침 - 양방향 수정 가능
    ".claude/CLAUDE.md".source = config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/CLAUDE.md";

    # Hooks - mkOutOfStoreSymlink로 nrs 없이 즉시 반영 (소스 파일에 chmod +x 필수)
    ".claude/hooks/stop-notification.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/hooks/stop-notification.sh";
    ".claude/hooks/ask-notification.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/hooks/ask-notification.sh";
    ".claude/hooks/plan-notification.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/hooks/plan-notification.sh";

    # syncing-codex-harness 스킬 (user-scope)
    ".claude/skills/syncing-codex-harness".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/syncing-codex-harness";

    # managing-github-issues 스킬 (user-scope)
    ".claude/skills/managing-github-issues".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/managing-github-issues";

    # maintaining-skills 스킬 (user-scope)
    ".claude/skills/maintaining-skills".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/maintaining-skills";
  };
}

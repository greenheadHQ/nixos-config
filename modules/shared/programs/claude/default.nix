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
  # macOS에서는 chrome-devtools-mcp를 user-scope MCP로 사용, NixOS는 빈 설정 유지
  claudeMcpFile = if pkgs.stdenv.isDarwin then "mcp.darwin.json" else "mcp.json";
  jqBin = "${pkgs.jq}/bin/jq";
in
{
  # Binary Claude Code 설치 (Node.js 버전 의존성 없음)
  # CIR: curl install.sh 방식 유지 — Nix 패키지(VSCode 확장 의존성)와 별개 채널이지만,
  #   auto-updater가 터미널 CLI를 항상 최신으로 유지하므로 이 방식이 최적.
  #   VSCode 확장 쪽 Nix 패키지는 DISABLE_AUTOUPDATER=1로 격리됨 (vscode/default.nix CIR 참조)
  home.activation.installClaudeCode = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -f "$HOME/.local/bin/claude" ]; then
      echo "Installing Claude Code binary..."
      ${pkgs.curl}/bin/curl -fsSL https://claude.ai/install.sh | ${pkgs.bash}/bin/bash
    else
      echo "Claude Code already installed at $HOME/.local/bin/claude"
    fi
  '';

  # Hooks trust 자동 주입: ~/.claude.json의 기존 프로젝트에 trust 플래그 패치
  # 배경: upstream #5572, #10409 — hasTrustDialogHooksAccepted를 공식 인터페이스로 설정 불가
  # v2.1.51 보안 수정으로 interactive hooks 실행에 이 플래그가 필수가 되었으나,
  # --dangerously-skip-permissions가 trust dialog를 건너뛰면서 플래그도 설정하지 않는 버그 존재
  home.activation.ensureClaudeHooksTrust = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    cfg="$HOME/.claude.json"
    lockdir="''${cfg}.lock"

    # 파일 없거나 비어있으면 skip (서브쉘이 아닌 조건문으로 처리)
    if [ -s "$cfg" ]; then

      # mkdir 기반 lock (macOS/Linux 모두 POSIX 원자적)
      acquire_lock() {
        local waited=0
        while ! mkdir -- "$lockdir" 2>/dev/null; do
          if [ -f "$lockdir/pid" ]; then
            local other_pid
            other_pid=$(cat "$lockdir/pid" 2>/dev/null || echo "")
            if [ -n "$other_pid" ] && ! kill -0 "$other_pid" 2>/dev/null; then
              rm -rf -- "$lockdir"
              continue
            fi
          elif [ -d "$lockdir" ]; then
            # PID 파일 없는 stale lock: 즉시 제거
            rm -rf -- "$lockdir"
            continue
          fi
          waited=$((waited + 1))
          if [ "$waited" -ge 100 ]; then
            echo "ensureClaudeHooksTrust: lock timeout, skipping"
            return 1
          fi
          sleep 0.1
        done
        echo $$ > "$lockdir/pid"
        return 0
      }

      if acquire_lock; then
        tmp=$(mktemp "''${cfg}.tmp.XXXXXX")
        trap 'rm -f "$tmp"; rm -rf -- "$lockdir"' EXIT INT TERM

        if $DRY_RUN_CMD ${jqBin} '
          if (.projects | type) != "object" then .
          else
            .projects |= with_entries(
              .value |= (
                if (type == "object")
                then . + { hasTrustDialogAccepted: true, hasTrustDialogHooksAccepted: true }
                else .
                end
              )
            )
          end
        ' "$cfg" > "$tmp" && [ -s "$tmp" ] && ${jqBin} empty "$tmp" >/dev/null 2>&1; then
          $DRY_RUN_CMD mv -- "$tmp" "$cfg"
        else
          echo "ensureClaudeHooksTrust: jq patch failed, skipping"
          rm -f "$tmp"
        fi

        rm -rf -- "$lockdir"
        trap - EXIT INT TERM
      fi

    fi
  '';

  # ~/.claude/ 디렉토리 관리 (선택적 파일만)
  home.file = {
    # 메인 설정 파일 - 양방향 수정 가능 (nixos-config 직접 참조)
    # Claude Code에서 플러그인 설치/설정 변경 시 nixos-config에 바로 반영됨
    ".claude/settings.json".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/settings.json";

    # MCP 설정 - 양방향 수정 가능
    # chrome-devtools MCP(CDP)만 사용 — claude-in-chrome(--chrome)은 제거됨 (CIR 참조: shell/default.nix)
    ".claude/mcp.json".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/${claudeMcpFile}";

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

    # using-codex-exec 스킬 (user-scope)
    ".claude/skills/using-codex-exec".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/using-codex-exec";

    # documenting-intent 스킬 (user-scope)
    ".claude/skills/documenting-intent".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/documenting-intent";
  };
}

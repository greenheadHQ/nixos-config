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
  # CIR: curl install.sh 방식 유지 — auto-updater가 터미널 CLI를 항상 최신으로 유지하므로 이 방식이 최적.
  #   Zed는 ACP(Agent Client Protocol) 기반 네이티브 Claude Code 통합 사용 (zed/default.nix CIR 참조)
  home.activation.installClaudeCode = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -f "$HOME/.local/bin/claude" ]; then
      echo "Installing Claude Code binary..."
      ${pkgs.curl}/bin/curl -fsSL https://claude.ai/install.sh | ${pkgs.bash}/bin/bash
    else
      echo "Claude Code already installed at $HOME/.local/bin/claude"
    fi
  '';

  # ~/.claude.json 패치: hooks trust + notification defaults
  #
  # (1) Hooks trust 자동 주입
  #   배경: upstream #5572, #10409 — hasTrustDialogHooksAccepted를 공식 인터페이스로 설정 불가
  #   v2.1.51 보안 수정으로 interactive hooks 실행에 이 플래그가 필수가 되었으나,
  #   --dangerously-skip-permissions가 trust dialog를 건너뛰면서 플래그도 설정하지 않는 버그 존재
  #
  # (2) Notification defaults 주입 (키가 없을 때만)
  #   배경: Claude Code의 알림 토글은 ~/.claude.json에 per-machine으로 저장되며,
  #   settings.json으로 선언 불가. 새 머신 셋업 시 알림이 기본 비활성이므로 nrs로 보장.
  #   - preferredNotifChannel: "auto" — "ghostty" 채널 버그 회피 (upstream #19979)
  #     기존 "ghostty" 값은 자동으로 "auto"로 교체, 그 외 사용자 값은 보존.
  #   - taskCompleteNotifEnabled / inputNeededNotifEnabled / agentPushNotifEnabled: true
  #   사용자가 UI(Shift+Tab)에서 명시적으로 변경한 값은 덮어쓰지 않음 (has() 가드).
  #
  # CIR: ~/.claude.json 직접 패치의 fragility 분석
  #   - Claude Code는 저장 시 기본값(ZI)과 동일한 키를 삭제한다.
  #     preferredNotifChannel="auto"는 ZI 기본값과 동일하므로 Claude Code 저장 시 삭제됨.
  #     → 매 nrs마다 has()가 false → 재삽입 사이클 발생. 기능적으로 무해 (기본값="auto").
  #   - 3개 토글(taskComplete/inputNeeded/agentPush)은 ZI에 없으므로 삭제되지 않음.
  #   - 락 메커니즘: mkdir 기반 lock과 Claude Code의 내부 lock이 동일 경로 사용.
  #     activation이 ms 단위로 완료되므로 실질적 race condition 위험은 극소.
  #   - 스키마 변경 시: jq empty 검증으로 안전 실패 (원본 보존, 패치 skip).
  home.activation.patchClaudeJson = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
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
            echo "patchClaudeJson: lock timeout, skipping"
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
          # (1) Hooks trust: 모든 프로젝트에 trust 플래그 주입
          (if (.projects | type) != "object" then .
          else
            .projects |= with_entries(
              .value |= (
                if (type == "object")
                then . + { hasTrustDialogAccepted: true, hasTrustDialogHooksAccepted: true }
                else .
                end
              )
            )
          end)
          # (2) Notification defaults: 키가 없을 때만 기본값 삽입
          | if .preferredNotifChannel? == "ghostty" then .preferredNotifChannel = "auto"
            elif has("preferredNotifChannel") then .
            else .preferredNotifChannel = "auto"
            end
          | if has("taskCompleteNotifEnabled") then . else .taskCompleteNotifEnabled = true end
          | if has("inputNeededNotifEnabled") then . else .inputNeededNotifEnabled = true end
          | if has("agentPushNotifEnabled") then . else .agentPushNotifEnabled = true end
        ' "$cfg" > "$tmp" && [ -s "$tmp" ] && ${jqBin} empty "$tmp" >/dev/null 2>&1; then
          $DRY_RUN_CMD mv -- "$tmp" "$cfg"
        else
          echo "patchClaudeJson: jq patch failed, skipping"
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
    # CIR: mkOutOfStoreSymlink 사용 — Nix store symlink는 Claude Code 런타임 쓰기 불가.
    #   주의: enabledPlugins를 settings.json에서 직접 편집하면 유령 플러그인 발생
    #   (UI에 표시되나 토글/삭제 불가). 해결: 유령 항목 재추가 후 CLI로 삭제.
    #   플러그인 관리는 반드시 `claude plugin install/uninstall` CLI로 수행할 것.
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
    ".claude/hooks/nrs-session-cleanup.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/hooks/nrs-session-cleanup.sh";
    ".claude/hooks/worktree-path-guard.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/hooks/worktree-path-guard.sh";
    ".claude/hooks/session-init-icons.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/hooks/session-init-icons.sh";
    ".claude/hooks/log-skill.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/hooks/log-skill.sh";
    ".claude/hooks/fragile-hardcoding-guard.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/hooks/fragile-hardcoding-guard.sh";
    ".claude/hooks/system-bash-guard.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/hooks/system-bash-guard.sh";
    # Cache TTL tracking hooks
    ".claude/hooks/record-last-stop.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/hooks/record-last-stop.sh";
    ".claude/hooks/record-prompt-submit.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/hooks/record-prompt-submit.sh";

    # hs.notify contentImage용 아이콘 (Claude.app에서 추출한 128x128 PNG, macOS 전용)
    ".claude/assets/notification-icon.png" = lib.mkIf pkgs.stdenv.isDarwin {
      source = config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/assets/notification-icon.png";
    };

    # syncing-codex-harness 스킬 (user-scope)
    ".claude/skills/syncing-codex-harness".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/syncing-codex-harness";

    # create-issue 스킬 (user-scope)
    ".claude/skills/create-issue".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/create-issue";

    # using-codex-exec 스킬 (user-scope)
    ".claude/skills/using-codex-exec".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/using-codex-exec";

    # documenting-intent 스킬 (user-scope)
    ".claude/skills/documenting-intent".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/documenting-intent";

    # using-claude-p 스킬 (user-scope)
    ".claude/skills/using-claude-p".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/using-claude-p";

    # set-icons 스킬 (user-scope)
    ".claude/skills/set-icons".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/set-icons";

    # plan-with-questions 스킬 (user-scope)
    ".claude/skills/plan-with-questions".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/plan-with-questions";

    # run-da 스킬 (user-scope)
    ".claude/skills/run-da".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/run-da";

    # review-pr-feedback 스킬 (user-scope)
    ".claude/skills/review-pr-feedback".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/review-pr-feedback";

    # create-pr 스킬 (user-scope)
    ".claude/skills/create-pr".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/create-pr";

    # write-handoff 스킬 (user-scope)
    ".claude/skills/write-handoff".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/write-handoff";

    # parallel-audit 스킬 (user-scope)
    ".claude/skills/parallel-audit".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/parallel-audit";

    # playwright-cli 스킬 (user-scope)
    ".claude/skills/playwright-cli".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/playwright-cli";

    # codex-fan-out 스킬 (user-scope)
    ".claude/skills/codex-fan-out".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/skills/codex-fan-out";

    # Statusline script - 양방향 수정 가능
    ".claude/scripts/statusline.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/scripts/statusline.sh";

    # Eval 인프라 스크립트 — run-eval.sh, improve-description.sh, run-loop.sh (#283, #316, #318)
    ".claude/scripts/run-eval.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/scripts/run-eval.sh";
    ".claude/scripts/improve-description.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/scripts/improve-description.sh";
    ".claude/scripts/run-loop.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/scripts/run-loop.sh";
    ".claude/scripts/generate-report.py".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/scripts/generate-report.py";

    # write-handoff repo slug 확보 helper. LLM이 SKILL.md Step 1-B 절차에 따라 직접 호출한다 (#486).
    # Codex 세션은 ~/.codex/scripts/ 경로에서 동일 source를 공유한다 (codex/default.nix).
    ".claude/scripts/write-handoff-repo-slug.sh".source =
      config.lib.file.mkOutOfStoreSymlink "${claudeFilesPath}/scripts/write-handoff-repo-slug.sh";

  };
}

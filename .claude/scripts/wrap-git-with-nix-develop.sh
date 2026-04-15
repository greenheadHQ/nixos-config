#!/usr/bin/env bash
# PreToolUse hook: git 명령어를 nix develop 환경에서 실행
# 이 프로젝트는 lefthook (gitleaks, shellcheck 등)을 사용하므로
# nix develop 환경에서 git 명령어를 실행해야 함

set -euo pipefail

input=$(cat)

# 디버그 로깅 (문제 발생 시 주석 해제)
# exec 2>>/tmp/claude-hook-debug.log
# echo "=== $(date) ===" >&2
# echo "Input: $input" >&2

tool_name=$(echo "$input" | jq -r '.tool_name')

# Bash 도구가 아니면 통과
if [[ "$tool_name" != "Bash" ]]; then
  exit 0
fi

command=$(echo "$input" | jq -r '.tool_input.command // empty')

# command가 없으면 통과
if [[ -z "$command" ]]; then
  exit 0
fi

# git add/commit/push/stash로 시작하고, 아직 래핑되지 않은 경우
if [[ "$command" =~ ^git[[:space:]]+(add|commit|push|stash) ]] && \
   [[ ! "$command" =~ ^nix[[:space:]]+develop ]] && \
   [[ ! "$command" =~ ^echo[[:space:]].*base64 ]]; then

  # === Change Intent Record ===
  # v1: nix develop -c $command 직접 래핑 → chain command(&&)에서 첫 번째 명령만
  #     nix 환경에서 실행되고 나머지는 시스템 셸로 탈출하는 문제 발생.
  #     커밋 메시지의 따옴표/한글/백틱/$변수도 JSON 이스케이프 실패 유발.
  # v2 (이번): base64 인코딩으로 전체 command를 단일 bash stdin으로 전달.
  #     trade-off: 디버그 시 base64 디코딩 필요하나,
  #               chain command + 특수문자 + JSON 출력 안정성을 한번에 해결.
  encoded=$(printf '%s' "$command" | base64 | tr -d '\n')
  wrapped_command="echo $encoded | base64 -d | nix develop -c bash"

  jq -n \
    --arg cmd "$wrapped_command" \
    --arg msg "lefthook 사용을 위해 nix develop 환경에서 실행합니다." \
    '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        updatedInput: { command: $cmd }
      },
      systemMessage: $msg
    }'
  exit 0
fi

# 그 외 명령어는 그대로 통과
exit 0

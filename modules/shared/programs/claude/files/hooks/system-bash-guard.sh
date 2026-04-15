#!/usr/bin/env bash
# PreToolUse Hook: 시스템 bash 3.2 강제 호출 차단
# [WHY] macOS /bin/bash는 Apple의 GPLv3 회피로 3.2.x에 고정되어
# `declare -A` 등 bash 4+ 기능이 `invalid option`으로 실패. Nix bash 5.x가
# PATH 최상단에 있으므로 `/bin/bash` 절대경로 호출과 `#!/bin/bash` shebang을
# 차단해 PATH-resolved bash로 유도한다.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

_deny() {
  # [WHY] 공식 최신 PreToolUse 스펙: hookSpecificOutput.permissionDecision
  # (top-level {decision:"block"}은 legacy). permissionDecisionReason은 "deny"에서
  # Claude에 전달되어 다음 시도를 교정한다.
  jq -n --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}

case "$TOOL_NAME" in
  Bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    # [WHY] 명령 세그먼트 시작(라인 시작, `;`, `&&`, `||`, `|`, `(`) 뒤에서
    # `/bin/bash`가 실행되는 케이스만 매치. `grep /bin/bash README`나
    # `test -x /bin/bash` 같은 문자열 언급은 통과.
    # Trade-off: quoted path(`"/bin/bash"`), 변수 치환, `sudo /bin/bash`는 MISS —
    # 주 방어선은 shebang 마이그레이션이며 여기서는 heredoc 등 주 호출 패턴 차단이 목적.
    if printf '%s' "$CMD" | grep -Eq '(^|[;&|(])[[:space:]]*/bin/bash([[:space:]<>]|$)'; then
      _deny "[system-bash-guard] Bash command에서 /bin/bash 절대경로 호출이 감지되었습니다. macOS /bin/bash는 3.2 (GPLv3 legacy)로 'declare -A' 등 bash 4+ 기능이 실패합니다. 대안: \`bash <<'EOF'\` (PATH 기반 해석; Claude Code 세션 PATH에 있는 Nix bash 5.x가 선택됨)."
    fi
    ;;
  Write)
    CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null)
    if printf '%s' "$CONTENT" | grep -Eq '^#!/bin/bash([[:space:]]|$)'; then
      _deny "[system-bash-guard] Write content의 shebang이 #!/bin/bash입니다. macOS /bin/bash는 3.2 (GPLv3 legacy)로 bash 4+ 기능이 실패합니다. 대안: #!/usr/bin/env bash (호출 환경 PATH를 통해 bash가 해석됨; launchd/systemd처럼 PATH가 통제된 컨텍스트에서는 해당 agent의 PATH에 Nix bash 경로가 포함되는지 별도 확인 필요)."
    fi
    ;;
  Edit)
    FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    OLD_STR=$(printf '%s' "$INPUT" | jq -r '.tool_input.old_string // empty' 2>/dev/null)
    NEW_STR=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null)
    # [WHY] new_string만 검사하면 partial 치환(예: old="/usr/bin/env bash",
    # new="/bin/bash")이 post-edit shebang을 #!/bin/bash로 만들어도 우회된다.
    # old_string을 new_string으로 치환한 전체 결과에서 검사하여 bypass를 차단.
    # fragile-hardcoding-guard.sh:52-74의 awk 재구성 패턴을 따른다.
    POST_EDIT=""
    if [ -n "$OLD_STR" ] && [ -n "$FILE_PATH" ] && [ -f "$FILE_PATH" ]; then
      POST_EDIT=$(OLD_STR="$OLD_STR" NEW_STR="$NEW_STR" awk '
        BEGIN { RS="\0"; ORS="" }
        {
          old = ENVIRON["OLD_STR"]; new = ENVIRON["NEW_STR"]
          idx = index($0, old)
          if (idx > 0) { print substr($0, 1, idx-1) new substr($0, idx+length(old)); exit 0 }
          else { exit 1 }
        }' "$FILE_PATH" 2>/dev/null)
      [ -z "$POST_EDIT" ] && POST_EDIT="$NEW_STR"
    else
      POST_EDIT="$NEW_STR"
    fi
    if printf '%s' "$POST_EDIT" | grep -Eq '^#!/bin/bash([[:space:]]|$)'; then
      _deny "[system-bash-guard] Edit 결과 파일의 shebang이 #!/bin/bash입니다 (post-edit 재구성 검사). macOS /bin/bash는 3.2 (GPLv3 legacy)로 bash 4+ 기능이 실패합니다. 대안: #!/usr/bin/env bash (호출 환경 PATH를 통해 bash가 해석됨; launchd/systemd처럼 PATH가 통제된 컨텍스트에서는 해당 agent의 PATH에 Nix bash 경로가 포함되는지 별도 확인 필요)."
    fi
    ;;
esac

exit 0

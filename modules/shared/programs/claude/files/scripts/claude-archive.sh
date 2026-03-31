#!/usr/bin/env bash
# claude-archive — Claude Code 세션 데이터를 ~/.claude/archive/에 아카이빙
set -euo pipefail
umask 077

ARCHIVE_DIR="$HOME/.claude/archive"
CLAUDE_DIR="$HOME/.claude"

# --- 상수 ---
HEADER_SCAN_LINES=5          # JSONL 헤더 메타데이터 추출 시 스캔할 줄 수
TOOL_INPUT_PREVIEW_MAX=500   # tool_use input 미리보기 최대 문자수
TOOL_RESULT_PREVIEW_MAX=300  # tool_result 출력 미리보기 최대 문자수

# --- 출력 헬퍼 ---
err()  { printf '\033[31mError: %s\033[0m\n' "$1" >&2; }
info() { printf '\033[32m%s\033[0m\n' "$1"; }
warn() { printf '\033[33m%s\033[0m\n' "$1"; }

usage() {
  cat <<'EOF'
Usage: claude-archive [OPTIONS]

Archive Claude Code session data to ~/.claude/archive/

Options:
  (none)          Archive current session
  --all           Archive all sessions for current CWD
  --project       Archive all sessions for main repo + worktrees
  --list          List archived sessions
  --restore <id>  Restore session files to original locations
  -h, --help      Show this help
EOF
}

# --- 유틸리티 ---

# CWD 인코딩 (statusline.sh:140, collect-pain-points.sh:82 와 동일 패턴)
encode_path() {
  printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'
}

# git canonical root: git-common-dir → dirname
get_canonical_root() {
  local git_common_dir
  git_common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  dirname "$git_common_dir"
}

# CWD에서 프로젝트 이름 추출 (worktree 삭제 후에도 동작)
get_project_name_from_cwd() {
  local cwd="$1"

  # 1. worktree 패턴: .claude/worktrees/ 포함
  case "$cwd" in
    */.claude/worktrees/*)
      basename "${cwd%%/.claude/worktrees/*}"
      return ;;
  esac

  # 2. cd + git으로 canonical root
  local root
  root=$(cd "$cwd" 2>/dev/null && get_canonical_root 2>/dev/null) || {
    # 3. fallback: basename
    basename "$cwd"
    return
  }
  basename "$root"
}

# 현재 세션 ID 찾기 (sessions/ PID 파일 스캔)
find_current_session() {
  local cwd="$1"
  local sessions_dir="$CLAUDE_DIR/sessions"

  [ -d "$sessions_dir" ] || return 1

  for pid_file in "$sessions_dir"/*.json; do
    [ -f "$pid_file" ] || continue
    local file_cwd
    file_cwd=$(jq -r '.cwd // empty' "$pid_file" 2>/dev/null) || continue
    if [ "$file_cwd" = "$cwd" ]; then
      local found
      found=$(jq -r '.sessionId // empty' "$pid_file" 2>/dev/null)
      [ -n "$found" ] && echo "$found" && return 0
    fi
  done

  return 1
}

# CWD에 해당하는 모든 세션 JSONL 목록
find_sessions_for_cwd() {
  local cwd="$1"
  local encoded
  encoded=$(encode_path "$cwd")
  local project_dir="$CLAUDE_DIR/projects/$encoded"

  [ -d "$project_dir" ] || return 0

  find "$project_dir" -maxdepth 1 -name '*.jsonl' ! -name 'agent-*' | sort
}

# 프로젝트의 모든 관련 세션 (main + worktrees)
find_sessions_for_project() {
  local canonical_root="$1"

  # main repo sessions
  find_sessions_for_cwd "$canonical_root"

  # worktree sessions
  git -C "$canonical_root" worktree list --porcelain 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        local wt_path="${line#worktree }"
        if [ "$wt_path" != "$canonical_root" ]; then
          find_sessions_for_cwd "$wt_path"
        fi
        ;;
    esac
  done
}

# 세션이 이미 아카이브되었는지 확인
is_already_archived() {
  local session_id="$1"
  [ -n "$(find "$ARCHIVE_DIR" -path "*/$session_id/meta.json" -print -quit 2>/dev/null)" ]
}

# allowlist 경로 검증 (--restore용)
validate_restore_path() {
  local path="$1"
  local real_path
  real_path=$(realpath -m "$path" 2>/dev/null || echo "$path")

  # symlink 거부
  if [ -L "$path" ]; then
    err "Refusing to restore to symlink: $path"
    return 1
  fi

  # allowlist: ~/.claude/projects/, ~/.claude/status-icons/, ~/.claude/memos/ 하위만
  case "$real_path" in
    "$HOME/.claude/projects/"*|"$HOME/.claude/status-icons/"*|"$HOME/.claude/memos/"*)
      return 0 ;;
    *)
      err "Path outside allowlist: $real_path"
      return 1 ;;
  esac
}

# --- JSONL → Markdown 변환 ---

convert_to_markdown() {
  local jsonl_file="$1"
  local session_id="$2"
  local output_file="$3"

  # 헤더 정보 추출 (JSONL 선두 N줄에서 메타데이터 필드를 추출)
  local git_branch cwd timestamp
  git_branch=$(head -"$HEADER_SCAN_LINES" "$jsonl_file" | jq -r 'select(.gitBranch) | .gitBranch' 2>/dev/null | head -1 || true)
  cwd=$(head -"$HEADER_SCAN_LINES" "$jsonl_file" | jq -r 'select(.cwd) | .cwd' 2>/dev/null | head -1 || true)
  timestamp=$(head -"$HEADER_SCAN_LINES" "$jsonl_file" | jq -r 'select(.timestamp) | .timestamp' 2>/dev/null | head -1 || true)
  local date_str="${timestamp%%T*}"

  {
    echo "# Session: $session_id"
    [ -n "${git_branch:-}" ] && echo "- **Branch**: $git_branch"
    [ -n "${date_str:-}" ] && echo "- **Date**: $date_str"
    [ -n "${cwd:-}" ] && echo "- **CWD**: $cwd"
    echo ""
    echo "---"
    echo ""

    # 메시지 변환 규칙:
    # - thinking 블록 제외 (내부 추론은 아카이브 불필요)
    # - tool_use input은 TOOL_INPUT_PREVIEW_MAX자로 잘라내기 (전체 입력은 JSONL 원본 참조)
    # - tool_result 출력은 TOOL_RESULT_PREVIEW_MAX자로 잘라내기 (동일)
    # - user/assistant 메시지만 포함 (system, file-history-snapshot 등 제외)
    jq -r --argjson tip "$TOOL_INPUT_PREVIEW_MAX" --argjson trp "$TOOL_RESULT_PREVIEW_MAX" '
      select(.type == "user" or .type == "assistant") |
      select(.message != null) |
      {
        role: .message.role,
        ts: (.timestamp // "" | split("T") | if length > 1 then .[1] | split(".")[0] else "?" end),
        content: (
          if (.message.content | type) == "string" then
            .message.content
          elif (.message.content | type) == "array" then
            [.message.content[] |
              select(.type != "thinking") |
              if .type == "text" then .text
              elif .type == "tool_use" then
                "**Tool: \(.name)**\n```\n\(.input | tostring | .[0:$tip])\n```"
              elif .type == "tool_result" then
                "**Result**: \((.content // "") | tostring | .[0:$trp])"
              else empty
              end
            ] | join("\n\n")
          else ""
          end
        )
      } |
      select(.content != "") |
      "## \(.role | gsub("^user$";"User") | gsub("^assistant$";"Assistant")) (\(.ts))\n\n\(.content)\n"
    ' "$jsonl_file" 2>/dev/null
  } > "$output_file"
}

# --- 단일 세션 아카이빙 ---

archive_session() {
  local jsonl_path="$1"
  local session_id
  session_id=$(basename "$jsonl_path" .jsonl)

  # 이미 아카이브됨?
  if is_already_archived "$session_id"; then
    warn "Already archived: $session_id"
    return 0
  fi

  # 프로젝트 이름 결정
  local cwd_from_jsonl project_name
  cwd_from_jsonl=$(head -"$HEADER_SCAN_LINES" "$jsonl_path" | jq -r 'select(.cwd) | .cwd' 2>/dev/null | head -1 || true)

  if [ -z "$cwd_from_jsonl" ]; then
    # CWD를 추출 못하면 JSONL 경로에서 유추
    cwd_from_jsonl="unknown"
    project_name="unknown"
  else
    project_name=$(get_project_name_from_cwd "$cwd_from_jsonl")
  fi

  # 아카이브 디렉토리 생성
  local archive_path="$ARCHIVE_DIR/$project_name/$session_id"
  mkdir -p "$archive_path"

  # 1. JSONL 원본 복사
  cp -p "$jsonl_path" "$archive_path/$session_id.jsonl"

  # 2. 서브에이전트 복사
  local parent_dir
  parent_dir=$(dirname "$jsonl_path")
  if [ -d "$parent_dir/$session_id/subagents" ]; then
    cp -rp "$parent_dir/$session_id/subagents" "$archive_path/subagents"
  fi

  # 3. status-icons 복사
  local icons_file="$CLAUDE_DIR/status-icons/$session_id.json"
  if [ -f "$icons_file" ]; then
    cp -p "$icons_file" "$archive_path/status-icons.json"
  fi

  # 4. memo 복사
  local memo_file="$CLAUDE_DIR/memos/$session_id.md"
  if [ -f "$memo_file" ]; then
    cp -p "$memo_file" "$archive_path/memo.md"
  fi

  # 5. Markdown 변환
  if ! convert_to_markdown "$jsonl_path" "$session_id" "$archive_path/$session_id.md"; then
    warn "Markdown conversion failed for $session_id (raw JSONL preserved)"
  fi

  # 6. meta.json 생성
  local git_branch has_icons has_memo message_count is_worktree
  git_branch=$(head -"$HEADER_SCAN_LINES" "$jsonl_path" | jq -r 'select(.gitBranch) | .gitBranch' 2>/dev/null | head -1 || true)
  [ -f "$icons_file" ] && has_icons=true || has_icons=false
  [ -f "$memo_file" ] && has_memo=true || has_memo=false
  message_count=$(grep -cE '"type":"(user|assistant)"' "$jsonl_path" 2>/dev/null || echo 0)

  # worktree 판별
  if [ -f "$cwd_from_jsonl/.git" ] 2>/dev/null; then
    is_worktree=true
  else
    is_worktree=false
  fi

  jq -n \
    --arg session_id "$session_id" \
    --arg project "$project_name" \
    --arg cwd "$cwd_from_jsonl" \
    --arg git_branch "${git_branch:-}" \
    --arg archived_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg original_path "$jsonl_path" \
    --argjson has_icons "$has_icons" \
    --argjson has_memo "$has_memo" \
    --argjson message_count "$message_count" \
    --argjson worktree "$is_worktree" \
    '{
      session_id: $session_id,
      project: $project,
      cwd: $cwd,
      git_branch: $git_branch,
      archived_at: $archived_at,
      original_path: $original_path,
      has_icons: $has_icons,
      has_memo: $has_memo,
      message_count: ($message_count | tonumber),
      worktree: $worktree
    }' > "$archive_path/meta.json"

  info "Archived: $session_id → $archive_path"
}

# --- --list ---

list_archives() {
  if [ ! -d "$ARCHIVE_DIR" ]; then
    echo "No archives found."
    return 0
  fi

  local count=0
  while IFS= read -r -d '' meta; do
    local fields
    fields=$(jq -r '[(if (.git_branch // "") == "" then "-" else .git_branch end) as $br | .session_id, .project, $br, .archived_at, (.message_count | tostring), (.worktree | tostring)] | @tsv' "$meta" 2>/dev/null) \
      || { warn "Corrupt meta.json: $meta"; continue; }

    local sid project branch archived_at msg_count is_wt
    IFS=$'\t' read -r sid project branch archived_at msg_count is_wt <<< "$fields"

    local wt_tag=""
    [ "$is_wt" = "true" ] && wt_tag=" [worktree]"

    printf '%s  %-20s  %-40s  %3s msgs  %s%s\n' \
      "${archived_at%%T*}" "$project" "$branch" "$msg_count" "$sid" "$wt_tag"
    count=$((count + 1))
  done < <(find "$ARCHIVE_DIR" -name meta.json -print0 2>/dev/null | sort -z)

  if [ "$count" -eq 0 ]; then
    echo "No archives found."
  fi
}

# --- --restore ---

restore_archive() {
  local target_id="$1"

  local meta_file
  meta_file=$(find "$ARCHIVE_DIR" -path "*/$target_id/meta.json" -print -quit 2>/dev/null)

  if [ -z "$meta_file" ]; then
    err "Archive not found: $target_id"
    return 1
  fi

  local archive_dir
  archive_dir=$(dirname "$meta_file")

  local original_path session_id
  original_path=$(jq -r '.original_path' "$meta_file")
  session_id=$(jq -r '.session_id' "$meta_file")

  # JSONL 복원 — 이미 존재하면 전체 restore를 중단 (live 세션 sidecar 오염 방지)
  if [ -f "$archive_dir/$session_id.jsonl" ]; then
    if [ -f "$original_path" ]; then
      warn "File already exists: $original_path"
      warn "Use 'claude --resume $session_id' directly."
      return 0
    fi
    validate_restore_path "$original_path" || return 1
    mkdir -p "$(dirname "$original_path")"
    cp "$archive_dir/$session_id.jsonl" "$original_path"
    info "Restored: $original_path"
  fi

  # status-icons 복원 (현재 mtime 사용 — session-init-icons.sh의 30일 cleanup과 충돌 방지)
  if [ -f "$archive_dir/status-icons.json" ]; then
    local icons_dest="$CLAUDE_DIR/status-icons/$session_id.json"
    if validate_restore_path "$icons_dest"; then
      cp "$archive_dir/status-icons.json" "$icons_dest"
      info "Restored: $icons_dest"
    fi
  fi

  # memo 복원
  if [ -f "$archive_dir/memo.md" ]; then
    local memo_dest="$CLAUDE_DIR/memos/$session_id.md"
    if validate_restore_path "$memo_dest"; then
      cp "$archive_dir/memo.md" "$memo_dest"
      info "Restored: $memo_dest"
    fi
  fi

  # subagents 복원 — validate_restore_path는 파일 경로를 요구하므로,
  # 부모 디렉토리가 allowlist 내인지 확인하기 위해 하위 placeholder 경로를 사용
  if [ -d "$archive_dir/subagents" ]; then
    local parent_dir
    parent_dir=$(dirname "$original_path")
    local subagent_dest="$parent_dir/$session_id/subagents"
    if validate_restore_path "$parent_dir/$session_id/placeholder"; then
      mkdir -p "$subagent_dest"
      cp -r "$archive_dir/subagents/." "$subagent_dest/"
      info "Restored: $subagent_dest"
    fi
  fi

  echo ""
  echo "Session files restored. Note: only session files are restored."
  echo "Branch/code context is NOT restored — check out the branch manually."
  echo ""
  echo "To resume: claude --resume $session_id"
}

# --- 메인 ---

main() {
  local mode="current"
  local restore_id=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --all)     mode="all"; shift ;;
      --project) mode="project"; shift ;;
      --list)    mode="list"; shift ;;
      --restore)
        mode="restore"
        [ -z "${2:-}" ] && { err "Missing session ID for --restore"; usage; exit 1; }
        restore_id="$2"
        shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) err "Unknown option: $1"; usage; exit 1 ;;
    esac
  done

  case "$mode" in
    list)
      list_archives
      ;;

    restore)
      restore_archive "$restore_id"
      ;;

    current)
      local session_id
      session_id=$(find_current_session "$PWD") || {
        # fallback: CWD 프로젝트 디렉토리에서 가장 최근 수정된 JSONL
        local latest=""
        local latest_mtime=0
        while IFS= read -r f; do
          [ -f "$f" ] || continue
          local mt
          mt=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
          if [ "$mt" -gt "$latest_mtime" ]; then
            latest_mtime="$mt"
            latest="$f"
          fi
        done < <(find_sessions_for_cwd "$PWD")

        if [ -z "$latest" ]; then
          err "No sessions found for current directory"
          exit 1
        fi
        archive_session "$latest"
        exit 0
      }

      local encoded
      encoded=$(encode_path "$PWD")
      local jsonl_path="$CLAUDE_DIR/projects/$encoded/$session_id.jsonl"

      if [ ! -f "$jsonl_path" ]; then
        err "Session file not found: $jsonl_path"
        exit 1
      fi

      archive_session "$jsonl_path"
      ;;

    all)
      local count=0
      while IFS= read -r jsonl; do
        [ -n "$jsonl" ] || continue
        archive_session "$jsonl"
        count=$((count + 1))
      done < <(find_sessions_for_cwd "$PWD")

      if [ "$count" -eq 0 ]; then
        err "No sessions found for current directory"
        exit 1
      fi

      info "Archived $count session(s)"
      ;;

    project)
      local canonical_root
      canonical_root=$(get_canonical_root) || {
        err "Not a git repository"
        exit 1
      }

      local count=0
      while IFS= read -r jsonl; do
        [ -n "$jsonl" ] || continue
        archive_session "$jsonl"
        count=$((count + 1))
      done < <(find_sessions_for_project "$canonical_root")

      if [ "$count" -eq 0 ]; then
        err "No sessions found for project"
        exit 1
      fi

      info "Archived $count session(s) for $(basename "$canonical_root")"
      ;;
  esac
}

main "$@"

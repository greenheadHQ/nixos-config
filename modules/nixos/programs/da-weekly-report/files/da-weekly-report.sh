#!/usr/bin/env bash
# DA 주간 리포트 파이프라인 진입점.
#
# systemd 모듈은 다음 과제에서 이 스크립트를 writeShellApplication으로 감싼다.
# 이 파일 자체는 user-scope 계약만 가정한다: HOME 아래 상태/SSH/Pushover 설정을 사용하고,
# GitHub 토큰은 gh 호출 한 줄에만 셸 할당으로 주입한다. set -x 금지.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEEKLY_REPORT_PY="${WEEKLY_REPORT_PY:-$SCRIPT_DIR/weekly_report.py}"
ANALYZE_PY="${ANALYZE_PY:-$SCRIPT_DIR/../../../../shared/programs/claude/files/skills/analyzing-da-sessions/scripts/analyze.py}"

if [ -z "${REPO_ROOT:-}" ]; then
  REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
fi

USERNAME_FOR_PATHS="${DA_WEEKLY_USERNAME:-${USER:-$(id -un)}}"
HOME="${HOME:-/home/$USERNAME_FOR_PATHS}"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/da-weekly-report}"
HOSTS="${HOSTS:-mac,minipc}"
HOST_HOME="${HOST_HOME:-mac=/Users/$USERNAME_FOR_PATHS,minipc=/home/$USERNAME_FOR_PATHS}"
GH_PAT_PATH="${GH_PAT_PATH:-/run/opnix/$USERNAME_FOR_PATHS/github-pat}"
PUSHOVER_SHARE_CRED="${PUSHOVER_SHARE_CRED:-$HOME/.config/pushover/share}"
PUSHOVER_HELPER="${PUSHOVER_HELPER:-$HOME/.local/lib/pushover.sh}"
TRACKING_ISSUE_NUMBER="${TRACKING_ISSUE_NUMBER:-}"
DEADLINE_HOUR="${DEADLINE_HOUR:-14}"

mkdir -p "$STATE_DIR"

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

current_collection_host() {
  case "$(uname -s)" in
    Darwin) printf '%s\n' "mac" ;;
    *) printf '%s\n' "minipc" ;;
  esac
}

collect_remote_hosts() {
  local current_host="$1"
  local item host
  local -a host_items=()
  REMOTE_HOSTS=()
  IFS=',' read -r -a host_items <<< "$HOSTS"
  for item in "${host_items[@]}"; do
    host="$(trim "$item")"
    if [ -n "$host" ] && [ "$host" != "$current_host" ]; then
      REMOTE_HOSTS+=("$host")
    fi
  done
}

join_by_comma() {
  local IFS=,
  printf '%s' "$*"
}

deadline_reached() {
  local status
  set +e
  python3 "$WEEKLY_REPORT_PY" deadline-reached --deadline-hour "$DEADLINE_HOUR"
  status=$?
  set -e
  case "$status" in
    0) return 0 ;;
    1) return 1 ;;
    *)
      echo "ERROR: deadline check failed with exit $status" >&2
      exit "$status"
      ;;
  esac
}

send_remote_sleep_alert() {
  local helper="$PUSHOVER_HELPER"
  local cred="$PUSHOVER_SHARE_CRED"
  local body="MacBook이 잠들어 있습니다. 깨우면 다음 정시 시도에 포함됩니다"

  if [ ! -r "$helper" ]; then
    echo "WARN: Pushover helper not readable: $helper" >&2
    return 0
  fi
  if [ ! -r "$cred" ]; then
    echo "WARN: Pushover credential not readable: $cred" >&2
    return 0
  fi

  # shellcheck disable=SC1090
  source "$helper"
  if ! declare -F pushover_send >/dev/null 2>&1; then
    echo "WARN: pushover_send function not found" >&2
    return 0
  fi

  set +e
  pushover_send "$cred" "DA weekly remote host sleeping" "$body" 0
  local status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    echo "WARN: pushover_send exited $status" >&2
  fi
  return 0
}

commentary_contains_file_secret() {
  local secret_file="$1"
  local commentary_file="$2"
  local secret_value=""

  [ -r "$secret_file" ] || return 1
  [ -s "$commentary_file" ] || return 1
  IFS= read -r secret_value < "$secret_file" || return 1
  secret_value="$(trim "$secret_value")"
  if [ -n "$secret_value" ] && grep -Fq -- "$secret_value" "$commentary_file"; then
    secret_value=""
    return 0
  fi
  secret_value=""
  return 1
}

commentary_contains_pushover_secret() (
  local cred_file="$1"
  local commentary_file="$2"
  local secret_value=""

  [ -r "$cred_file" ] || return 1
  [ -s "$commentary_file" ] || return 1
  # shellcheck disable=SC1090
  source "$cred_file" 2>/dev/null || return 1
  for secret_value in "${PUSHOVER_TOKEN:-}" "${PUSHOVER_USER:-}"; do
    if [ -n "$secret_value" ] && grep -Fq -- "$secret_value" "$commentary_file"; then
      secret_value=""
      return 0
    fi
  done
  secret_value=""
  return 1
)

sanitize_commentary_output() {
  [ -s "$COMMENTARY_OUT" ] || return 0

  # Same-UID subprocesses can still read user secret files; nested bwrap isolation made
  # Codex initialization fail in measurement. This gate blocks the public publish path
  # by comparing literal secret values before commentary is accepted.
  if commentary_contains_file_secret "$GH_PAT_PATH" "$COMMENTARY_OUT" \
    || commentary_contains_pushover_secret "$PUSHOVER_SHARE_CRED" "$COMMENTARY_OUT"; then
    rm -f "$COMMENTARY_OUT"
    COMMENTARY_ERROR="sanitize gate: secret-like content"
    return 1
  fi
  return 0
}

load_pending_publish_targets() {
  local output status target
  PENDING_TARGETS=()

  set +e
  output="$(python3 "$WEEKLY_REPORT_PY" pending-publish-targets \
    --publish-log "$PUBLISH_LOG" \
    --targets "$(join_by_comma "${PUBLISH_TARGETS[@]}")")"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    echo "ERROR: publish log status check failed with exit $status" >&2
    exit "$status"
  fi

  while IFS= read -r target; do
    if [ -n "$target" ]; then
      PENDING_TARGETS+=("$target")
    fi
  done <<< "$output"
}

publish_record() {
  local target="$1"
  local status="$2"
  local message="$3"
  local url="${4:-}"
  python3 "$WEEKLY_REPORT_PY" publish-record \
    --publish-log "$PUBLISH_LOG" \
    --week-id "$WEEK_ID" \
    --target "$target" \
    --status "$status" \
    --message "$message" \
    --url "$url" \
    --report-json "$REPORT_JSON" \
    --report-md "$REPORT_MD"
}

publish_github() {
  local gh_status gh_stderr gh_stdout
  COMMENT_URL=""
  if [ -z "$TRACKING_ISSUE_NUMBER" ]; then
    publish_record "github" "skipped" "TRACKING_ISSUE_NUMBER not set"
  elif [ ! -r "$GH_PAT_PATH" ]; then
    publish_record "github" "skipped" "GH token path not readable: $GH_PAT_PATH"
  elif ! command -v gh >/dev/null 2>&1; then
    publish_record "github" "skipped" "gh command not found"
  else
    gh_stdout="$STATE_DIR/weekly-$WEEK_ID-gh.out"
    gh_stderr="$STATE_DIR/weekly-$WEEK_ID-gh.err"
    set +e
    (
      cd "$REPO_ROOT"
      GH_TOKEN="$(< "$GH_PAT_PATH")" gh issue comment "$TRACKING_ISSUE_NUMBER" --body-file "$REPORT_MD"
    ) >"$gh_stdout" 2>"$gh_stderr"
    gh_status=$?
    set -e
    if [ "$gh_status" -eq 0 ]; then
      COMMENT_URL="$(grep -Eo 'https://[^ ]+' "$gh_stdout" | head -n 1 || true)"
      publish_record "github" "success" "comment posted" "$COMMENT_URL"
    else
      publish_record "github" "failed" "$(tr '\n' ' ' < "$gh_stderr" | cut -c1-500)"
    fi
  fi
}

publish_pushover() {
  local pushover_cred pushover_helper push_body push_status
  pushover_helper="$PUSHOVER_HELPER"
  pushover_cred="$PUSHOVER_SHARE_CRED"
  if [ ! -r "$pushover_helper" ]; then
    publish_record "pushover" "skipped" "helper not readable: $pushover_helper"
  elif [ ! -r "$pushover_cred" ]; then
    publish_record "pushover" "skipped" "credential not readable: $pushover_cred"
  else
    # shellcheck disable=SC1090
    source "$pushover_helper"
    if ! declare -F pushover_send >/dev/null 2>&1; then
      publish_record "pushover" "skipped" "pushover_send function not found"
    else
      push_body="$(python3 "$WEEKLY_REPORT_PY" notification --report-json "$REPORT_JSON")"
      if [ -n "$COMMENT_URL" ]; then
        push_body="${push_body}
GitHub: $COMMENT_URL"
      fi
      set +e
      pushover_send "$pushover_cred" "DA weekly $WEEK_ID" "$push_body" 0
      push_status=$?
      set -e
      if [ "$push_status" -eq 0 ]; then
        publish_record "pushover" "success" "notification sent" "$COMMENT_URL"
      else
        publish_record "pushover" "failed" "pushover_send exited $push_status"
      fi
    fi
  fi
}

publish_selected_targets() {
  local target
  for target in "$@"; do
    case "$target" in
      github) publish_github ;;
      pushover) publish_pushover ;;
      *) echo "WARN: unknown publish target skipped: $target" >&2 ;;
    esac
  done
}

WEEK_ID="$(python3 "$WEEKLY_REPORT_PY" week-id)"
ANALYSIS_JSON="$STATE_DIR/analyze-$WEEK_ID.json"
ANALYSIS_MD="$STATE_DIR/analyze-$WEEK_ID.md"
DRAFT_JSON="$STATE_DIR/weekly-$WEEK_ID.draft.json"
DRAFT_MD="$STATE_DIR/weekly-$WEEK_ID.draft.md"
REPORT_JSON="$STATE_DIR/weekly-$WEEK_ID.json"
REPORT_MD="$STATE_DIR/weekly-$WEEK_ID.md"
PUBLISH_LOG="$STATE_DIR/weekly-$WEEK_ID-publish.json"
COMMENTARY_OUT="$STATE_DIR/weekly-$WEEK_ID-commentary.txt"
ATTEMPT_STATE="$(python3 "$WEEKLY_REPORT_PY" attempt-state-path --state-dir "$STATE_DIR" --week-id "$WEEK_ID")"
PUBLISH_TARGETS=(github pushover)

echo "== DA weekly report $WEEK_ID =="
echo "repo: $REPO_ROOT"
echo "state: $STATE_DIR"

if [ -s "$REPORT_JSON" ]; then
  echo "final report exists: $REPORT_JSON"
  load_pending_publish_targets
  if [ "${#PENDING_TARGETS[@]}" -eq 0 ]; then
    echo "publish targets already successful"
    exit 0
  fi
  echo "retrying publish targets: $(join_by_comma "${PENDING_TARGETS[@]}")"
  COMMENT_URL=""
  publish_selected_targets "${PENDING_TARGETS[@]}"
  echo "report: $REPORT_JSON"
  echo "markdown: $REPORT_MD"
  echo "publish log: $PUBLISH_LOG"
  exit 0
fi

CURRENT_HOST="$(current_collection_host)"
collect_remote_hosts "$CURRENT_HOST"
if [ "${#REMOTE_HOSTS[@]}" -gt 0 ]; then
  echo "remote preflight hosts: $(join_by_comma "${REMOTE_HOSTS[@]}")"
else
  echo "remote preflight hosts: none"
fi

UNREACHABLE_HOSTS=()
for host in "${REMOTE_HOSTS[@]}"; do
  # Shell retry-window preflight intentionally uses BatchMode=yes and relies on
  # SSH ConnectTimeout. Python analyze.py preflight has no BatchMode but also
  # enforces a subprocess timeout; update both comments and host-handling.md
  # if either contract changes.
  if ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" true >/dev/null 2>&1; then
    echo "remote host alive: $host"
  else
    echo "remote host unreachable: $host"
    UNREACHABLE_HOSTS+=("$host")
  fi
done

if [ "${#UNREACHABLE_HOSTS[@]}" -gt 0 ]; then
  if deadline_reached; then
    echo "deadline reached at hour $DEADLINE_HOUR; proceeding with partial collection"
  else
    echo "deadline not reached; waiting for next scheduled attempt"
    set +e
    python3 "$WEEKLY_REPORT_PY" claim-attempt-alert --state-file "$ATTEMPT_STATE"
    CLAIM_STATUS=$?
    set -e
    case "$CLAIM_STATUS" in
      0)
        send_remote_sleep_alert
        ;;
      1)
        echo "remote sleep alert already claimed for $WEEK_ID"
        ;;
      *)
        echo "ERROR: attempt alert state update failed with exit $CLAIM_STATUS" >&2
        exit "$CLAIM_STATUS"
        ;;
    esac
    exit 0
  fi
fi

# 1. analyze.py 실행. non-zero라도 sidecar가 있으면 partial로 계속 진행한다.
set +e
python3 "$ANALYZE_PY" \
  --hosts "$HOSTS" \
  --host-home "$HOST_HOME" \
  --json "out=$ANALYSIS_JSON" \
  > "$ANALYSIS_MD"
ANALYZE_STATUS=$?
set -e

if [ ! -s "$ANALYSIS_JSON" ]; then
  echo "ERROR: analyze.py did not produce sidecar: $ANALYSIS_JSON" >&2
  exit 1
fi

# 2. 해설 입력용 draft JSON. final glob(weekly-????-W??.json)에 걸리지 않는 이름을 쓴다.
python3 "$WEEKLY_REPORT_PY" build \
  --analysis-sidecar "$ANALYSIS_JSON" \
  --state-dir "$STATE_DIR" \
  --repo-root "$REPO_ROOT" \
  --output-json "$DRAFT_JSON" \
  --output-md "$DRAFT_MD" \
  --publish-log-path "$PUBLISH_LOG" \
  --commentary-error "LLM commentary pending" \
  --analyze-exit-code "$ANALYZE_STATUS"

# 3. LLM 해설은 repo 밖 scratch cwd + read-only sandbox + stdin 입력만 사용한다.
COMMENTARY_ERROR=""
SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/da-weekly-report-llm.XXXXXX")"
COMMENTARY_INPUT="$SCRATCH_DIR/commentary-input.txt"
cat > "$COMMENTARY_INPUT" <<'EOF'
아래 DA weekly report JSON을 읽고 특이점, 공통점/차이점, 다음 주에 볼 신호를 한국어 한두 문단으로 해설하라.
숫자를 새로 만들지 말고 입력 JSON의 값만 근거로 사용하라.
EOF
cat "$DRAFT_JSON" >> "$COMMENTARY_INPUT"

if command -v codex-exec-supervised >/dev/null 2>&1; then
  set +e
  # --skip-git-repo-check: scratch cwd는 의도적으로 git repo 밖이다 (secret/repo 접근 격리).
  # 이 플래그가 없으면 codex가 untrusted directory로 거부한다 (systemd 실측에서 확인).
  cat "$COMMENTARY_INPUT" | env \
    -u GH_TOKEN \
    -u GITHUB_TOKEN \
    -u GH_PAT_PATH \
    -u GITHUB_PAT \
    -u GH_PAT \
    -u OP_SERVICE_ACCOUNT_TOKEN \
    -u PUSHOVER_TOKEN \
    -u PUSHOVER_USER \
    -u PUSHOVER_FILE \
    -u PUSHOVER_CRED \
    -u PUSHOVER_CRED_FILE \
    -u PUSHOVER_SHARE_CRED \
    -u PUSHOVER_HELPER \
    CODEX_PROGRAMMATIC=1 codex-exec-supervised \
    --sandbox read-only \
    --ignore-user-config \
    --ignore-rules \
    --ephemeral \
    --skip-git-repo-check \
    -c model_reasoning_effort=xhigh \
    -C "$SCRATCH_DIR" \
    -o "$COMMENTARY_OUT" \
    -
  LLM_STATUS=$?
  set -e
  if [ "$LLM_STATUS" -ne 0 ]; then
    COMMENTARY_ERROR="codex-exec-supervised failed with exit $LLM_STATUS"
  elif [ ! -s "$COMMENTARY_OUT" ]; then
    COMMENTARY_ERROR="codex-exec-supervised produced empty commentary"
  else
    sanitize_commentary_output || true
  fi
else
  COMMENTARY_ERROR="codex-exec-supervised not found"
fi

# 4. draft와 같은 측정 JSON에 commentary만 주입해 final core를 발송 전에 원자 저장한다.
# publish 결과는 별도 append-only log만 사용한다.
FINALIZE_ARGS=(
  finalize
  --input-json "$DRAFT_JSON"
  --output-json "$REPORT_JSON"
  --output-md "$REPORT_MD"
)
if [ -n "$COMMENTARY_ERROR" ]; then
  FINALIZE_ARGS+=(--commentary-error "$COMMENTARY_ERROR")
else
  FINALIZE_ARGS+=(--commentary-file "$COMMENTARY_OUT")
fi
python3 "$WEEKLY_REPORT_PY" "${FINALIZE_ARGS[@]}"

rm -f "$DRAFT_JSON" "$DRAFT_MD"

COMMENT_URL=""
publish_selected_targets "${PUBLISH_TARGETS[@]}"

echo "report: $REPORT_JSON"
echo "markdown: $REPORT_MD"
echo "publish log: $PUBLISH_LOG"

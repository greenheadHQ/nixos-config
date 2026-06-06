#!/usr/bin/env bash
# statusline: Claude Code의 cockpit형 statusline
#
# 동작:
#   stdin으로 Claude Code가 제공하는 statusLine JSON을 받아 여러 줄로 렌더링한다:
#   - L1: status-icons (Jira/Slack/Figma/Memo) OSC 8 hyperlink — sidecar 가 있을 때
#   - L2: cwd(📁) + git branch(🌿) + branch 동기화 상태(ahead/behind/dirty/diff)
#   - L_M: Plan(📝) + Memory(🧠) — 감지될 때
#   - L_SID: session-id(🆔) 전용 줄 — session_id 가 있을 때
#   - L_N: rate_limits.{five_hour,seven_day} progress bar
#
# 상태 파일 키는 stdin JSON의 .session_id를 사용한다. .session_id가 없으면
# .transcript_path basename으로 fallback한다 (구버전 호환). sidecar I/O
# (status-icons/plan/memory)는 SIDECAR_IO_ENABLED 가드(valid session_id +
# transcript_path) 통과 시에만 활성화되며, 미통과 시에도 cwd/branch/session-id/
# rate 는 정상 렌더링된다(sidecar 영역만 skip).
#
# 추가로 SIDECAR_IO_ENABLED 가드를 도입해 (a) session_id allowlist 통과 + (b)
# transcript_path가 $HOME/.claude/projects/ 하위인 정상 경로일 때만 sidecar I/O
# (status-icons 등)를 활성화한다. 가드 미통과 시 sidecar 영역(아이콘/plan/memory)만
# skip 하고 cwd/branch/session-id/rate 는 정상 렌더링한다.
#
# SSH 환경에서는 OSC 8 hyperlink가 클릭 불가하므로 외부 링크는 평문 URL로 출력하고 로컬 파일은 텍스트만 표기.
#
# 출력 예 (status-icons + rate):
#   ⚡ PROJ-1234  💬 Slack  🎨 Figma  📓 Memo
#   ██░░░░░░░░ 23% 5h → 2h15m (04/17 19:00) | ████░░░░░░ 41% 7d → 6d17h (04/24 09:00)
#
# 의존성: bash, jq, date, awk, stty

set -u

# === 입력 검증 helper SSOT ===
# 8 개 helper 모두 사용부 활성화. cwd v2 (validate_cwd_syntax /
# canonicalize_dir / tilde_shorten) 는 L2 cwd 라인 및 cwd IDE URL 생성 입력으로
# 사용한다. cwd IDE URL 의 scheme 선택 (env override / macOS 자동 감지 / vscode
# fallback) 은 tilde_shorten 직후의 IDE URL template SSOT 블록을 본다.

# OSC 8 URL에 control char가 있으면 거부 (escape injection 차단). 빈 문자열은
# 통과 (caller 가 OSC 8 미사용 분기로 분기).
# 검사는 tr 라운드트립 — grep '[[:cntrl:]]' 은 라인 단위 처리 특성상 LF (0x0a)
# 를 본문 control char 로 보지 못해 통과시키는 결함이 있어 tr 로 교체했다.
sanitize_osc8_url() {
  local url=${1:-} stripped
  [ -z "$url" ] && return 0
  stripped=$(printf '%s' "$url" | LC_ALL=C tr -d '[:cntrl:]')
  [ "$stripped" = "$url" ] || return 0
  printf '%s' "$url"
}

# UTF-8 byte-aware percent encoding. jq @uri 가 / 까지 인코딩하므로 path
# separator 는 gsub 로 복원. jq 부재는 line 27 가드로 조기 종료되므로 fallback
# path 불필요.
percent_encode_segment() {
  local input=${1:-}
  [ -z "$input" ] && return 0
  printf '%s' "$input" | jq -sRr '@uri | gsub("%2F"; "/")'
}

# best-effort symlink resolve. macOS/BSD 의 `readlink -f` 부재 환경까지
# 커버하기 위해 cd + pwd -P 로 normalize.
# 본 PR 에서 L2 cwd 라인 입력 (CWD_RESOLVED) 으로 사용.
canonicalize_dir() {
  local dir=${1:-}
  [ -z "$dir" ] && return 0
  [ -d "$dir" ] || return 0
  (cd "$dir" 2>/dev/null && pwd -P) || return 0
}

# transcript_path 가 (a) 절대경로 (b) symlink 아님 (c) .jsonl 확장자 (d) leaf
# 파일 실재 (e) $HOME/.claude/projects/ root 하위에 있을 때만 canonical dir 출력.
# 어느 조건이라도 실패하면 빈 출력 → caller 가 TRANSCRIPT_VALID=false 로 처리.
# (d) leaf 실재 검사 — 존재하지 않는 .jsonl 경로로 sidecar I/O gate 가 열려
# status-icons/HEAVY state 를 읽는 것을 막는다(SSOT: 실제 transcript 가 있는 세션만).
validate_transcript_path() {
  local tp=${1:-}
  local dir canonical_dir canonical_root
  [ -z "$tp" ] && return 0
  case "$tp" in /*) ;; *) return 0 ;; esac
  [ -L "$tp" ] && return 0
  case "$tp" in *.jsonl) ;; *) return 0 ;; esac
  [ -f "$tp" ] || return 0
  dir=$(dirname "$tp")
  canonical_dir=$(canonicalize_dir "$dir") || return 0
  [ -z "$canonical_dir" ] && return 0
  canonical_root=$(canonicalize_dir "$HOME/.claude/projects") || return 0
  [ -z "$canonical_root" ] && return 0
  case "$canonical_dir" in
    "$canonical_root"|"$canonical_root"/*) ;;
    *) return 0 ;;
  esac
  printf '%s' "$canonical_dir"
}

# session_id allowlist + `..` traversal 차단 (status-icons sidecar 경로
# traversal 방어 가드). hook lib(session-state.sh)의 is_safe_session_id 와
# 동일 정책 — `[A-Za-z0-9._-]` 만 허용 + `..` 차단. self-contained 렌더러라
# lib 을 source 하지 않지만 정책은 SSOT 와 일치시켜 drift(hook 이 생성한
# sidecar 의 sid 를 statusline 이 거부해 아이콘/plan/memory 가 안 보이는 케이스)를
# 막는다. 첫/끝 character 추가 제한을 두지 않는다(lib 과 동일).
validate_session_id() {
  local sid=${1:-}
  case "$sid" in
    "")                       return 1 ;;
    *[!A-Za-z0-9._-]*)        return 1 ;;
    *..*)                     return 1 ;;
  esac
  return 0
}

# cwd 가 (a) 절대경로 (b) control char (LF 포함) 미포함 일 때만 그대로 출력.
# 본 PR 에서 L2 cwd 라인의 syntax 게이트로 사용 → 통과한 값만 canonicalize_dir 입력.
# control char 검사는 tr 라운드트립 — sanitize_osc8_url 과 동일한 이유 (LF 누락 회피).
validate_cwd_syntax() {
  local cwd=${1:-} stripped
  [ -z "$cwd" ] && return 0
  case "$cwd" in /*) ;; *) return 0 ;; esac
  stripped=$(printf '%s' "$cwd" | LC_ALL=C tr -d '[:cntrl:]')
  [ "$stripped" = "$cwd" ] || return 0
  printf '%s' "$cwd"
}

# display 용 텍스트에서 control char 제거. statusline 시각 출력에 사용.
sanitize_display_text() {
  local text=${1:-}
  [ -z "$text" ] && return 0
  printf '%s' "$text" | LC_ALL=C tr -d '[:cntrl:]'
}

# $HOME 으로 시작하는 경로를 `~` 로 단축. 그 외는 그대로.
# 본 PR 에서 L2 cwd display 단축에 사용 (worktree 합성 display 의 main repo 단축 포함).
tilde_shorten() {
  local path=${1:-}
  [ -z "$path" ] && return 0
  case "$path" in
    "$HOME")    printf '~' ;;
    "$HOME"/*)  printf '~%s' "${path#"$HOME"}" ;;
    *)          printf '%s' "$path" ;;
  esac
}

# === IDE URL template SSOT (cwd L2 OSC 8 hyperlink) ===
# L2 cwd 📁 라인의 OSC 8 hyperlink target 을 사용자 IDE 에 맞춰 생성한다.
# template 의 `%s` 는 percent_encode_segment 출력 (leading slash 포함 절대경로)
# 으로 치환된다 — 모든 IDE scheme 을 같은 규약으로 통일하므로 VSCode/Cursor 는
# `scheme://file%s`, JetBrains 계열은 `scheme://open?file=%s` 형태가 모두
# leading slash 포함 절대경로를 그대로 받는다. 우선순위:
#   (A) CLAUDE_STATUSLINE_IDE_URL_TEMPLATE env override (사용자 명시)
#   (C) macOS LaunchServices 자동 감지 (HEAVY 캐시)
#   (fallback) vscode://file%s/?windowId=_blank (현행 보존, backward compat)
# issue #293. 매핑/우선순위는 본 파일의 ide_url_template_for_bundle_id 가 SSOT 다.

# bundle id → URL template 매핑. macOS LaunchServices 는 bundle id 를 lowercase
# 로 저장하므로 입력을 lowercase 정규화 후 매칭한다. 미지원 bundle id 는 빈 출력
# → caller 가 vscode default 로 fallback 한다. 매핑은 회사 IDE 분포
# (VSCode/Cursor/Antigravity/JetBrains 계열) 의 실측 검증된 scheme 만 포함한다 —
# 미확정 scheme 은 추가하지 않는다 (오매핑보다 vscode fallback 이 안전한 silent
# UX 회복 경로). VSCode 계열 fork (Cursor/Antigravity) 는 `scheme://file%s`,
# JetBrains 계열은 Toolbox URL handler `scheme://open?file=%s` 규약을 따른다.
# bundle id / scheme 은 macOS 실측 (CFBundleIdentifier / CFBundleURLSchemes):
#   com.microsoft.vscode → vscode, com.todesktop.230313mzl4w4u92 → cursor,
#   com.google.antigravity → antigravity, com.jetbrains.intellij → idea,
#   com.jetbrains.webstorm → webstorm.
#
# ⚠ JetBrains 계열 (idea/webstorm) 의 scheme 은 VSCode 계열과 성격이 다르다.
# VSCode/Cursor/Antigravity 의 `scheme://file%s` 는 앱이 CFBundleURLSchemes 로
# 직접 등록하는 핸들러라 자동 감지로 매핑돼도 클릭이 확실히 동작한다. 반면
# `idea://open?file=` 의 open 동작은 JetBrains Toolbox / 플러그인이 핸들러를
# 등록한 경우에만 보장되는 의존적 동작이라 (IDEA-65879 / IJPL-35295), 미등록
# 환경에서 자동 감지로 매핑되면 클릭이 무반응 (silent no-op) 일 수 있다. 따라서
# JetBrains 사용자는 env override 로 명시하는 것을 우선 권장한다 (install-
# statusline.md 의 자동 감지 매핑표 각주 참조). 매핑 자체는 Toolbox 사용자를
# 위해 유지한다. issue #293 검증 반영.
ide_url_template_for_bundle_id() {
  local bid
  bid=$(printf '%s' "${1:-}" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  case "$bid" in
    com.microsoft.vscode)          printf 'vscode://file%%s/?windowId=_blank' ;;
    com.todesktop.230313mzl4w4u92) printf 'cursor://file%%s' ;;
    com.google.antigravity)        printf 'antigravity://file%%s' ;;
    com.jetbrains.intellij)        printf 'idea://open?file=%%s' ;;      # Toolbox/플러그인 핸들러 등록 시 동작
    com.jetbrains.webstorm)        printf 'webstorm://open?file=%%s' ;;  # Toolbox/플러그인 핸들러 등록 시 동작
    *) return 0 ;;
  esac
}

# IDE allowlist SSOT — 자동 감지(detect) 분기가 사용한다.
# 위 ide_url_template_for_bundle_id 의 case 와 같은 bundle id 집합을 유지한다.
# 여기 bundle id 는 mdfind / defaults read 의 case-sensitive 매칭용이라 실제 앱의
# CFBundleIdentifier 원본 대소문자를 그대로 쓴다 (case 문은 lowercase 정규화 후
# 비교하므로 표현이 다르다 — drift 테스트는 lowercase 기준으로 두 집합을 대조한다).
# 출력 형식: "표시이름|bundle_id" 한 줄씩. installer 가 helper 만 source 해 재사용한다.
known_ide_list() {
  printf '%s\n' \
    "VSCode|com.microsoft.VSCode" \
    "Cursor|com.todesktop.230313mzl4w4u92" \
    "Antigravity|com.google.antigravity" \
    "IntelliJ IDEA|com.jetbrains.intellij" \
    "WebStorm|com.jetbrains.WebStorm"
}

# 옵션 C — macOS LaunchServices 에서 source-code 의 default 에디터를 조회해 IDE
# URL template 으로 환원. defaults export → plutil json → jq 로 LSHandlers 배열을
# 파싱한다. 조회 신호를 우선순위로 평탄화:
#   (1) 회사 주력 확장자 (ts/tsx/kt/java/py/go/... 의 public.filename-extension)
#       의 default 에디터 — 사용자가 "이 확장자는 항상 X 로" 설정한 구체적 신호.
#       public.source-code 추상 UTI 보다 실제로 설정될 확률이 높다.
#   (2) public.source-code UTI 의 default handler — 상위 fallback.
# 후보를 우선순위 순서로 순회하며 ide_url_template_for_bundle_id 가 매핑하는 첫
# IDE 를 채택한다. 매핑은 lowercase allowlist 라서 Xcode (com.apple.dt.xcode) /
# TextEdit / Finder / Zed 등 allowlist 밖 handler 는 빈 출력으로 자동 skip 되어
# 다음 후보로 넘어가고, 끝까지 매칭이 없으면 caller 가 vscode default 로 fallback
# 한다 — 명시 설정이 없는 macOS 의 source code 기본값이 Xcode 로 잡혀 원치 않는
# 에디터가 열리는 것을 구조적으로 차단한다 (allowlist = deny-by-default).
# macOS 전용 — defaults/plutil/jq 중 하나라도 부재하면 빈 출력. fork 체인 비용이
# 있어 caller (HEAVY 블록) 가 10초 캐시로 refresh 당 1회로 제한한다.
detect_macos_ide_template() {
  command -v defaults >/dev/null 2>&1 || return 0
  command -v plutil   >/dev/null 2>&1 || return 0
  command -v jq       >/dev/null 2>&1 || return 0
  local candidates bid tmpl
  candidates=$(defaults export com.apple.LaunchServices/com.apple.launchservices.secure - 2>/dev/null \
    | plutil -convert json -o - - 2>/dev/null \
    | jq -r '
        (.LSHandlers // []) as $h
        | (["ts","tsx","js","jsx","mjs","cjs","kt","kts","java","py","go","rs","rb","md","json","yaml","yml","sh"]) as $exts
        | [ ($exts[] as $e
              | $h[]
              | select(((.LSHandlerContentTagClass // "") == "public.filename-extension")
                       and (((.LSHandlerContentTag // "") | ascii_downcase) == $e))
              | (.LSHandlerRoleAll // .LSHandlerRoleEditor)),
            ($h[]
              | select((.LSHandlerContentType // "") == "public.source-code")
              | (.LSHandlerRoleAll // .LSHandlerRoleEditor)) ]
        | map(select(. != null and . != "")) | .[]' 2>/dev/null)
  while IFS= read -r bid; do
    [ -z "$bid" ] && continue
    tmpl=$(ide_url_template_for_bundle_id "$bid")
    if [ -n "$tmpl" ]; then
      printf '%s' "$tmpl"
      return 0
    fi
  done <<EOF
$candidates
EOF
  return 0
}

# 옵션 A — env override template 검증. (a) 비어있지 않음 (b) control char 없음
# (OSC 8 escape injection 차단) (c) `%s` placeholder 포함 (d) scheme:// 형식 일
# 때만 template 출력 + return 0. 미통과 시 빈 출력 + return 1 → caller 가 다음
# 우선순위 (LS query / vscode default) 로 fallthrough. control char 검사는 tr
# 라운드트립 — sanitize_osc8_url 과 동일한 이유 (grep 의 LF 누락 회피).
validate_ide_url_template() {
  local tmpl=${1:-} stripped
  [ -z "$tmpl" ] && return 1
  stripped=$(printf '%s' "$tmpl" | LC_ALL=C tr -d '[:cntrl:]')
  [ "$stripped" = "$tmpl" ] || return 1
  # 선행/후행 공백 제거 — 손편집 실수로 들어간 trailing space 가 깨진 URL 을 만들거나
  # leading space 가 아래 scheme:// 게이트에서 거부되는 비대칭을 없앤다 (control char 는
  # 위에서 이미 거부; SPACE 0x20 은 control 이 아니므로 여기서 trim). env·config 공통.
  tmpl="${tmpl#"${tmpl%%[![:space:]]*}"}"
  tmpl="${tmpl%"${tmpl##*[![:space:]]}"}"
  [ -z "$tmpl" ] && return 1
  case "$tmpl" in *'%s'*) ;; *) return 1 ;; esac
  case "$tmpl" in [A-Za-z]*://*) ;; *) return 1 ;; esac
  printf '%s' "$tmpl"
}

# 옵션 B — ~/.claude/statusline-ide-template 의 첫 줄을 IDE template 으로 읽어
# validate_ide_url_template 로 검증한다. (이 파일은 사용자가 직접 두거나 외부 도구가
# atomic write + chmod 600 으로 저장한다.) statusline 은 우선순위
# (env > config > 자동 감지 > vscode) 의 config 단계에서 이 함수를 호출한다.
# 부재 / 빈 첫 줄 / 검증 실패 시 비-zero return + 빈 출력 → caller 가 다음 우선순위로
# fallthrough. trailing newline 없는 단일 라인도 처리한다 (read 가 EOF 로 non-zero
# 여도 line 이 차 있으면 채택). 파일 내용은 env 경로와 동일한 validate 통과를 받는다.
read_ide_config_template() {
  local f="$HOME/.claude/statusline-ide-template" line=""
  [ -f "$f" ] || return 1
  IFS= read -r line < "$f" || true
  [ -n "$line" ] || return 1
  validate_ide_url_template "$line"
}

# cwd OSC 8 URL 생성 — template 의 `%s` 를 percent-encoded 절대경로로 치환한다.
# printf 대신 parameter expansion (${tmpl//%s/...}) 으로 치환해 path/template 의
# `%` 문자 (percent_encode 출력의 %20/%ED 등) 가 printf format 으로 재해석되는
# 것을 차단한다. path/template 어느 쪽이든 비면 빈 출력 → print_icon 이 URL-less
# 분기로 fallback.
build_cwd_url() {
  local path=${1:-} tmpl=${2:-} encoded
  [ -z "$path" ] && return 0
  [ -z "$tmpl" ] && return 0
  encoded=$(percent_encode_segment "$path")
  [ -z "$encoded" ] && return 0
  printf '%s' "${tmpl//%s/$encoded}"
}

# --- resolve_raw_terminal_cols: 5단계 폭 측정 fallback chain ---
# 우선순위:
#   (1) CLAUDE_STATUSLINE_COLUMNS  (사용자 명시 override)
#   (1.5) STATUSLINE_COLS          (v0.2.x deprecated alias — silent regression 방지)
#   (2) STDIN_COLS                 (stdin JSON의 .terminal.columns, v2.1.141+)
#   (3) COLUMNS env                (v2.1.153+ Claude Code가 export)
#   (4) stty size </dev/tty        (실제 TTY 측정)
#   (5) DEFAULT_RAW_COLS=140       (v2.1.139+ baseline)
#
# octal/음수/leading-zero/5자리 이상 입력은 `_is_decimal` (^[1-9][0-9]{0,3}$) 로 거부.
# `_is_decimal`은 top-level 헬퍼로 단독 정의한다 — bash는 nested function에 lexical
# scope가 없어 부모 함수가 호출되면 전역으로 leak되므로, 의도를 명시하고 이름 충돌
# 가능성을 줄이기 위해 모듈 최상위에 둔다.
# 본 함수는 isolation 가능하도록 set -u 직후 정의 — test runner가 source 해서 직접 호출한다.
_is_decimal() { [[ "$1" =~ ^[1-9][0-9]{0,3}$ ]]; }

resolve_raw_terminal_cols() {
  local DEFAULT_RAW_COLS=140 v

  v=${CLAUDE_STATUSLINE_COLUMNS:-}; _is_decimal "$v" && { printf '%s' "$v"; return; }
  v=${STATUSLINE_COLS:-};           _is_decimal "$v" && { printf '%s' "$v"; return; }
  v=${STDIN_COLS:-};                _is_decimal "$v" && { printf '%s' "$v"; return; }
  v=${COLUMNS:-};                   _is_decimal "$v" && { printf '%s' "$v"; return; }
  v=$({ stty size </dev/tty | awk '{print $2}'; } 2>/dev/null)
  _is_decimal "$v" && { printf '%s' "$v"; return; }
  printf '%s' "$DEFAULT_RAW_COLS"
}

# --- _parse_shortstat: `git diff --shortstat` 출력 → "ADD DEL" ---
# shortstat 은 ` N files changed, X insertions(+), Y deletions(-)` 형식이며 변경이
# 한쪽만 있으면 insertions 또는 deletions 절이 생략된다 (예: ` 1 file changed,
# 5 insertions(+)`). 각 숫자를 독립 추출하고 부재 시 0 으로 처리한다. top-level
# 정의 — nested function 금지 (lexical scope 부재로 부모 함수 호출 시 전역 leak).
_parse_shortstat() {
  local s=${1:-} add del
  add=$(printf '%s' "$s" | grep -oE '[0-9]+ insertion' | grep -oE '^[0-9]+'); add=${add:-0}
  del=$(printf '%s' "$s" | grep -oE '[0-9]+ deletion'  | grep -oE '^[0-9]+'); del=${del:-0}
  printf '%s %s' "$add" "$del"
}

# --- _git_ro: untrusted .git 의 hook/lock/network 표면을 차단하는 read-only git ---
# fsmonitor/post-index-change 등 hook 자동 실행과 optional index lock/write 를 막는다.
# GIT_NO_LAZY_FETCH=1: partial clone/promisor repo 에서 rev-list/diff 가 missing object 를
# 만나도 promisor remote 로 on-demand fetch 하지 않는다 (statusline 은 네트워크 호출 불가).
# diff 의 ext-diff/textconv 외부 명령은 전역 -c 로 못 막으므로 diff 호출부에서
# --no-ext-diff --no-textconv 를 별도 명시한다. statusline 은 반복 실행되므로 working-tree
# 접근(status/diff)에 이 차단이 필요하며, rev-list/rev-parse 는 부작용 표면이 없지만 일관성으로
# 동일 wrapper 를 쓴다.
#
# filter driver(clean/smudge/process)는 의도적으로 차단하지 않는다 — 이를 끄면 보안 표면은
# 줄지만 Git LFS/git-crypt 같은 정상 filter repo 가 깨진다: worktree↔index 정규화가 무력화돼
# false dirty/[심볼] 이 뜨고, required filter(LFS 기본 filter.lfs.required=true)면 git 명령
# 자체가 exit 128 로 실패해 상태가 통째로 사라진다. starship 자체도 filter 를 실행하므로,
# "starship 과 동일" parity 를 위해 filter 는 그대로 따른다. (filter 명령 실행 표면은 사용자가
# 그 repo 에서 git status/diff 를 직접 쳐도 동일하게 발생하는 git 공통 표면이다.)
# 향후 보안 강화 제안이 와도 이 절을 근거로 filter 차단을 재도입하지 마라.
# top-level 정의 — nested function 금지.
_git_ro() {
  # read-only guard — 이름(_ro)이 약속하는 read-only 의미를 코드로 강제한다. 현재 호출부가
  # 쓰는 read 계열 subcommand 만 허용하고, write/기타 subcommand 는 거부(return 2)해 다음
  # 수정자가 이 hardening wrapper 를 통해 실수로 tracked write 를 내보내지 못하게 막는다.
  case "${1:-}" in
    rev-list|diff|status|rev-parse) ;;
    *) return 2 ;;
  esac
  GIT_OPTIONAL_LOCKS=0 GIT_NO_LAZY_FETCH=1 git -C "$CWD_RESOLVED" \
    -c core.fsmonitor= -c core.hooksPath=/dev/null "$@"
}

# --- compute_branch_sync: @{upstream} 대비 브랜치 동기화 상태 산출 ---
# CWD_RESOLVED 기준. 결과를 전역 SYNC_* 에 set 한다 (HEAVY 블록에서 호출 → .vars
# 캐시 대상):
#   SYNC_AHEAD / SYNC_BEHIND  : ahead/behind 커밋 수 (upstream 없으면 "")
#   SYNC_HAS_UPSTREAM         : @{upstream} 추적 설정 여부 (true/false)
#   SYNC_COMMIT_ADD / _DEL    : push 대기 커밋 diff (@{upstream}...HEAD, 3-dot = ahead 커밋만)
#   SYNC_DIRTY_ADD / _DEL     : uncommitted diff (HEAD 대비, staged+unstaged)
#   SYNC_GIT_STATUS           : starship git_status 동일 파일 상태 심볼 문자열
#                               (git status --porcelain XY 분류 + refs/stash)
# fetch 는 하지 않는다 — statusline 은 매 refresh 호출되므로 git fetch 불가.
# behind 는 마지막 git fetch 시점의 로컬 origin ref 기준이라 stale 일 수 있다 (허용).
# upstream 미설정 시 graceful: ahead/behind/커밋diff 를 생략하고 dirty 와 git_status 심볼은
# 산출한다 (경고 glyph 없음). detached HEAD / non-git 은 caller(GIT_BRANCH 가드, 호출부 참조)
# 에서 호출 자체가 skip 되어 본 함수에 도달하지 않는다. top-level 정의 — nested 금지.
compute_branch_sync() {
  SYNC_AHEAD=""; SYNC_BEHIND=""; SYNC_HAS_UPSTREAM=false
  SYNC_COMMIT_ADD=0; SYNC_COMMIT_DEL=0; SYNC_DIRTY_ADD=0; SYNC_DIRTY_DEL=0; SYNC_GIT_STATUS=""
  { [ -n "$CWD_RESOLVED" ] && [ -d "$CWD_RESOLVED" ] && command -v git >/dev/null 2>&1; } || return 0

  # @{upstream} tracking 설정 시에만 ahead/behind + push 대기 커밋 diff.
  # rev-list --count --left-right 출력은 "behind<TAB>ahead" (3-dot symmetric diff).
  # upstream 미설정 시 git 은 stderr fatal + 비-zero exit → 2>/dev/null 로 빈 출력.
  local lr
  lr=$(_git_ro rev-list --count --left-right '@{upstream}...HEAD' 2>/dev/null) || lr=""
  if [ -n "$lr" ]; then
    SYNC_HAS_UPSTREAM=true
    SYNC_BEHIND=${lr%%[!0-9]*}      # 구분자(TAB) 앞 = behind (왼쪽)
    SYNC_AHEAD=${lr##*[!0-9]}       # 구분자(TAB) 뒤 = ahead (오른쪽)
    local cs
    # 3-dot = merge-base(@{upstream},HEAD)..HEAD = ahead 커밋만의 변경. 2-dot
    # (@{upstream}..HEAD) 은 endpoints diff 라 behind-only 에서 원격 라인을 -N 으로
    # 잘못 집계한다 (push 대기 의미와 불일치). behind 는 rev-list 의 ↓N 으로 표시.
    # --no-ext-diff --no-textconv: untrusted repo 의 외부 diff/textconv 명령 실행 차단.
    cs=$(_git_ro diff --no-ext-diff --no-textconv --shortstat '@{upstream}...HEAD' 2>/dev/null)
    read -r SYNC_COMMIT_ADD SYNC_COMMIT_DEL <<< "$(_parse_shortstat "$cs")"
  fi

  # dirty 는 upstream 무관하게 항상 (unstaged + staged = HEAD 대비). working-tree 접근이라
  # _git_ro 로 hook/lock 을 막고, diff 의 ext-diff/textconv 외부 명령도 함께 차단한다.
  local ds
  ds=$(_git_ro diff --no-ext-diff --no-textconv --shortstat HEAD 2>/dev/null)
  read -r SYNC_DIRTY_ADD SYNC_DIRTY_DEL <<< "$(_parse_shortstat "$ds")"

  # starship 1.20.1 default git_status 동일 표기 — `git status --porcelain` 의 XY 코드를 파일 상태로
  # 분류해 심볼 문자열을 만든다 (라인 diff 와 병행). starship 분류 규칙과 동일:
  #   X(index)=M/A/T → staged(+) · X=D → deleted(✘) · X=R/C → renamed(»)
  #   Y(worktree)=M/A → modified(!) · Y=D → deleted(✘) · Y=R/C → renamed(»)
  #   Y=T(worktree typechange) 는 starship typechanged(기본 빈 심볼) 와 동일하게 미표기.
  #   '??' → untracked(?) · unmerged(UU/AA/DD/AU/UA/DU/UD) → conflicted(=)
  #   refs/stash 존재 → stashed($). 심볼 순서는 starship all_status 와 동일.
  #   status.showUntrackedFiles/renames 등 분류 config 는 starship 도 동일하게 따르므로
  #   override 하지 않는다 — 강제하면 오히려 parity 가 깨진다(실측 검증). git 호출 hardening
  #   은 _git_ro 참조. process substitution 스트리밍 — 6 presence flag 가 다 차면 조기 종료.
  local _st_conflict='' _st_deleted='' _st_renamed='' _st_modified='' _st_staged='' _st_untracked='' _st_stashed='' _line _xy _x _y
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _xy=${_line:0:2}
    case "$_xy" in
      '??') _st_untracked='?' ;;
      DD|AU|UD|UA|DU|AA|UU) _st_conflict='=' ;;
      *)
        _x=${_xy:0:1}; _y=${_xy:1:1}
        case "$_x" in M|A|T) _st_staged='+' ;; esac
        case "$_x" in D) _st_deleted='✘' ;; esac
        case "$_x" in R|C) _st_renamed='»' ;; esac
        case "$_y" in M|A) _st_modified='!' ;; esac
        case "$_y" in D) _st_deleted='✘' ;; esac
        case "$_y" in R|C) _st_renamed='»' ;; esac
        ;;
    esac
    [ -n "$_st_conflict" ] && [ -n "$_st_deleted" ] && [ -n "$_st_renamed" ] \
      && [ -n "$_st_modified" ] && [ -n "$_st_staged" ] && [ -n "$_st_untracked" ] && break
  done < <(_git_ro status --porcelain 2>/dev/null)
  # stash: refs/stash ref 존재가 아니라 reflog entry count 로 판정한다 (starship parity).
  # ref 만 남고 reflog 가 빈 비정상 repo 에서 starship 은 stashed 로 보지 않으므로, rev-parse
  # 존재 확인이 아닌 reflog count >= 1 을 기준으로 [$] 를 낸다. rev-list 는 read-only.
  [ "$(_git_ro rev-list --walk-reflogs --count refs/stash 2>/dev/null || echo 0)" -gt 0 ] 2>/dev/null \
    && _st_stashed='$'
  SYNC_GIT_STATUS="${_st_conflict}${_st_stashed}${_st_deleted}${_st_renamed}${_st_modified}${_st_staged}${_st_untracked}"
}

input=$(cat)
NOW=$(date +%s)

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

# --- stdin 통합 추출 (jq 1회 호출) ---
# 기존 .session_id, .transcript_path, .rate_limits.* 의 3~4 회 fork 를 단일
# 호출로 통합. .terminal.columns 는 width fallback chain 의 한 슬롯으로 추출되어
# resolve_raw_terminal_cols 에서 COLUMNS env 다음 우선순위로 사용된다.
TRANSCRIPT="" STDIN_SESSION_ID="" CWD="" STDIN_COLS=""
RATE_5H="" RATE_5H_RESET=""
RATE_7D="" RATE_7D_RESET=""

eval "$(printf '%s' "$input" | jq -r '
  @sh "TRANSCRIPT=\(.transcript_path // "")",
  @sh "STDIN_SESSION_ID=\(.session_id // "")",
  @sh "CWD=\(.cwd // "")",
  @sh "STDIN_COLS=\(.terminal.columns // "")",
  @sh "RATE_5H=\(.rate_limits.five_hour.used_percentage // "")",
  @sh "RATE_5H_RESET=\(.rate_limits.five_hour.resets_at // "")",
  @sh "RATE_7D=\(.rate_limits.seven_day.used_percentage // "")",
  @sh "RATE_7D_RESET=\(.rate_limits.seven_day.resets_at // "")"
' 2>/dev/null)" 2>/dev/null || true

# --- transcript_path 검증 ---
CANONICAL_TRANSCRIPT_DIR=$(validate_transcript_path "${TRANSCRIPT:-}")
TRANSCRIPT_VALID=false
[ -n "$CANONICAL_TRANSCRIPT_DIR" ] && TRANSCRIPT_VALID=true

# --- session_id 추출 ---
# 우선 stdin .session_id, 없으면 transcript_path basename fallback (구버전
# 호환). validate_session_id 미통과 시 빈 문자열로 reset → status-icons 영역
# skip.
SESSION_ID="${STDIN_SESSION_ID:-}"
if [ -z "$SESSION_ID" ] && [ -n "${TRANSCRIPT:-}" ]; then
  SESSION_ID=$(basename "$TRANSCRIPT" .jsonl)
fi
validate_session_id "$SESSION_ID" || SESSION_ID=""

# --- SIDECAR_IO_ENABLED 가드 ---
# sidecar I/O (status-icons 등) 활성화 조건:
#   (a) SESSION_ID 가 allowlist 통과
#   (b) transcript_path 가 $HOME/.claude/projects/ 하위 정상 경로
# 두 조건 모두 통과해야 unknown SESSION_ID 공유로 인한 cross-session 누출을
# 차단할 수 있다.
SIDECAR_IO_ENABLED=false
if [ -n "$SESSION_ID" ] && $TRANSCRIPT_VALID; then
  SIDECAR_IO_ENABLED=true
fi

# --- SSH 환경 감지 ---
# SSH 세션(Termius 등)에서는 OSC 8 hyperlink가 클릭 불가하므로 외부 링크(Jira/Slack/Figma)는
# 평문 URL로 출력(print_icon SSH 분기)해 클라이언트 URL regex 감지에 맡기고, 로컬 파일
# (Memo/Plan/Memory)은 텍스트만 표기. SSH_CONNECTION은 sshd가 export하며 자식 프로세스에 상속.
# 감지: SSH_CONNECTION 직접 + tmux 세션 환경 폴백(tmux attach 대응).
IS_SSH=false
[ -n "${SSH_CONNECTION:-}" ] && IS_SSH=true
# tmux attach 폴백: SSH 밖에서 시작한 tmux에 SSH로 attach하면, 이미 떠 있던 pane의
# 프로세스는 갱신된 SSH_CONNECTION을 물려받지 못한다 (fork 모델 — update-environment는
# 새 pane에만 주입). tmux 세션 환경을 조회해 보강한다. 값이 있을 때(SSH_CONNECTION=?*)만
# SSH로 판정 — 로컬 클라이언트 재attach 시 tmux가 남기는 제거표시(-SSH_CONNECTION)는
# 배제해, 데스크톱 재attach 시 OSC 8 동작으로 자동 복귀한다.
if ! $IS_SSH && command -v tmux >/dev/null 2>&1; then
  case "$(tmux show-environment SSH_CONNECTION 2>/dev/null)" in
    SSH_CONNECTION=?*) IS_SSH=true ;;
  esac
fi

# 256-color 고정 그레이 — 터미널 팔레트 의존 \e[90m 대신 사용
MUTED="38;5;242"

# --- SSH 환경 vertical rate gauge glyph palette ---
# 9단계 vertical block — idx 0 은 empty (공백), 1..8 은 ▁..█ (U+2581..U+2588).
# SSH 환경의 좁은 터미널에서 horizontal 10-cell bar 가 wrap 되는 회귀를 막기
# 위해 `▏${glyph}▕` 3-cell 압축 표시로 대체한다. `▏` (U+258F) / `▕` (U+2595)
# 는 thinnest vertical bracket — gauge core glyph 의 좌우 경계를 시각적으로
# 분리하여 색상 구분만으로는 부족한 좁은 폭에서도 진행도를 변별 가능하게 한다.
SSH_BAR_GLYPHS=("" "▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")

# --- cwd v2 사용부 활성화 ---
# 우선 syntax 검증 → control char/relative 거부.
# 통과한 cwd 만 best-effort symlink resolve. canonicalize 실패 (디렉토리 부재
# 등) 시 raw $CWD_VALID 를 fallback 으로 유지하여 display/URL 생성이 빈 결과로
# 떨어지지 않게 한다 (canonicalize_dir 가 부재 디렉토리에서 빈 출력을 내는
# semantics 를 보완).
CWD_VALID=$(validate_cwd_syntax "${CWD:-}")
CWD_CANONICAL=""
[ -n "$CWD_VALID" ] && CWD_CANONICAL=$(canonicalize_dir "$CWD_VALID")
CWD_RESOLVED="${CWD_CANONICAL:-$CWD_VALID}"

# --- HEAVY 캐시 (Plan/Memory/Git worktree) ---
# 매 statusline 호출마다 transcript 스캔 + git rev-parse/status/stash + memory dir 스캔을
# 돌리면 가시적 지연이 발생한다. 본 구간 결과를 sidecar 에 직렬화 (.vars) 하고
# mtime 기준 10초 TTL 내 호출은 source 만으로 복원한다. CACHED_CWD 가 raw $CWD
# 와 다르면 즉시 무효화 (cd 직후 stale state 표시 방지).
#
# 키 사전 초기화 (forward-compat schema lock):
#   .vars 파일 schema 가 v0.4.x 에서 키를 추가/축소할 때 light run restore 가
#   미정의 키를 참조하지 않도록 본 라인에서 기본값을 박는다.
PLAN_FILE=""
MEMORY_LINK=""
MEMORY_LABEL=""
GIT_BRANCH=""
MAIN_REPO_DIR=""
CACHED_CWD=""
# IDE_TEMPLATE_DETECTED: 옵션 C (macOS LaunchServices 자동 감지) 결과. HEAVY
# 영역에서 1회 산출되어 .vars 에 직렬화 → light run 은 source 로 복원한다. 키
# 사전 초기화로 구버전 .vars (이 키 부재) 를 source 해도 미정의 참조가 없다.
IDE_TEMPLATE_DETECTED=""
# SYNC_*: @{upstream} 대비 브랜치 동기화 상태 (ahead/behind + push 대기 커밋 diff
# + uncommitted dirty diff + starship git_status 파일 상태 심볼). HEAVY 영역에서
# compute_branch_sync 가 1회 산출 →
# .vars 직렬화 → light run 은 source 로 복원한다. 키 사전 초기화로 구버전 .vars
# (이 키 부재) source 시 미정의 참조 방지. SYNC_HAS_UPSTREAM 은 bool — restore
# 후 IS_WORKTREE 와 동일하게 case 재정규화한다.
SYNC_AHEAD=""
SYNC_BEHIND=""
SYNC_HAS_UPSTREAM=false
SYNC_COMMIT_ADD=0
SYNC_COMMIT_DEL=0
SYNC_DIRTY_ADD=0
SYNC_DIRTY_DEL=0
SYNC_GIT_STATUS=""
# IS_WORKTREE 는 워크트리 감지부에서 false 로 초기화한다 (아래 블록 직후).

# HEAVY 캐시 경로 결정. $XDG_RUNTIME_DIR 우선 (RAM tmpfs — 재부팅 시 자연 정리)
# → 부재 시 $XDG_STATE_HOME/claude-statusline → 최후 fallback
# $HOME/.local/state/claude-statusline. session_id 가 키 — SIDECAR_IO_ENABLED
# 가드 통과 시에만 read/write.
HEAVY_STATE=""
HEAVY_TTL=10
if $SIDECAR_IO_ENABLED; then
  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
    HEAVY_DIR="$XDG_RUNTIME_DIR/claude-statusline"
  elif [ -n "${XDG_STATE_HOME:-}" ]; then
    HEAVY_DIR="$XDG_STATE_HOME/claude-statusline"
  else
    HEAVY_DIR="$HOME/.local/state/claude-statusline"
  fi
  if mkdir -p "$HEAVY_DIR" 2>/dev/null; then
    chmod 700 "$HEAVY_DIR" 2>/dev/null || true
    HEAVY_STATE="$HEAVY_DIR/heavy-${SESSION_ID}"
  fi
fi

# HEAVY restore: $HEAVY_STATE 의 mtime 이 NOW - HEAVY_TTL 이내이면 .vars 를
# source. cwd 변경 시 즉시 무효화 (CACHED_CWD != $CWD 비교는 raw $CWD 단일 —
# canonicalize 이전 시점).
HEAVY_CACHE_HIT=false
if [ -n "$HEAVY_STATE" ] && [ -f "${HEAVY_STATE}.vars" ] && [ -f "$HEAVY_STATE" ]; then
  HEAVY_MTIME=$(/usr/bin/stat -f %m "$HEAVY_STATE" 2>/dev/null || stat -c %Y "$HEAVY_STATE" 2>/dev/null || echo 0)
  if [ -n "$HEAVY_MTIME" ] && [ "$((NOW - HEAVY_MTIME))" -lt "$HEAVY_TTL" ] 2>/dev/null; then
    # source 안전: 변수 사전 초기화로 키 누락 시 미정의 참조 방지.
    # shellcheck disable=SC1090
    source "${HEAVY_STATE}.vars" 2>/dev/null || true
    case "${IS_WORKTREE:-false}" in
      true) IS_WORKTREE=true ;;
      *)    IS_WORKTREE=false ;;
    esac
    # SYNC_HAS_UPSTREAM 도 bool — %q 직렬화는 true/false 문자열이라 source 후
    # 논리 분기 (render_branch_sync) 전에 정규화한다 (IS_WORKTREE 패턴과 대칭).
    case "${SYNC_HAS_UPSTREAM:-false}" in
      true) SYNC_HAS_UPSTREAM=true ;;
      *)    SYNC_HAS_UPSTREAM=false ;;
    esac
    if [ "${CACHED_CWD:-}" = "${CWD:-}" ]; then
      HEAVY_CACHE_HIT=true
    fi
  fi
fi

# --- worktree 감지 + Plan/Memory transcript 스캔 (HEAVY) ---
# stdin .workspace.git_worktree 가 명시되면 우선 사용 (Claude Code 신규 schema
# 슬롯). 부재 시 git rev-parse --git-dir vs --git-common-dir 비교로 fallback.
# 두 경로가 다르면 worktree, 같으면 main repo. CWD 가 git 리포지토리가 아니거나
# 디렉토리 자체가 부재하면 둘 다 빈 문자열 → IS_WORKTREE=false 유지.
#
# HEAVY 영역 — cache hit 시 source 로 복원되므로 본 블록 전체 skip. cache miss
# 시에만 fork-heavy 한 git rev-parse/status/stash / transcript 스캔 / memory 스캔 수행.
WS_WORKTREE=""
WORKTREE_BRANCH=""

if ! $HEAVY_CACHE_HIT; then
  IS_WORKTREE=false
  GIT_BRANCH=""
  MAIN_REPO_DIR=""

  # .workspace 존재 여부와 무관하게 항상 추출한다 (.worktree.branch 만 있는 공식
  # statusLine 입력도 커버). WORKTREE_BRANCH 는 .workspace.git_branch / .worktree.branch
  # 중 null·빈문자열이 아닌 첫 값을 취한다 (jq // 는 빈문자열을 fallback 하지 않으므로
  # select 로 거른다).
  eval "$(printf '%s' "$input" | jq -r '
    @sh "WS_WORKTREE=\(.workspace.git_worktree // "")",
    @sh "WORKTREE_BRANCH=\([.workspace.git_branch, .worktree.branch] | map(select(. != null and . != "")) | first // "")"
  ' 2>/dev/null)" 2>/dev/null || true

  GIT_DIR_ABS=""
  GIT_COMMON_ABS=""
  if [ -n "$CWD_RESOLVED" ] && [ -d "$CWD_RESOLVED" ] && command -v git >/dev/null 2>&1; then
    # worktree 감지의 rev-parse 도 _git_ro 경유로 통일한다 — hook/fsmonitor/lock 차단을
    # 일관 적용하고, _git_ro allowlist(rev-parse 포함)와 실제 호출 관계를 일치시킨다 (raw
    # git -C 잔존 방지). _git_ro 는 위 top-level 에 정의돼 이 시점 호출 가능하다.
    GIT_DIR_ABS=$(_git_ro rev-parse --path-format=absolute --git-dir 2>/dev/null) || GIT_DIR_ABS=""
    GIT_COMMON_ABS=$(_git_ro rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || GIT_COMMON_ABS=""
  fi

  case "${WS_WORKTREE:-}" in
    true|1) IS_WORKTREE=true ;;
    false|0|"") ;;
    *) IS_WORKTREE=true ;;  # 비어있지 않은 truthy value (예: 경로 string)
  esac
  if ! $IS_WORKTREE; then
    if [ -n "$GIT_DIR_ABS" ] && [ -n "$GIT_COMMON_ABS" ] && [ "$GIT_DIR_ABS" != "$GIT_COMMON_ABS" ]; then
      IS_WORKTREE=true
    fi
  fi

  if $IS_WORKTREE && [ -n "$GIT_COMMON_ABS" ]; then
    # --git-common-dir 결과는 main repo 의 .git 경로 → 한 단계 dirname 으로 repo root.
    MAIN_REPO_DIR=$(dirname "$GIT_COMMON_ABS")
  fi

  GIT_BRANCH="${WORKTREE_BRANCH:-}"
  if [ -z "$GIT_BRANCH" ] && [ -n "$CWD_RESOLVED" ] && [ -d "$CWD_RESOLVED" ] && command -v git >/dev/null 2>&1; then
    GIT_BRANCH=$(git -C "$CWD_RESOLVED" branch --show-current 2>/dev/null) || GIT_BRANCH=""
  fi

  # --- 브랜치 동기화 상태 (HEAVY — @{upstream} 대비 ahead/behind + diff) ---
  # branch 라벨이 출력될 때 (= GIT_BRANCH 존재) 만 의미가 있다. detached HEAD /
  # non-git 은 GIT_BRANCH 가 비어 sync 표기 자리도 없으므로 git fork 자체를 skip.
  # rev-list + diff×2 + status + stash = 최대 5 fork 는 본 HEAVY 블록 안이라 10초 TTL 캐시로 흡수.
  if [ -n "$GIT_BRANCH" ]; then
    compute_branch_sync
  fi

  # --- Plan 자동 감지 (v5 단순화) ---
  # transcript JSONL 에서 .claude/plans/*.md 경로 이벤트를 직접 grep. agent
  # 산출물 plans/<agent-name>-* 는 별도 lineage 라 본 메인 라인에서 제외.
  # 감지된 plan path 는 SIDECAR_IO_ENABLED 통과 시 세션별 state 파일에 박제 →
  # transcript truncation/clear 이후에도 같은 세션 내 복원 가능.
  # `${SESSION_ID:-unknown}` fallback 금지 — unknown 키로
  # 다른 세션의 plan 을 잘못 표시하는 cross-session 누출 차단.
  PLAN_STATE_FILE=""
  if $SIDECAR_IO_ENABLED; then
    PLAN_STATE_FILE="$CANONICAL_TRANSCRIPT_DIR/.statusline-plan-${SESSION_ID}"
  fi

  PLAN_FILE=""
  if $TRANSCRIPT_VALID && [ -f "$TRANSCRIPT" ]; then
    PLAN_FILE=$(grep -v '"type":"agent_progress"' "$TRANSCRIPT" 2>/dev/null \
      | grep -oE '"(filePath|file_path|planFilePath)":"[^"]*\.claude/plans/[^"]*\.md"' \
      | grep -v 'plans/[^"]*-agent-' \
      | tail -1 \
      | sed 's/^"[^"]*":"//;s/"$//')
  fi

  if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ] && [ -n "$PLAN_STATE_FILE" ]; then
    # atomic write — tmp + mv (race / 부분 쓰기 차단).
    plan_tmp=$(mktemp "${PLAN_STATE_FILE}.XXXXXX" 2>/dev/null) || plan_tmp=""
    if [ -n "$plan_tmp" ]; then
      if printf '%s' "$PLAN_FILE" > "$plan_tmp" 2>/dev/null && mv "$plan_tmp" "$PLAN_STATE_FILE" 2>/dev/null; then
        chmod 600 "$PLAN_STATE_FILE" 2>/dev/null || true
      else
        rm -f "$plan_tmp" 2>/dev/null || true
      fi
    fi
  elif [ -z "$PLAN_FILE" ] && [ -n "$PLAN_STATE_FILE" ] && [ -f "$PLAN_STATE_FILE" ]; then
    # transcript 에서 못 찾았으면 state 파일에서 복원 (truncate/clear 이후).
    PLAN_FILE=$(head -1 "$PLAN_STATE_FILE" 2>/dev/null | tr -d '[:cntrl:]') || PLAN_FILE=""
    # 복원된 path 가 실제 파일이 아니면 무효화.
    [ -n "$PLAN_FILE" ] && [ ! -f "$PLAN_FILE" ] && PLAN_FILE=""
  fi

  # --- Memory 자동 감지 ---
  # Claude Code memory 는 <transcript dir>/memory/*.md 서브디렉토리 + 글로벌
  # ~/.claude/memory/*.md 에 존재한다 (2026-03 이후 일관). 과거 회귀: 본 블록이
  # /memory 세그먼트를 누락하고 transcript dir 바로 아래(-maxdepth 1)를 봐서 항상
  # 0건이었다 (Claude Code 동작 변경이 아니라 감지 경로 누락이 원인).
  #
  # worktree 세션은 transcript dir 이 worktree 별 encoded 디렉토리라 /memory 가
  # 없을 수 있으므로, 이미 위 worktree 감지 블록에서 산출된 변수 (MAIN_REPO_DIR,
  # 부재 시 GIT_COMMON_ABS dirname) 로 main repo 의 ~/.claude/projects/<encoded>/
  # memory 를 유도한다 — git rev-parse 를 재호출하지 않는다 (이미 _git_ro 산출분 재사용).
  #
  # 카운트 의미: MEMORY.md index 에 `- [name.md](name.md)` 로 등록된
  # 링크만 Claude getMemoryFiles 가 읽는다 (디렉토리를 스캔하지 않음). 따라서 디스크
  # .md 총합(MEMORY.md 자신 제외) > 등록 링크 수이면 미등록(=Claude 접근 불가) orphan
  # 파일이 존재 → ⚠. 라벨의 N 은 총 메모리 파일 수이지 orphan 개수가 아니다. 글로벌
  # ~/.claude/memory 도 합산한다. MEMORY.md 가 없거나 N=0 이면 🧠 아이콘 미표시.
  # 알려진 한계: project+global 혼재 시 REFERENCED 는 우선 MEMORY.md 단일 기준이라
  # ⚠ 오탐이 가능하다 — 의도적으로 그대로 둔다 (수정하지 않음).
  MEMORY_LINK=""
  MEMORY_LABEL=""
  if $TRANSCRIPT_VALID; then
    PROJECT_MEMORY_DIR="$CANONICAL_TRANSCRIPT_DIR/memory"
    GLOBAL_MEMORY_DIR="$HOME/.claude/memory"
    MEMORY_COUNT=0
    MEMORY_INDEX=""

    # worktree 보정 — transcript dir 에 /memory 가 없으면 main repo encoded
    # projects dir 의 memory 로 유도. MAIN_REPO_DIR 은 IS_WORKTREE 일 때만 set 되므로
    # 부재 시 GIT_COMMON_ABS (git repo 면 worktree 무관 항상 set, --path-format=absolute)
    # 의 dirname 으로 fallback 한다. 인코딩 규약은 Claude Code 와 동일 ([^a-zA-Z0-9]→-).
    if [ ! -d "$PROJECT_MEMORY_DIR" ]; then
      _main_repo="$MAIN_REPO_DIR"
      [ -z "$_main_repo" ] && [ -n "$GIT_COMMON_ABS" ] && _main_repo=$(dirname "$GIT_COMMON_ABS")
      if [ -n "$_main_repo" ]; then
        ENCODED=$(printf '%s' "$_main_repo" | sed 's/[^a-zA-Z0-9]/-/g')
        CANONICAL_MEMORY="$HOME/.claude/projects/$ENCODED/memory"
        [ -d "$CANONICAL_MEMORY" ] && PROJECT_MEMORY_DIR="$CANONICAL_MEMORY"
      fi
    fi

    # project memory — MEMORY.md 자신은 카운트 제외 (! -name MEMORY.md). MEMORY_INDEX
    # 는 project 를 우선 채택 (link 타깃 정확성). find 인자의 trailing slash 는 memory
    # dir 가 심볼릭링크(dotfile sync 등)일 때도 descend 하게 한다 (없으면 0건으로 미표시).
    if [ -d "$PROJECT_MEMORY_DIR" ]; then
      MEMORY_INDEX="$PROJECT_MEMORY_DIR/MEMORY.md"
      MEMORY_COUNT=$(find "$PROJECT_MEMORY_DIR/" -maxdepth 1 -name "*.md" ! -name "MEMORY.md" -type f 2>/dev/null | wc -l | tr -d ' ')
    fi

    # 글로벌 memory 합산 — $TRANSCRIPT_VALID 만 통과하면 project dir 존재와 무관하게
    # 합산한다. MEMORY_INDEX 는 project 부재 시에만 글로벌로 fallback.
    if [ -d "$GLOBAL_MEMORY_DIR" ]; then
      GLOBAL_COUNT=$(find "$GLOBAL_MEMORY_DIR/" -maxdepth 1 -name "*.md" ! -name "MEMORY.md" -type f 2>/dev/null | wc -l | tr -d ' ')
      MEMORY_COUNT=$((MEMORY_COUNT + GLOBAL_COUNT))
      [ -z "$MEMORY_INDEX" ] && MEMORY_INDEX="$GLOBAL_MEMORY_DIR/MEMORY.md"
    fi

    # orphan ⚠ = 디스크 .md 총합 > MEMORY.md 등록 링크 수. grep -c 는 0 매칭 시 exit 1
    # 이라 `|| REFERENCED=0` 로 방어. MEMORY_LINK 는 file:// 없는 raw 디렉토리 경로 —
    # L_M render 가 file://+percent_encode_segment+IS_SSH 분기를 부착한다.
    if [ "$MEMORY_COUNT" -gt 0 ] && [ -n "$MEMORY_INDEX" ] && [ -f "$MEMORY_INDEX" ]; then
      REFERENCED=$(grep -cE '^[[:space:]]*-[[:space:]]*\[.*\.md\]' "$MEMORY_INDEX" 2>/dev/null) || REFERENCED=0
      MEMORY_WARN=""
      [ "$MEMORY_COUNT" -gt "$REFERENCED" ] 2>/dev/null && MEMORY_WARN=$'\xe2\x9a\xa0'
      MEMORY_LINK="$(dirname "$MEMORY_INDEX")"
      MEMORY_LABEL="Memory (${MEMORY_COUNT}${MEMORY_WARN})"
    fi
  fi

  # --- IDE URL 자동 감지 (옵션 C, HEAVY) ---
  # macOS LaunchServices 의 source-code default handler → IDE URL template.
  # env override 와 무관하게 산출/캐시하고, 최종 우선순위 결정 (env > detected >
  # vscode default) 은 cwd URL 생성부 (build_cwd_url 호출 직전) 에서 한다 — 그래야
  # 사용자가 env 를 켜고 끄더라도 캐시된 detected 값이 그대로 재사용된다.
  IDE_TEMPLATE_DETECTED=$(detect_macos_ide_template)

  # --- HEAVY 캐시 persist ---
  # SIDECAR_IO_ENABLED 통과 시에만 .vars / mtime 직렬화. CACHED_CWD 는 raw $CWD
  # (canonicalize 이전 시점, cd 직후 cwd 변화 즉시 감지 목적).
  if $SIDECAR_IO_ENABLED && [ -n "$HEAVY_STATE" ]; then
    vars_tmp=$(mktemp "${HEAVY_STATE}.vars.XXXXXX" 2>/dev/null) || vars_tmp=""
    if [ -n "$vars_tmp" ]; then
      if printf 'PLAN_FILE=%q\nMEMORY_LINK=%q\nMEMORY_LABEL=%q\nIS_WORKTREE=%q\nGIT_BRANCH=%q\nMAIN_REPO_DIR=%q\nIDE_TEMPLATE_DETECTED=%q\nSYNC_AHEAD=%q\nSYNC_BEHIND=%q\nSYNC_HAS_UPSTREAM=%q\nSYNC_COMMIT_ADD=%q\nSYNC_COMMIT_DEL=%q\nSYNC_DIRTY_ADD=%q\nSYNC_DIRTY_DEL=%q\nSYNC_GIT_STATUS=%q\nCACHED_CWD=%q\n' \
          "$PLAN_FILE" "$MEMORY_LINK" "$MEMORY_LABEL" "$IS_WORKTREE" "$GIT_BRANCH" "$MAIN_REPO_DIR" "$IDE_TEMPLATE_DETECTED" "$SYNC_AHEAD" "$SYNC_BEHIND" "$SYNC_HAS_UPSTREAM" "$SYNC_COMMIT_ADD" "$SYNC_COMMIT_DEL" "$SYNC_DIRTY_ADD" "$SYNC_DIRTY_DEL" "$SYNC_GIT_STATUS" "${CWD:-}" \
          > "$vars_tmp" 2>/dev/null && mv "$vars_tmp" "${HEAVY_STATE}.vars" 2>/dev/null; then
        chmod 600 "${HEAVY_STATE}.vars" 2>/dev/null || true
        # mtime stamp 파일 — TTL 비교의 기준.
        : > "$HEAVY_STATE" 2>/dev/null || true
        chmod 600 "$HEAVY_STATE" 2>/dev/null || true
      else
        rm -f "$vars_tmp" 2>/dev/null || true
      fi
    fi
  fi
fi

# --- cwd display + IDE URL ---
# display 는 worktree 일 때 "<main repo basename>:<현 worktree basename>" 로
# 합성. 일반 (main repo) 일 때는 tilde_shorten 만 적용. SSH 환경에서는 OSC 8
# 클릭 불가 → CWD_URL 빈 문자열 (print_icon 가 텍스트 분기로 fallback).
#
# IDE URL scheme 우선순위 (issue #293):
#   (A) CLAUDE_STATUSLINE_IDE_URL_TEMPLATE env override — validate 통과 시 최우선.
#   (C) IDE_TEMPLATE_DETECTED — macOS LaunchServices 자동 감지 (HEAVY 캐시 복원).
#   (fallback) vscode://file%s/?windowId=_blank — 현행 보존 (backward compat).
# env 는 캐시 독립적으로 즉시 반영되도록 여기서 매 호출 재평가한다.
IDE_URL_TEMPLATE="vscode://file%s/?windowId=_blank"
_ide_env_tmpl=$(validate_ide_url_template "${CLAUDE_STATUSLINE_IDE_URL_TEMPLATE:-}") || _ide_env_tmpl=""
if [ -n "$_ide_env_tmpl" ]; then
  IDE_URL_TEMPLATE="$_ide_env_tmpl"
elif _ide_cfg_tmpl=$(read_ide_config_template); [ -n "$_ide_cfg_tmpl" ]; then
  # 옵션 B — ~/.claude/statusline-ide-template (installer 가 저장). env 다음,
  # 자동 감지 앞. read_ide_config_template 이 validate 통과 시만 채택한다.
  IDE_URL_TEMPLATE="$_ide_cfg_tmpl"
elif [ -n "${IDE_TEMPLATE_DETECTED:-}" ]; then
  # detected 값도 validate 재통과 — light run 의 HEAVY .vars source 복원 경로가
  # env 경로와 동일한 검증을 받도록 대칭성 확보 (chmod 600 .vars 변조 대비
  # defense-in-depth). 미통과 시 vscode default 유지.
  _ide_detected_tmpl=$(validate_ide_url_template "$IDE_TEMPLATE_DETECTED") || _ide_detected_tmpl=""
  [ -n "$_ide_detected_tmpl" ] && IDE_URL_TEMPLATE="$_ide_detected_tmpl"
  unset _ide_detected_tmpl
fi
unset _ide_env_tmpl _ide_cfg_tmpl

CWD_DISPLAY=""
CWD_URL=""
if [ -n "$CWD_RESOLVED" ]; then
  if $IS_WORKTREE && [ -n "$MAIN_REPO_DIR" ]; then
    CWD_DISPLAY="$(tilde_shorten "$MAIN_REPO_DIR"):$(basename "$CWD_RESOLVED")"
  else
    CWD_DISPLAY=$(tilde_shorten "$CWD_RESOLVED")
  fi
  if ! $IS_SSH; then
    CWD_URL=$(build_cwd_url "$CWD_RESOLVED" "$IDE_URL_TEMPLATE")
  fi
fi

# --- 🌿 branch 라벨 OSC 8 URL (cwd IDE URL 과 대칭, 기본 비활성) ---
# CLAUDE_STATUSLINE_BRANCH_URL_TEMPLATE env 가 validate_ide_url_template 를 통과
# (control char 차단 / `%s` 필수 / scheme:// 형식) 하고, branch 가 있고, SSH 가
# 아닐 때만 build_cwd_url 로 OSC 8 URL 을 만든다. cwd 와 동일하게 CWD_RESOLVED
# (현 위치 — worktree 면 그 worktree) 를 `%s` 로 주입해, 클릭 시 현재 작업 트리의
# git UI (예: lazygit) 로 진입한다. 미설정/SSH/non-git 이면 BRANCH_URL 이 빈
# 문자열 → print_icon 이 plain text 분기로 fallback 해 현행과 동일 (하위호환).
# 신규 검증/생성 헬퍼를 만들지 않고 cwd IDE URL 인프라를 그대로 재사용한다.
BRANCH_URL=""
# 기본 비활성(env 미설정)·non-git·SSH 는 validate subshell 자체를 건너뛴다 — 대다수
# (env 미설정) 경로에서 매 렌더의 command substitution 1회를 절약한다. cwd IDE URL 과
# 달리 fallback chain 이 없어 env guard 를 validate 앞에 둘 수 있다.
if [ -n "${CLAUDE_STATUSLINE_BRANCH_URL_TEMPLATE:-}" ] && [ -n "$GIT_BRANCH" ] && ! $IS_SSH; then
  _branch_tmpl=$(validate_ide_url_template "$CLAUDE_STATUSLINE_BRANCH_URL_TEMPLATE") || _branch_tmpl=""
  [ -n "$_branch_tmpl" ] && BRANCH_URL=$(build_cwd_url "$CWD_RESOLVED" "$_branch_tmpl")
  unset _branch_tmpl
fi

# --- Status icons 읽기 ---
# SessionStart hook이 ~/.claude/status-icons/<session-id>.json을 생성한다.
# ICONS_FILE 경로 구성은 SIDECAR_IO_ENABLED 통과 시에만 진행.
JIRA_URL="" JIRA_LABEL=""
SLACK_URL="" SLACK_LABEL=""
FIGMA_URL="" FIGMA_LABEL=""
MEMO_PATH="" MEMO_LABEL=""

if $SIDECAR_IO_ENABLED; then
  ICONS_FILE="$HOME/.claude/status-icons/$SESSION_ID.json"
  if [ -f "$ICONS_FILE" ]; then
    eval "$(jq -r '
      @sh "JIRA_URL=\(.jira.url // "")",
      @sh "JIRA_LABEL=\(.jira.label // "")",
      @sh "SLACK_URL=\(.slack.url // "")",
      @sh "SLACK_LABEL=\(.slack.label // "")",
      @sh "FIGMA_URL=\(.figma.url // "")",
      @sh "FIGMA_LABEL=\(.figma.label // "")",
      @sh "MEMO_PATH=\(.memo.path // "")",
      @sh "MEMO_LABEL=\(.memo.label // "")"
    ' "$ICONS_FILE" 2>/dev/null)" 2>/dev/null || true
  fi
fi

# 아이콘 / rate / cwd / worktree(branch) / plan / memory / session-id 가 모두
# 비어있으면 출력할 게 없음. 그 중 하나라도 있으면 해당 라인(session-id 전용 줄·
# branch 인라인 포함)이 출력되므로 early exit 하지 않는다.
if [ -z "$JIRA_URL" ] && [ -z "$SLACK_URL" ] && [ -z "$FIGMA_URL" ] && [ -z "$MEMO_PATH" ] \
   && [ -z "$RATE_5H" ] && [ -z "$RATE_7D" ] && [ -z "$CWD_DISPLAY" ] \
   && [ -z "$PLAN_FILE" ] && [ -z "$MEMORY_LINK" ] \
   && [ -z "$SESSION_ID" ] && [ -z "$GIT_BRANCH" ]; then
  exit 0
fi

# --- 라인 구조 추상화: begin_line / end_line / LINE_HAS_OUTPUT ---
# 멀티 라인 출력의 각 라인을 독립적으로 다루기 위한 상태 헬퍼. begin_line 으로
# 라인 시작 (LINE_HAS_OUTPUT=false reset), print_icon 호출이 누적되며 출력하면
# LINE_HAS_OUTPUT=true 로 표시, end_line 에서 한 번이라도 출력이 있었을 때만
# 줄바꿈을 emit. 출력이 없었던 라인은 빈 줄을 남기지 않는다.
LINE_HAS_OUTPUT=false
begin_line() { LINE_HAS_OUTPUT=false; }
end_line()   { $LINE_HAS_OUTPUT && printf '\n'; }

# --- print_icon: 아이콘 하나 출력 ---
# $1=color $2=url (빈 문자열이면 OSC 8 생략) $3=emoji_bytes $4=label
# OSC 8 분기에서 escape sequence (\e/\a) 와 URL/label 를 %b/%s/%b 3-단으로
# 분리해 URL/label 의 `%` 문자가 printf format 해석을 트리거하지 않도록 한다.
# label 은 sidecar JSON 에서 untrusted 로 들어오므로 sanitize_display_text 로
# control char 를 제거해 OSC 8 escape injection (e.g. \e]8;;evil\aTEXT\e]8;;\a)
# 를 통한 hyperlink hijacking 을 차단한다.
# 같은 라인에 두 번째 이상 호출되면 앞에 2-space 구분자를 삽입한다.
print_icon() {
  local color=$1 url=$2 emoji=$3 label=$4
  url=$(sanitize_osc8_url "$url")
  label=$(sanitize_display_text "$label")
  $LINE_HAS_OUTPUT && printf '  '
  if [ -n "$url" ] && $IS_SSH; then
    # SSH(Termius 등): OSC 8 미지원 + Claude Code Ink 유실로 하이퍼링크 클릭 불가.
    # 평문 URL을 라벨 뒤에 출력해 SSH 클라이언트의 URL regex 감지에 맡긴다.
    # url 은 위에서 sanitize_osc8_url 을 거친 값 — control 문자가 있으면 통째로 비워지고,
    # 빈 값이면 위 `[ -n "$url" ]` 가드에서 이 분기에 진입하지 못한다. 즉 여기 도달한 url 은
    # control 문자가 없음이 보장되어 escape 주입 방어가 유지된다. label 은 위에서
    # sanitize_display_text 로 control char 가 제거되었다.
    printf '%b' "\e[${color}m${emoji} "
    printf '%s' "$label"
    printf '%b' "\e[0m "
    printf '%s' "$url"
  elif [ -n "$url" ]; then
    printf '%b' "\e[4;${color}m\e]8;;"
    printf '%s' "$url"
    printf '%b' "\a"
    printf '%b' "${emoji} "
    printf '%s' "$label"
    printf '%b' "\e]8;;\a\e[0m"
  else
    printf '%b' "\e[${color}m${emoji} "
    printf '%s' "$label"
    printf '%b' "\e[0m"
  fi
  LINE_HAS_OUTPUT=true
}

# --- render_branch_sync: branch 라벨 뒤 @{upstream} 동기화 표기 ---
# print_icon 으로 출력된 branch 라벨 바로 뒤에 이어 붙인다 (각 요소 앞 단일 space
# — print_icon 의 2-space segment 구분과 달리 branch 의 종속 정보임을 시각 표현).
# $1=detail (폭 단계 1~4). progressive disclosure (넓음→좁음):
#   detail>=2: [심볼] git_status + ↑ahead ↓behind (파일 상태/동기화 핵심 — 끝까지 유지)
#   detail>=4: +X/-Y          (push 대기 커밋 diff — 폭 여유 시. dirty 보다 먼저 버림)
#   detail>=3: (+X/-Y)        (uncommitted dirty — 즉각적 관심이라 커밋diff 보다 오래 유지)
# 표시 순서는 [심볼] git_status → ahead/behind → 커밋diff → dirty (이슈 #296 정렬). 색상:
#   ahead 32 green / behind 33 yellow / 커밋diff·dirty 모두 +녹 -적 (diff 가독성).
#   dirty 는 (cyan) 괄호로 push 대기 커밋 diff 와 구별한다 (아직 커밋 안 된 임시 변경).
# upstream 미설정 (SYNC_HAS_UPSTREAM=false) → ahead/behind/커밋diff 생략, [심볼] git_status 와 dirty 는 표시.
# 숫자/glyph 텍스트라 OSC 8 URL 이 아니므로 SSH 분기 불필요 (그대로 출력).
render_branch_sync() {
  local detail=${1:-1}
  [ "$detail" -ge 2 ] 2>/dev/null || return 0   # detail 1 (가장 좁음) → branch 만

  # ANSI 색상 — 이 함수 전용이라 local 명명 (MUTED 전역 상수와 같은 의도, 단 여기서만
  # 쓰여 전역 오염 없이 local). green / yellow / red / cyan.
  local c_ahead=32 c_behind=33 c_add=32 c_del=31 c_dirty=36

  # git_status 파일 상태 심볼 — branch 라벨 직후. starship git_status 와 동일한
  # 심볼/순서 (= $ ✘ » ! + ?) 를 red bold `[...]` 로 표기 (라인 diff 와 병행).
  # ahead/behind 는 아래 ↑↓ 로 별도 표시하므로 이 심볼 묶음에는 포함하지 않는다.
  [ -n "${SYNC_GIT_STATUS:-}" ] && printf ' %b[%s]%b' "\e[1;31m" "$SYNC_GIT_STATUS" "\e[0m"

  # ahead/behind — detail>=2, upstream 있을 때만, 0 은 생략.
  if $SYNC_HAS_UPSTREAM; then
    [ "${SYNC_AHEAD:-0}"  -gt 0 ] 2>/dev/null && printf ' %b\xe2\x86\x91%s%b' "\e[${c_ahead}m"  "$SYNC_AHEAD"  "\e[0m"
    [ "${SYNC_BEHIND:-0}" -gt 0 ] 2>/dev/null && printf ' %b\xe2\x86\x93%s%b' "\e[${c_behind}m" "$SYNC_BEHIND" "\e[0m"
  fi

  # 표시 순서상 push 대기 커밋 diff 가 dirty 보다 먼저 와야 해서 (위 progressive
  # disclosure 표 참조), 더 엄격한 detail>=4 블록을 detail>=3 블록보다 위에 둔다 —
  # 분기 임계가 역순(4 then 3)인 것은 출력 순서를 맞추기 위한 의도다.

  # push 대기 커밋 diff — detail>=4 (가장 넓을 때만), upstream + 0/0 아닐 때. +녹/-적.
  if [ "$detail" -ge 4 ] 2>/dev/null && $SYNC_HAS_UPSTREAM \
     && { [ "${SYNC_COMMIT_ADD:-0}" -gt 0 ] 2>/dev/null || [ "${SYNC_COMMIT_DEL:-0}" -gt 0 ] 2>/dev/null; }; then
    printf ' %b+%s%b/%b-%s%b' "\e[${c_add}m" "$SYNC_COMMIT_ADD" "\e[0m" "\e[${c_del}m" "$SYNC_COMMIT_DEL" "\e[0m"
  fi

  # dirty (uncommitted) — detail>=3, 0/0 생략. (cyan) 괄호로 push 대기 커밋 diff 와
  # 구별 (아직 커밋 안 된 임시 변경). 괄호 안 +녹/-적 은 커밋diff 와 동일.
  if [ "$detail" -ge 3 ] 2>/dev/null \
     && { [ "${SYNC_DIRTY_ADD:-0}" -gt 0 ] 2>/dev/null || [ "${SYNC_DIRTY_DEL:-0}" -gt 0 ] 2>/dev/null; }; then
    printf ' %b(%b+%s%b/%b-%s%b)%b' "\e[${c_dirty}m" "\e[${c_add}m" "$SYNC_DIRTY_ADD" "\e[0m" "\e[${c_del}m" "$SYNC_DIRTY_DEL" "\e[${c_dirty}m" "\e[0m"
  fi
}

# --- rate_color: 사용률 → ANSI 색상 코드 ---
# <50 green, 50-79 yellow, >=80 red
rate_color() {
  if [ "${1:-0}" -ge 80 ] 2>/dev/null; then echo "31"
  elif [ "${1:-0}" -ge 50 ] 2>/dev/null; then echo "33"
  else echo "32"
  fi
}

# --- format_remaining: 초 → XdYh / XhYYm / Xm ---
format_remaining() {
  local secs=${1:-0}
  if [ "$secs" -le 0 ] 2>/dev/null; then echo "0m"; return; fi
  local d=$((secs / 86400)) h=$(((secs % 86400) / 3600)) m=$(((secs % 3600) / 60))
  if [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
  else printf '%dm' "$m"
  fi
}

# --- _render_rate_bar_horizontal: 10-cell horizontal block bar ---
# 기존 render_rate_window 인라인 코드를 함수로 추출 (SSH vertical gauge 분기와
# 대칭 구조로). pct 가 0 이 아니면 최소 1셀 filled 보장 — 1~9% 가 빈 막대로
# 표시되어 0% 와 시각 구별 불가능해지는 회귀를 차단한다.
# pct 정규화 (decimal/clamp) 는 caller (render_rate_window) 가 책임진다.
_render_rate_bar_horizontal() {
  local pct=$1 color=$2 filled empty i bar_filled="" bar_empty=""
  filled=$((pct / 10))
  [ "$pct" -gt 0 ] 2>/dev/null && [ "$filled" -eq 0 ] && filled=1
  empty=$((10 - filled))
  for ((i=0; i<filled; i++)); do bar_filled+="█"; done
  for ((i=0; i<empty; i++)); do bar_empty+="░"; done
  printf '%b%s%b%s%b ' "\e[${color}m" "$bar_filled" "\e[${MUTED}m" "$bar_empty" "\e[0m"
}

# --- _render_rate_bar_ssh_vertical: SSH 환경 3-cell vertical glyph gauge ---
# pct → idx 산식: `idx = (pct==0)?0 : ((pct-1)*8/100 + 1)`, cap 8.
# Boundary rationale: naive `pct*8/100` 은 pct=1..12 에서 idx=0 으로 떨어져
# 0% 와 시각 구별 불가능. `((pct-1)*8/100 + 1)` 로 1% 이상은 항상 idx>=1 보장,
# 100% 는 (99*8/100+1)=8 으로 cap. 출력은 `▏<glyph>▕` 3-cell 압축 — 좁은
# 터미널에서 wrap 회귀 차단.
# pct 정규화는 caller 책임.
_render_rate_bar_ssh_vertical() {
  local pct=$1 color=$2 idx core
  if [ "$pct" -eq 0 ] 2>/dev/null; then
    idx=0
  else
    idx=$(((pct - 1) * 8 / 100 + 1))
    [ "$idx" -gt 8 ] 2>/dev/null && idx=8
  fi
  if [ "$idx" -eq 0 ]; then
    core=" "
  else
    core="${SSH_BAR_GLYPHS[$idx]}"
  fi
  printf '%b▏%b%s%b▕%b ' "\e[${MUTED}m" "\e[${color}m" "$core" "\e[${MUTED}m" "\e[0m"
}

# --- render_rate_window: progress bar + 퍼센트 + 잔여 + 리셋 시각 ---
# $1=pct $2=window $3=resets_at $4=now $5=detail (1-4)
render_rate_window() {
  local pct=${1:-0} window=$2 resets_at=$3 now=$4 detail=${5:-4}
  pct=${pct%%.*}
  pct=${pct:-0}
  [ "$pct" -lt 0 ] 2>/dev/null && pct=0
  [ "$pct" -gt 100 ] 2>/dev/null && pct=100
  local color
  color=$(rate_color "$pct")

  if [ "$detail" -ge 2 ]; then
    if $IS_SSH; then
      _render_rate_bar_ssh_vertical "$pct" "$color"
    else
      _render_rate_bar_horizontal "$pct" "$color"
    fi
  fi

  printf '%b%s%b %s' "\e[${color}m" "${pct}%" "\e[0m" "$window"

  if [ -n "$resets_at" ] && [ "$resets_at" -gt 0 ] 2>/dev/null; then
    if [ "$detail" -ge 3 ]; then
      local remaining=$((resets_at - now))
      if [ "$remaining" -gt 0 ]; then
        printf ' %b%s%b %s' "\e[${MUTED}m" "→" "\e[0m" "$(format_remaining $remaining)"
      fi
    fi
    if [ "$detail" -ge 4 ]; then
      local reset_fmt
      reset_fmt=$(date -r "$resets_at" "+%m/%d %H:%M" 2>/dev/null \
               || date -d "@$resets_at" "+%m/%d %H:%M" 2>/dev/null)
      [ -n "$reset_fmt" ] && printf ' %b(%s)%b' "\e[${MUTED}m" "$reset_fmt" "\e[0m"
    fi
  fi
}

# --- L1: Status icons (있을 때만) ---
# Jira / Slack / Figma / Memo. begin_line/end_line 으로 wrap 하여 아이콘이
# 하나도 없으면 빈 줄을 남기지 않는다.
begin_line
# Jira: yellow ⚡ (SSH에서는 print_icon이 평문 URL로 출력)
if [ -n "$JIRA_URL" ] && [ -n "$JIRA_LABEL" ]; then
  print_icon "33" "$JIRA_URL" "\xe2\x9a\xa1" "$JIRA_LABEL"
fi

# Slack: magenta 💬 (SSH에서는 print_icon이 평문 URL로 출력)
if [ -n "$SLACK_URL" ] && [ -n "$SLACK_LABEL" ]; then
  print_icon "35" "$SLACK_URL" "\xf0\x9f\x92\xac" "$SLACK_LABEL"
fi

# Figma: red 🎨 (SSH에서는 print_icon이 평문 URL로 출력)
if [ -n "$FIGMA_URL" ] && [ -n "$FIGMA_LABEL" ]; then
  print_icon "31" "$FIGMA_URL" "\xf0\x9f\x8e\xa8" "$FIGMA_LABEL"
fi

# Memo: green 📓 (SSH에서는 링크 없이 텍스트만).
# file:// URL 은 percent_encode_segment 로 path 를 인코딩 (한글/공백 등
# UTF-8 byte safe). control char 가 섞이면 sanitize_osc8_url 에서 차단되므로
# print_icon 이 자동으로 URL-less 분기로 fallback.
if [ -n "$MEMO_PATH" ] && [ -f "$MEMO_PATH" ]; then
  if $IS_SSH; then
    MEMO_URL=""
  else
    MEMO_URL="file://$(percent_encode_segment "$MEMO_PATH")"
  fi
  print_icon "32" "$MEMO_URL" "\xf0\x9f\x93\x93" "${MEMO_LABEL:-Memo}"
fi
end_line

# --- 공용 폭(detail) 계산: branch sync (L2) + rate (L_N) 공유 ---
# progressive disclosure 단계를 L2 렌더 앞에서 1회 산출해 공용화한다. 기존에는
# L_N rate 블록 안에서만 계산했으나, branch sync 도 같은 폭 기준으로 축약하므로
# L2 앞으로 끌어올려 공용화한다 (rate 블록은 WIDTH_DETAIL 재사용 — 중복 계산 제거).
# 산식/임계값은 기존 rate 로직 그대로: EFF_COLS = COLS<MIN_COLS_FOR_RESERVE ? COLS
# : COLS-RIGHT_RESERVE_COLS, detail 4(EFF>=88) / 3(>=58) / 2(>=40) / 1(그 외).
COLS=$(resolve_raw_terminal_cols)
RIGHT_RESERVE_COLS=40
# 이 폭 미만이면 우측 예약폭(RIGHT_RESERVE_COLS) 차감을 생략한다 — 좁은 화면에서
# EFF_COLS 가 음수/과소로 떨어지는 것을 막는 floor (RIGHT_RESERVE_COLS 와 연동).
MIN_COLS_FOR_RESERVE=80
DETAIL_THRESHOLD_4=88
DETAIL_THRESHOLD_3=58
DETAIL_THRESHOLD_2=40
if [ "$COLS" -lt "$MIN_COLS_FOR_RESERVE" ]; then
  EFF_COLS=$COLS
else
  EFF_COLS=$((COLS - RIGHT_RESERVE_COLS))
fi
if   [ "$EFF_COLS" -ge "$DETAIL_THRESHOLD_4" ]; then WIDTH_DETAIL=4
elif [ "$EFF_COLS" -ge "$DETAIL_THRESHOLD_3" ]; then WIDTH_DETAIL=3
elif [ "$EFF_COLS" -ge "$DETAIL_THRESHOLD_2" ]; then WIDTH_DETAIL=2
else WIDTH_DETAIL=1
fi

# --- L2: cwd + branch (worktree·비-worktree 공통, 단일 라인) ---
# cwd 가 있을 때 📁 cyan 으로 출력. CWD_URL (IDE URL template — env override /
# macOS 자동 감지 / vscode default) 로 OSC 8 hyperlink → 사용자 IDE 진입 가능.
# SSH 환경에서는 CWD_URL 이 빈 문자열이라 print_icon 자동으로 URL-less 분기로
# fallback (텍스트만). branch 가 있으면 같은 줄에 🌿 green 으로 병기하고 그 뒤에
# render_branch_sync 로 동기화 표기를 잇는다.
#
# worktree 도 main repo 와 동일하게 cwd 와 같은 줄에 branch 를 인라인으로 병기한다
# (별도 L3 라인/줄바꿈 없음). worktree 디렉토리명이 branch 와 같더라도 🌿 라벨을
# 생략하지 않는다 (과거 basename guard 제거) — cwd display 의 "<repo>:<basename>"
# 합성과 branch 라벨은 서로 다른 정보(현 위치 vs 체크아웃된 branch)라, 디렉토리명이
# 우연히 branch 와 같다는 이유로 branch 표시를 숨기면 main repo 와의 일관성이 깨진다.
# git 표시/동작을 worktree 에서도 main repo 와 동일하게 맞추는 것이 의도다.
# detached HEAD / non-git 은 GIT_BRANCH 가 비어 branch 분기를 건너뛴다 (cwd 만).
begin_line
if [ -n "$CWD_DISPLAY" ]; then
  print_icon "36" "$CWD_URL" "\xf0\x9f\x93\x81" "$CWD_DISPLAY"
fi
if [ -n "$GIT_BRANCH" ]; then
  print_icon "32" "$BRANCH_URL" "\xf0\x9f\x8c\xbf" "$GIT_BRANCH"
  render_branch_sync "$WIDTH_DETAIL"
fi
end_line

# --- L_M: Plan 📝 + Memory 🧠 ---
# Plan path 가 감지됐으면 cyan-purple 계열로 표시 + file:// URL OSC 8.
# Memory link 가 있으면 같은 라인에 brain emoji + Memory(N⚠) 라벨.
begin_line
if [ -n "$PLAN_FILE" ]; then
  PLAN_NAME=$(basename "$PLAN_FILE" .md)
  if $IS_SSH; then
    PLAN_URL=""
  else
    PLAN_URL="file://$(percent_encode_segment "$PLAN_FILE")"
  fi
  # 35 magenta — plan 임을 시각적으로 구분 (cwd 36 cyan, branch 32 green).
  # 라벨은 "플랜(제목: <파일명>)" 으로 감싼다 — basename 원문만 노출하면 이 plugin
  # 동작을 모르는 사람은 이게 plan 파일인지 알 수 없으므로 의미를 명시한다.
  # sanitize_display_text 가 control char 만 제거하므로 한글/괄호/콜론은 보존된다.
  print_icon "35" "$PLAN_URL" "\xf0\x9f\x93\x9d" "플랜(제목: $PLAN_NAME)"
fi
if [ -n "$MEMORY_LINK" ]; then
  if $IS_SSH; then
    MEMORY_URL=""
  else
    MEMORY_URL="file://$(percent_encode_segment "$MEMORY_LINK")"
  fi
  # 33 yellow — memory orphan warning 가독성.
  print_icon "33" "$MEMORY_URL" "\xf0\x9f\xa7\xa0" "${MEMORY_LABEL:-Memory}"
fi
end_line

# --- L_SID: session-id (rate 바로 위 전용 줄) ---
# 항상 전체 session_id 를 표시한다 (축약 없음). 이 줄에는 session_id 외 어떤
# 아이콘/정보도 병렬 출력하지 않는다 — begin/end_line 으로 격리된 전용 줄이다.
# 🆔 prefix 로 session-id 임을 명시한다. 비-SSH + CWD 확정 시 hammerspoon:// 클릭
# 링크(아래)를 부착하고, SSH 또는 CWD 미확정 시 URL-less 텍스트로 출력한다. SESSION_ID 는
# validate_session_id 통과 값이고 print_icon 이 sanitize_display_text 로 한 번 더
# control char 를 제거한다. rate(L_N) 가 가장 긴 줄이라 항상 최하단에 고정하기
# 위해 session-id 는 그 바로 위에 둔다.
begin_line
if [ -n "$SESSION_ID" ]; then
  # 비-SSH + CWD 확정 시, 클릭하면 'cd <cwd> && c --resume=<SID> --fork-session' 을
  # 클립보드에 복사하는 hammerspoon:// OSC 8 링크를 부착한다 (init.lua 의
  # hs.urlevent.bind("claude-fork", ...) 가 cmd 를 디코드해 hs.pasteboard.setContents).
  # claude --resume --fork-session 은 세션 시작 cwd 에서 실행해야 하므로 cd 를 앞에 붙인다.
  # SSH(또는 CWD 미확정) 시 SID_URL 이 빈 값이라 print_icon 이 URL-less 텍스트 분기로
  # fallback 한다 (SSH 는 OSC 8 클릭 불가).
  # 보안: 클립보드 명령은 사용자가 붙여넣어 셸에서 실행하므로 cwd/SID 를 printf %q 로
  # 셸-quote 한다 — cwd 디렉토리명의 따옴표/$()/백틱 등이 cd "..." 를 탈출해 임의 명령으로
  # 실행되는 인젝션을 차단한다. SID 는 --resume=<SID> attached form 으로 넘겨 '-' 로
  # 시작하는 SID 가 옵션으로 오인되지 않게 한다.
  SID_URL=""
  if ! $IS_SSH && [ -n "$CWD_RESOLVED" ]; then
    SID_FORK_CMD="cd $(printf '%q' "$CWD_RESOLVED") && c --resume=$(printf '%q' "$SESSION_ID") --fork-session"
    SID_URL="hammerspoon://claude-fork?cmd=$(percent_encode_segment "$SID_FORK_CMD")"
  fi
  print_icon "$MUTED" "$SID_URL" "\xf0\x9f\x86\x94" "$SESSION_ID"
fi
end_line

# --- L_N: Rate Limits (progressive disclosure) ---
if [ -n "$RATE_5H" ] || [ -n "$RATE_7D" ]; then
  # 폭(detail) 은 위 공용 블록에서 산출한 WIDTH_DETAIL 재사용 (L2 branch sync
  # 와 동일 기준). progressive disclosure 단계별 표시량은 render_rate_window 가
  # detail 인자로 제어한다.
  if [ -n "$RATE_5H" ]; then
    render_rate_window "$RATE_5H" "5h" "$RATE_5H_RESET" "$NOW" "$WIDTH_DETAIL"
  fi
  if [ -n "$RATE_5H" ] && [ -n "$RATE_7D" ]; then
    printf ' %b%s%b ' "\e[${MUTED}m" "|" "\e[0m"
  fi
  if [ -n "$RATE_7D" ]; then
    render_rate_window "$RATE_7D" "7d" "$RATE_7D_RESET" "$NOW" "$WIDTH_DETAIL"
  fi
  printf '\n'
fi

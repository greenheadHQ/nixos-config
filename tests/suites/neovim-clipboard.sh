# shellcheck shell=bash
# SC2154: REPO_ROOT·new_sandbox·fail·assert_*는 aggregator가 test-common.sh를 먼저 source한 뒤
#   이 파일을 source해 정의한다(shellcheck는 이 순서를 모른다).
# shellcheck disable=SC2154
# tests/suites/neovim-clipboard.sh — nvim 클립보드 provider 선택과 SSH 붙여넣기 (#1453)
#
# 배포되는 options.lua를 headless nvim(--clean)에 그대로 읽힌다. OS는 has('mac')의 답을 바꿔
# 주입하므로 Mac에서도 Linux(MiniPC) 경로를 확인할 수 있다. 그래서 options.lua의 macOS 판정은
# has('mac')를 써야 이 fixture가 성립한다. provider#clipboard#Executable()의 macOS 분기는
# vimscript의 실제 has('mac')를 보므로, 판정 결과는 g:clipboard 값으로 확인한다.
# 터미널로 나가는 OSC 52 시퀀스는 nvim_ui_send를 가로채 기록한다. headless에는 터미널이 없어
# 실제 클립보드에 닿는지는 확인하지 못한다.

_NVIM_CLIPBOARD_OPTIONS="modules/shared/programs/neovim/files/nvim/lua/config/options.lua"

# nvim이 없으면 SKIP 사유를 내고 1을 돌려준다. required CI는 prePushRuntime의 nvim을 쓴다.
_nvim_clipboard_require_nvim() {
  command -v nvim >/dev/null 2>&1 && return 0
  echo "SKIP: $1 requires nvim; run 'bash scripts/ai/test-runtime-profile.sh run \"$REPO_ROOT\" -- bash tests/run-shell-script-tests.sh'" >&2
  return 1
}

_nvim_clipboard_write_probe() {
  cat >"$1/probe.lua" <<'EOF'
local real_has = vim.fn.has
vim.fn.has = function(feature)
  if feature == "mac" then
    return vim.env.NVIM_CLIPBOARD_PROBE_OS == "mac" and 1 or 0
  end
  return real_has(feature)
end
local sent = {}
vim.api.nvim_ui_send = function(data)
  sent[#sent + 1] = data
end

dofile(arg[1])

local function emit(key, value)
  io.stdout:write(key .. "=" .. value .. "\n")
end
emit("clipboard", vim.o.clipboard)
local cb = vim.g.clipboard
if cb == nil then
  emit("g_clipboard", "unset")
  return
end
emit("g_clipboard", tostring(cb.name))
emit("provider", vim.fn["provider#clipboard#Executable"]())

vim.fn.setreg("+", { "plus 1", "plus 2" }, "V")
vim.fn.setreg("*", "star", "v")
emit("paste_plus", vim.fn.json_encode({ vim.fn.getreg("+", 1, 1), vim.fn.getregtype("+") }))
emit("paste_star", vim.fn.json_encode({ vim.fn.getreg("*", 1, 1), vim.fn.getregtype("*") }))
-- 'clipboard'가 비면 provider 자체 캐시로 regtype을 되살리지 않는다(LazyVim은 VeryLazy 전까지 비운다).
vim.o.clipboard = ""
vim.fn.setreg("+", { "ab", "cd" }, "\022")
emit("paste_block", vim.fn.json_encode({ vim.fn.getreg("+", 1, 1), vim.fn.getregtype("+") }))
vim.o.clipboard = "unnamedplus"
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "line" })
vim.cmd("normal! yyp")
emit("buffer", vim.fn.json_encode(vim.api.nvim_buf_get_lines(0, 0, -1, false)))
for _, data in ipairs(sent) do
  emit("sent", (data:gsub("\027\\", "<ST>"):gsub("\027", "<ESC>")))
end
EOF
}

# _nvim_clipboard_probe SANDBOX OS [VAR=VALUE...]
# options.lua를 읽힌 nvim의 판정 결과를 key=value 줄로 SANDBOX/out에 쓴다. SSH·tmux 변수는
# 모두 지운 뒤 인자로 준 것만 넣는다. OS는 mac 또는 linux다.
_nvim_clipboard_probe() {
  local sandbox="$1" os="$2"
  shift 2
  env -u SSH_CONNECTION -u SSH_TTY -u TMUX \
    XDG_CONFIG_HOME="$sandbox/config" XDG_DATA_HOME="$sandbox/data" \
    XDG_STATE_HOME="$sandbox/state" XDG_CACHE_HOME="$sandbox/cache" \
    NVIM_CLIPBOARD_PROBE_OS="$os" "$@" \
    nvim --clean --headless -i NONE -n -l "$sandbox/probe.lua" "$REPO_ROOT/$_NVIM_CLIPBOARD_OPTIONS" \
    >"$sandbox/out" 2>"$sandbox/err" ||
    fail "nvim probe failed ($os $*): $(cat "$sandbox/err")"
}

test_neovim_clipboard_osc52_only_for_linux_ssh_outside_tmux() {
  _nvim_clipboard_require_nvim "neovim clipboard provider selection" || return 0
  local sandbox ssh_var
  sandbox="$(new_sandbox)"
  _nvim_clipboard_write_probe "$sandbox"

  # tmux 밖 SSH(Linux): SSH_CONNECTION과 SSH_TTY 중 하나만 있어도 OSC 52 dict를 쓴다.
  for ssh_var in SSH_CONNECTION SSH_TTY; do
    _nvim_clipboard_probe "$sandbox" linux "$ssh_var=probe"
    assert_file_contains "$sandbox/out" "clipboard=unnamedplus"
    assert_file_contains "$sandbox/out" "g_clipboard=OSC 52 (copy only)"
    assert_file_contains "$sandbox/out" "provider=OSC 52 (copy only)"
  done

  # tmux 안 SSH: nvim 내장 tmux provider가 고르도록 g:clipboard를 두지 않는다.
  _nvim_clipboard_probe "$sandbox" linux SSH_CONNECTION=probe SSH_TTY=probe TMUX=/tmp/probe,1,0
  [[ "$(cat "$sandbox/out")" == $'clipboard=unnamedplus\ng_clipboard=unset' ]] ||
    fail "SSH inside tmux must keep the built-in provider selection: $(cat "$sandbox/out")"

  # SSH가 아닌 Linux: 기존 자동 선택을 그대로 둔다.
  _nvim_clipboard_probe "$sandbox" linux
  [[ "$(cat "$sandbox/out")" == $'clipboard=unnamedplus\ng_clipboard=unset' ]] ||
    fail "non-SSH session must keep the built-in provider selection: $(cat "$sandbox/out")"

  # macOS: SSH로 들어온 세션도 pbcopy를 그대로 쓴다.
  _nvim_clipboard_probe "$sandbox" mac SSH_CONNECTION=probe SSH_TTY=probe
  [[ "$(cat "$sandbox/out")" == $'clipboard=unnamedplus\ng_clipboard=unset' ]] ||
    fail "macOS SSH session must keep pbcopy: $(cat "$sandbox/out")"
}

test_neovim_ssh_clipboard_paste_returns_last_copy_without_query() {
  _nvim_clipboard_require_nvim "neovim SSH clipboard paste" || return 0
  local sandbox
  sandbox="$(new_sandbox)"
  _nvim_clipboard_write_probe "$sandbox"

  _nvim_clipboard_probe "$sandbox" linux SSH_CONNECTION=probe SSH_TTY=probe
  # 붙여넣기는 레지스터별 마지막 복사 내용과 그 regtype을 돌려준다.
  assert_file_contains "$sandbox/out" 'paste_plus=[["plus 1", "plus 2"], "V"]'
  assert_file_contains "$sandbox/out" 'paste_star=[["star"], "v"]'
  # blockwise(<C-V> 너비 2)도 regtype째 돌려준다.
  assert_file_contains "$sandbox/out" 'paste_block=[["ab", "cd"], "\u00162"]'
  # clipboard=unnamedplus에서 yy → p가 provider를 거쳐 같은 줄을 붙여넣는다.
  assert_file_contains "$sandbox/out" 'buffer=["line", "line"]'
  # 복사 네 번만 OSC 52 쓰기로 나가고, 붙여넣기는 터미널에 읽기 요청(52;c;?)을 보내지 않는다.
  # base64: "plus 1\nplus 2\n", "star", "ab\ncd\n", "line\n". <ST>는 ESC \ 종결 시퀀스다.
  [[ "$(grep '^sent=' "$sandbox/out")" == "$(printf '%s\n' \
    'sent=<ESC>]52;c;cGx1cyAxCnBsdXMgMgo=<ST>' \
    'sent=<ESC>]52;p;c3Rhcg==<ST>' \
    'sent=<ESC>]52;c;YWIKY2QK<ST>' \
    'sent=<ESC>]52;c;bGluZQo=<ST>')" ]] ||
    fail "expected only OSC 52 copy sequences: $(grep '^sent=' "$sandbox/out")"
}

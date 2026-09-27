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
# 같은 이유로 probe는 g:clipboard가 없으면 레지스터를 건드리지 않는다. 건드리면 Mac에서는
# 실제 pbcopy·pbpaste provider가 불려 호스트 클립보드를 덮어쓴다.
# 터미널로 나가는 OSC 52 시퀀스는 nvim_ui_send를 가로채 기록한다. headless에는 터미널이 없어
# 실제 클립보드에 닿는지는 확인하지 못한다.

_NVIM_CLIPBOARD_OPTIONS="modules/shared/programs/neovim/files/nvim/lua/config/options.lua"

# nvim이 없으면 SKIP 사유를 내고 1을 돌려준다. required CI는 prePushRuntime의 nvim을 쓴다.
_nvim_clipboard_require_nvim() {
  command -v nvim >/dev/null 2>&1 && return 0
  echo "SKIP: $1 requires nvim; run 'bash scripts/ai/test-runtime-profile.sh run \"$REPO_ROOT\" -- bash tests/run-shell-script-tests.sh'" >&2
  return 1
}

# probe 시나리오(NVIM_CLIPBOARD_PROBE_SCENARIO)
# - copy(기본): 레지스터별 복사와 붙여넣기, "+" → "*" 대체, yy → p
# - fresh: 복사 전 붙여넣기. 둘 다 빈 상태, 레지스터 0 대체(linewise·blockwise·charwise)
# - star-first: "*"만 복사한 뒤 "+" 붙여넣기
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
local function reg(name)
  return vim.fn.json_encode({ vim.fn.getreg(name, 1, 1), vim.fn.getregtype(name) })
end
local function buffer()
  return vim.fn.json_encode(vim.api.nvim_buf_get_lines(0, 0, -1, false))
end
emit("clipboard", vim.o.clipboard)
local cb = vim.g.clipboard
if cb == nil then
  emit("g_clipboard", "unset")
  return
end
emit("g_clipboard", tostring(cb.name))
emit("provider", vim.fn["provider#clipboard#Executable"]())

local scenario = vim.env.NVIM_CLIPBOARD_PROBE_SCENARIO or "copy"
if scenario == "copy" then
  vim.fn.setreg("+", { "plus 1", "plus 2" }, "V")
  emit("paste_star_from_plus", reg("*"))
  vim.fn.setreg("*", "star", "v")
  emit("paste_plus", reg("+"))
  emit("paste_star", reg("*"))
  -- 'clipboard'가 비면 provider 자체 캐시로 regtype을 되살리지 않는다(LazyVim은 VeryLazy 전까지 비운다).
  local configured = vim.o.clipboard
  vim.o.clipboard = ""
  vim.fn.setreg("+", { "ab", "cd" }, "\022")
  emit("paste_block", reg("+"))
  vim.o.clipboard = configured
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "line" })
  vim.cmd("normal! yyp")
  emit("buffer", buffer())
elseif scenario == "fresh" then
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x" })
  local ok, err = pcall(vim.cmd, "normal! p")
  emit("empty_p", ok and "ok" or (tostring(err):match("E%d+: .*") or tostring(err)))
  emit("empty_p_invalid_data", tostring(vim.fn.execute("messages"):find("invalid data", 1, true) ~= nil))
  emit("empty_buffer", buffer())
  -- 레지스터 0은 ShaDa가 되살리는 마지막 yank다. 빈 마지막 줄까지 linewise로 돌려준다.
  vim.fn.setreg("0", { "from shada", "" }, "V")
  emit("fallback_linewise", reg("+"))
  emit("fallback_star", reg("*"))
  vim.cmd("normal! p")
  emit("fallback_buffer", buffer())
  vim.fn.setreg("0", { "ab", "c" }, "b2")
  emit("fallback_block", reg("+"))
  vim.fn.setreg("0", "word", "v")
  emit("fallback_charwise", reg("+"))
elseif scenario == "star-first" then
  vim.fn.setreg("*", "star only", "v")
  emit("paste_plus_from_star", reg("+"))
end
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
  env -u SSH_CONNECTION -u SSH_TTY -u TMUX -u NVIM_CLIPBOARD_PROBE_SCENARIO \
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
  # 빈 $TMUX는 tmux 밖으로 본다(nvim 내장 판정 !empty($TMUX)와 같다).
  for ssh_var in SSH_CONNECTION SSH_TTY; do
    _nvim_clipboard_probe "$sandbox" linux "$ssh_var=probe" TMUX=
    assert_file_contains "$sandbox/out" "clipboard=unnamedplus"
    assert_file_contains "$sandbox/out" "g_clipboard=OSC 52 (copy only)"
    assert_file_contains "$sandbox/out" "provider=OSC 52 (copy only)"
  done

  # tmux 안 SSH: nvim 내장 tmux provider가 고르도록 g:clipboard를 두지 않는다.
  _nvim_clipboard_probe "$sandbox" linux SSH_CONNECTION=probe SSH_TTY=probe TMUX=/tmp/probe,1,0
  [[ "$(cat "$sandbox/out")" == $'clipboard=unnamedplus\ng_clipboard=unset' ]] ||
    fail "SSH inside tmux must keep the built-in provider selection: $(cat "$sandbox/out")"

  # SSH가 아닌 Linux: 기존 자동 선택을 그대로 둔다. 빈 SSH 변수도 SSH가 아니다.
  _nvim_clipboard_probe "$sandbox" linux
  [[ "$(cat "$sandbox/out")" == $'clipboard=unnamedplus\ng_clipboard=unset' ]] ||
    fail "non-SSH session must keep the built-in provider selection: $(cat "$sandbox/out")"
  _nvim_clipboard_probe "$sandbox" linux SSH_CONNECTION= SSH_TTY=
  [[ "$(cat "$sandbox/out")" == $'clipboard=unnamedplus\ng_clipboard=unset' ]] ||
    fail "empty SSH variables must not count as SSH: $(cat "$sandbox/out")"

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
  # "*"에 복사한 적이 없으면 "+"의 마지막 복사 내용을 쓴다.
  assert_file_contains "$sandbox/out" 'paste_star_from_plus=[["plus 1", "plus 2"], "V"]'
  # 둘 다 복사했으면 레지스터별 마지막 복사 내용과 그 regtype을 돌려준다.
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

  # "+"에 복사한 적이 없으면 "*"의 마지막 복사 내용을 쓴다.
  _nvim_clipboard_probe "$sandbox" linux SSH_CONNECTION=probe NVIM_CLIPBOARD_PROBE_SCENARIO=star-first
  assert_file_contains "$sandbox/out" 'paste_plus_from_star=[["star only"], "v"]'
}

test_neovim_ssh_clipboard_paste_before_copy_uses_register_zero() {
  _nvim_clipboard_require_nvim "neovim SSH clipboard paste before copy" || return 0
  local sandbox
  sandbox="$(new_sandbox)"
  _nvim_clipboard_write_probe "$sandbox"

  _nvim_clipboard_probe "$sandbox" linux SSH_CONNECTION=probe NVIM_CLIPBOARD_PROBE_SCENARIO=fresh
  # 복사한 적도, 레지스터 0도 없으면 빈 결과로 E353(빈 레지스터)이 난다. provider 오류가 아니다.
  assert_file_contains "$sandbox/out" 'empty_p=E353: Nothing in register "'
  assert_file_contains "$sandbox/out" 'empty_p_invalid_data=false'
  assert_file_contains "$sandbox/out" 'empty_buffer=["x"]'
  # 복사 전에는 레지스터 0(ShaDa가 되살린 마지막 yank)을 regtype째 돌려준다.
  assert_file_contains "$sandbox/out" 'fallback_linewise=[["from shada", ""], "V"]'
  assert_file_contains "$sandbox/out" 'fallback_star=[["from shada", ""], "V"]'
  assert_file_contains "$sandbox/out" 'fallback_buffer=["x", "from shada", ""]'
  assert_file_contains "$sandbox/out" 'fallback_block=[["ab", "c"], "\u00162"]'
  assert_file_contains "$sandbox/out" 'fallback_charwise=[["word"], "v"]'
  # 붙여넣기만 했으므로 터미널로 나간 시퀀스가 없다.
  if grep -q '^sent=' "$sandbox/out"; then
    fail "paste before copy must not send anything: $(grep '^sent=' "$sandbox/out")"
  fi
}

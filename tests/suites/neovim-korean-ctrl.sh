# shellcheck shell=bash
# SC2154: REPO_ROOT·new_sandbox·fail·assert_*는 aggregator가 test-common.sh를 먼저 source한 뒤
#   이 파일을 source해 정의한다(shellcheck는 이 순서를 모른다).
# shellcheck disable=SC2154
# tests/suites/neovim-korean-ctrl.sh — 한글 입력소스의 Ctrl+n/Ctrl+p를 <C-n>/<C-p>로 해석
#
# Ghostty는 Neovim이 켜는 kitty keyboard protocol에서 Ctrl+글자를 현재 입력소스의 글자로 보낸다.
# 한글 두벌식에서 Ctrl+n은 CSI 12636;5u(<C-ㅜ>), Ctrl+p는 CSI 12628;5u(<C-ㅔ>)이고, 각 누름 뒤에
# 놓음 이벤트(:3)가 따라온다. 이 바이트는 2026-11 Ghostty 1.4.0 + nvim 0.12.5 실측값이다.
# 바깥 headless nvim이 pty 안에 자식 nvim(--clean)을 띄워 배포되는 keymaps.lua를 읽힌 뒤 이 바이트를
# 그대로 넣는다. 그래서 TUI의 CSI u 해석부터 매핑까지 실제 경로를 지난다. blink.cmp는 Insert 모드
# <C-n>/<C-p>를 버퍼 로컬 매핑으로 걸므로 같은 모양의 probe 매핑으로 대신한다. 실제 Ghostty의
# 한글 입력기 동작(조합 중 Ctrl 키를 버리는 것 등)은 headless로 재현하지 못한다.

_NVIM_KOREAN_CTRL_KEYMAPS="modules/shared/programs/neovim/files/nvim/lua/config/keymaps.lua"

# nvim이 없으면 SKIP 사유를 내고 1을 돌려준다. required CI는 prePushRuntime의 nvim을 쓴다.
_nvim_korean_ctrl_require_nvim() {
  command -v nvim >/dev/null 2>&1 && return 0
  echo "SKIP: $1 requires nvim; run 'bash scripts/ai/test-runtime-profile.sh run \"$REPO_ROOT\" -- bash tests/run-shell-script-tests.sh'" >&2
  return 1
}

_nvim_korean_ctrl_write_probe() {
  cat >"$1/probe.lua" <<'EOF'
local keymaps = arg[1]
local sock = vim.fn.tempname() .. ".sock"
local job = vim.fn.jobstart({ vim.v.progpath, "--clean", "-i", "NONE", "-n", "--listen", sock }, {
  pty = true,
  width = 80,
  height = 24,
  env = { TERM = "xterm-256color" },
})
local function emit(key, value)
  io.stdout:write(key .. "=" .. value .. "\n")
end
local function die(msg)
  emit("error", msg)
  pcall(vim.fn.jobstop, job)
  os.exit(1)
end
if not vim.wait(10000, function() return vim.uv.fs_stat(sock) ~= nil end, 20) then
  die("child nvim did not listen")
end
local ch
vim.wait(5000, function()
  local ok, c = pcall(vim.fn.sockconnect, "pipe", sock, { rpc = true })
  if ok and c > 0 then ch = c end
  return ch ~= nil
end, 50)
if not ch then die("cannot connect to child nvim") end
local function lua(code, ...)
  return vim.rpcrequest(ch, "nvim_exec_lua", code, { ... })
end

lua([[
  dofile(...)
  _G.hits, _G.sync, _G.snap = { n = 0, p = 0 }, 0, {}
  -- 동기화 표식: 앞서 보낸 바이트가 모두 처리된 뒤에 도착하는 <F12>로 그 시점의 상태를 찍는다.
  vim.keymap.set({ "n", "i", "c" }, "<F12>", function()
    _G.snap = {
      mode = vim.api.nvim_get_mode().mode,
      line = vim.api.nvim_get_current_line(),
      cmdline = vim.fn.getcmdline(),
    }
    _G.sync = _G.sync + 1
  end)
]], keymaps)

local synced = 0
local function send(bytes)
  vim.fn.chansend(job, bytes .. "\27[24~")
  synced = synced + 1
  if not vim.wait(5000, function() return lua("return _G.sync") >= synced end, 20) then
    die("child nvim did not process input: " .. vim.inspect(bytes))
  end
  return lua("return _G.snap")
end
local CTRL_N = "\27[12636;5u\27[12636;5:3u" -- Ghostty, 한글 두벌식 Ctrl+n (누름 + 놓음)
local CTRL_P = "\27[12628;5u\27[12628;5:3u" -- Ghostty, 한글 두벌식 Ctrl+p (누름 + 놓음)
local ESC = "\27[27u"

-- 1) blink.cmp처럼 Insert 모드 <C-n>/<C-p>가 버퍼 로컬로 매핑된 경우: 그 매핑이 한 번씩 불린다.
lua([[
  vim.keymap.set("i", "<C-n>", function() _G.hits.n = _G.hits.n + 1 end, { buffer = 0 })
  vim.keymap.set("i", "<C-p>", function() _G.hits.p = _G.hits.p + 1 end, { buffer = 0 })
]])
send("i")
send(CTRL_N)
local snap = send(CTRL_P)
local hits = lua("return _G.hits")
emit("mapped_hits", ("n:%d,p:%d"):format(hits.n, hits.p))
emit("mapped_line", vim.fn.json_encode(snap.line))

-- 2) <C-n>/<C-p> 매핑이 없으면 내장 키워드 완성으로 간다 (진짜 Ctrl+n/Ctrl+p와 같은 동작).
send(ESC)
lua([[
  vim.keymap.del("i", "<C-n>", { buffer = 0 })
  vim.keymap.del("i", "<C-p>", { buffer = 0 })
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "apple", "" })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
]])
send("iap")
emit("builtin_next", vim.fn.json_encode(send(CTRL_N).line))
emit("builtin_prev", vim.fn.json_encode(send(CTRL_P).line))

-- 3) 명령줄 모드: <C-p>/<C-n>이 히스토리를 오간다.
send(ESC .. ESC)
lua([[vim.fn.histadd("cmd", "echo 'from history'")]])
send(":")
emit("cmdline_prev", vim.fn.json_encode(send(CTRL_P).cmdline))
emit("cmdline_next", vim.fn.json_encode(send(CTRL_N).cmdline))
send(ESC)

pcall(vim.rpcrequest, ch, "nvim_command", "qa!")
pcall(vim.fn.jobstop, job)
EOF
}

test_neovim_korean_ctrl_np_acts_as_ctrl_np() {
  _nvim_korean_ctrl_require_nvim "neovim Korean Ctrl+n/Ctrl+p" || return 0
  local sandbox
  sandbox="$(new_sandbox)"
  _nvim_korean_ctrl_write_probe "$sandbox"

  XDG_CONFIG_HOME="$sandbox/config" XDG_DATA_HOME="$sandbox/data" \
    XDG_STATE_HOME="$sandbox/state" XDG_CACHE_HOME="$sandbox/cache" \
    nvim --clean --headless -i NONE -n -l "$sandbox/probe.lua" "$REPO_ROOT/$_NVIM_KOREAN_CTRL_KEYMAPS" \
    >"$sandbox/out" 2>"$sandbox/err" ||
    fail "nvim probe failed: $(cat "$sandbox/out" "$sandbox/err")"

  # 누름마다 한 번씩만 불린다(놓음 이벤트로 두 번 불리지 않는다). 'ㅜ'·'ㅔ'는 입력되지 않는다.
  assert_file_contains "$sandbox/out" "mapped_hits=n:1,p:1"
  assert_file_contains "$sandbox/out" 'mapped_line=""'
  # 매핑이 없으면 내장 완성: Ctrl+n은 "ap"를 "apple"로 채우고 Ctrl+p는 입력한 "ap"로 되돌린다.
  assert_file_contains "$sandbox/out" 'builtin_next="apple"'
  assert_file_contains "$sandbox/out" 'builtin_prev="ap"'
  # 명령줄: Ctrl+p는 이전 히스토리를, Ctrl+n은 입력하던 빈 줄을 돌려준다.
  assert_file_contains "$sandbox/out" "cmdline_prev=\"echo 'from history'\""
  assert_file_contains "$sandbox/out" 'cmdline_next=""'
}

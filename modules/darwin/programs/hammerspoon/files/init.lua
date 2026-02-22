-- CLI에서 hs 명령 사용을 위한 IPC 모듈 로드
require("hs.ipc")

--------------------------------------------------------------------------------
-- Capslock → F18 리매핑 (한영 전환용)
--------------------------------------------------------------------------------

local FRemap = require('foundation_remapping')
local remapper = FRemap.new()
remapper:remap('capslock', 'f18')
remapper:register()

--------------------------------------------------------------------------------
-- 한글 입력 중 특정 단축키 → 영어 전환 후 원래 키 전달
--------------------------------------------------------------------------------

local inputEnglish = "com.apple.keylayout.ABC"

-- 앱 감지 헬퍼
local terminalBundleIDs = {
    ["com.mitchellh.ghostty"] = true,
    ["com.apple.Terminal"] = true,
    ["dev.warp.Warp-Stable"] = true,
    ["com.googlecode.iterm2"] = true,
}

local function isTerminalApp()
    local app = hs.application.frontmostApplication()
    return app and terminalBundleIDs[app:bundleID()] or false
end

local function isGhostty()
    local app = hs.application.frontmostApplication()
    return app and app:bundleID() == "com.mitchellh.ghostty"
end

-- 공통 함수: 영어로 전환 후 키 전달 (재귀 방지 포함)
local function convertToEngAndSendKey(bind, mods, key)
    if hs.keycodes.currentSourceID() ~= inputEnglish then
        hs.keycodes.currentSourceID(inputEnglish)
    end
    bind:disable()
    hs.eventtap.keyStroke(mods, key)
    bind:enable()
end

-- Ctrl + ; → 영어 전환
local control_semicolon_bind
control_semicolon_bind = hs.hotkey.bind({'ctrl'}, ';', function()
    convertToEngAndSendKey(control_semicolon_bind, {'ctrl'}, ';')
end)

-- Cmd + Shift + Space → 영어 전환 후 Homerow 실행
local command_shift_space_bind
command_shift_space_bind = hs.hotkey.bind({'cmd', 'shift'}, 'space', function()
    if hs.keycodes.currentSourceID() ~= inputEnglish then
        hs.keycodes.currentSourceID(inputEnglish)
    end
    hs.eventtap.keyStroke({'cmd', 'shift'}, 'space')
    command_shift_space_bind:disable()
    hs.eventtap.keyStroke({'cmd', 'shift'}, 'space')
    command_shift_space_bind:enable()
end)

-- Ctrl + B → 영어 전환 후 tmux prefix 전달 (전역)
local ctrl_b_bind
ctrl_b_bind = hs.hotkey.bind({'ctrl'}, 'b', function()
    convertToEngAndSendKey(ctrl_b_bind, {'ctrl'}, 'b')
end)

--------------------------------------------------------------------------------
-- Ghostty 전용: Ctrl 키 조합 (CSI u 모드 우회)
-- Claude Code 2.1.0+ 에서 한글 입력소스일 때 Ctrl 단축키가 동작하지 않는 문제 해결
--------------------------------------------------------------------------------

local ghosttyCtrlKeys = {'c', 'u', 'k', 'w', 'a', 'e', 'l', 'f'}

for _, key in ipairs(ghosttyCtrlKeys) do
    local bind
    bind = hs.hotkey.bind({'ctrl'}, key, function()
        if isGhostty() then
            convertToEngAndSendKey(bind, {'ctrl'}, key)
        else
            bind:disable()
            hs.eventtap.keyStroke({'ctrl'}, key)
            bind:enable()
        end
    end)
end

--------------------------------------------------------------------------------
-- 모든 터미널: Option 키 조합 (한글 입력소스 문제 해결)
-- Opt+B/F (단어 이동)가 한글 입력소스에서 동작하지 않는 문제 해결
--------------------------------------------------------------------------------

local terminalOptKeys = {'b', 'f'}

for _, key in ipairs(terminalOptKeys) do
    local bind
    bind = hs.hotkey.bind({'alt'}, key, function()
        if isTerminalApp() then
            convertToEngAndSendKey(bind, {'alt'}, key)
        else
            bind:disable()
            hs.eventtap.keyStroke({'alt'}, key)
            bind:enable()
        end
    end)
end

--------------------------------------------------------------------------------
-- Finder → Ghostty 터미널 열기 (Ctrl + Option + Cmd + T)
--------------------------------------------------------------------------------

local function openGhosttyFromFinder()
    local frontApp = hs.application.frontmostApplication()
    local path = nil

    -- Finder에서 실행 시: 현재 디렉토리 가져오기
    if frontApp:bundleID() == "com.apple.finder" then
        local script = [[
            tell application "Finder"
                try
                    if (count of windows) > 0 then
                        return POSIX path of (target of front window as alias)
                    else
                        return POSIX path of (path to desktop folder as alias)
                    end if
                on error
                    return POSIX path of (path to desktop folder as alias)
                end try
            end tell
        ]]
        local ok, result = hs.osascript.applescript(script)
        if ok then
            path = result
        end
    end

    -- Ghostty 새 창 열기
    local ghostty = hs.application.get("Ghostty")

    if ghostty then
        -- 이미 실행 중: 활성화 후 Cmd+N으로 새 창, 클립보드로 경로 전달
        ghostty:activate()
        -- 딜레이 1: Ghostty 활성화 완료 대기 (Cmd+N이 Ghostty에 전달되도록)
        -- 경로가 열리지 않으면 이 값을 늘려보세요 (예: 0.3)
        hs.timer.doAfter(0.2, function()
            hs.eventtap.keyStroke({"cmd"}, "n")
            if path then
                -- 딜레이 2: 새 창이 완전히 열릴 때까지 대기 (cd가 새 창에 입력되도록)
                -- 기존 창에 cd가 입력되면 이 값을 늘려보세요 (예: 0.8)
                hs.timer.doAfter(0.6, function()
                    -- 클립보드를 활용하여 한글 경로 문제 방지
                    local prevClipboard = hs.pasteboard.getContents()
                    hs.pasteboard.setContents('cd "' .. path .. '" && clear')
                    hs.eventtap.keyStroke({"cmd"}, "v")
                    hs.eventtap.keyStroke({}, "return")
                    -- 클립보드 복원
                    hs.timer.doAfter(0.1, function()
                        if prevClipboard then
                            hs.pasteboard.setContents(prevClipboard)
                        end
                    end)
                end)
            end
        end)
    else
        -- 미실행: open 명령어로 시작
        local args = {"-a", "Ghostty"}
        if path then
            table.insert(args, "--args")
            table.insert(args, "--working-directory=" .. path)
        end
        hs.task.new("/usr/bin/open", nil, args):start()
    end
end

hs.hotkey.bind({"ctrl", "alt", "cmd"}, "t", openGhosttyFromFinder)

--------------------------------------------------------------------------------
-- Chrome DevTools autoConnect 준비 (Ctrl + Option + Cmd + C)
--------------------------------------------------------------------------------

local homeDir = os.getenv("HOME") or ""
local chromeDebugScript = homeDir .. "/.local/bin/ensure-chrome-autoconnect.sh"

local function prepareChromeAutoConnect()
    local mode = hs.fs.attributes(chromeDebugScript, "mode")
    if not mode then
        hs.notify.new({
            title = "Chrome DevTools",
            informativeText = "ensure-chrome-autoconnect.sh 없음, 일반 Chrome 실행"
        }):send()
        hs.application.launchOrFocus("Google Chrome")
        return
    end

    local task = hs.task.new(chromeDebugScript, function(exitCode, _, stdErr)
        if exitCode ~= 0 then
            hs.notify.new({
                title = "Chrome DevTools",
                informativeText = "autoConnect 준비 실패, 로그를 확인하세요"
            }):send()
            if stdErr and stdErr ~= "" then
                print("[chrome-debug] " .. stdErr)
            end
        end

        hs.timer.doAfter(0.2, function()
            hs.application.launchOrFocus("Google Chrome")
        end)
    end, {})

    if task then
        if not task:start() then
            hs.notify.new({
                title = "Chrome DevTools",
                informativeText = "스크립트 시작 실패, 일반 Chrome 실행"
            }):send()
            hs.application.launchOrFocus("Google Chrome")
        end
    else
        hs.notify.new({
            title = "Chrome DevTools",
            informativeText = "스크립트 실행 실패, 일반 Chrome 실행"
        }):send()
        hs.application.launchOrFocus("Google Chrome")
    end
end

hs.hotkey.bind({"ctrl", "alt", "cmd"}, "c", prepareChromeAutoConnect)

--------------------------------------------------------------------------------
-- Atuin 동기화 상태 메뉴바
--------------------------------------------------------------------------------

require('atuin_menubar')

--------------------------------------------------------------------------------
-- 설정 로드 완료 알림
--------------------------------------------------------------------------------

hs.notify.new({title="Hammerspoon", informativeText="✅ 설정(init.lua) 리로드 완료"}):send()

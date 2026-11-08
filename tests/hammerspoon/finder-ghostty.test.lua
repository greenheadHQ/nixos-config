-- 실제 init.lua를 Hammerspoon 대역으로 실행한다. 앱·키·클립보드·외부 프로세스는 사용하지 않는다.
local sourcePath = assert(arg[1], "init.lua 경로 필요")
local passed, failed = 0, 0

local function equal(actual, expected, message)
    assert(actual == expected, message or (tostring(actual) .. " ~= " .. tostring(expected)))
end

local function fixture(options)
    options = options or {}
    local f = { tasks = {}, notices = {}, path = options.path or "/tmp/finder-fixture/폴더", front = "com.apple.finder" }
    f.clipboard = { text = "원래 내용", image = "합성 이미지", files = { "합성 파일 하나", "합성 파일 둘" } }
    local binding = { disable = function() end, enable = function() end }
    package.loaded["hs.ipc"] = {}
    package.loaded.foundation_remapping = { new = function()
        return { remap = function() end, register = function() end }
    end }
    package.loaded.anki_card_links = { start = function() end }
    _G.hs = {
        hotkey = { bind = function(mods, key, callback)
            if key == "t" and table.concat(mods, ",") == "ctrl,alt,cmd" then f.invoke = callback end
            return binding
        end },
        application = {
            frontmostApplication = function()
                if not f.front then return nil end
                return { bundleID = function() return f.front end }
            end,
            get = function(name)
                assert(name == "Ghostty" or name == "com.mitchellh.ghostty")
                if options.running == false then return nil end
                return {
                    bundleID = function() return "com.mitchellh.ghostty" end,
                    activate = function() error("앱 활성화 뒤 전역 입력 경로 사용") end,
                }
            end,
        },
        osascript = { applescript = function(script)
            assert(script:find('tell application "Finder"', 1, true))
            if options.finderFailure then return false, "합성 조회 오류" end
            return true, f.path
        end },
        notify = { new = function(value)
            return { send = function() table.insert(f.notices, value.informativeText) end }
        end },
        task = { new = function(command, callback, args)
            if options.taskMissing then return nil end
            local task = { command = command, callback = callback, args = args, starts = 0 }
            function task:start()
                self.starts = self.starts + 1
                if options.startFailure then return false end
                return self
            end
            table.insert(f.tasks, task)
            return task
        end },
        timer = { doAfter = function() error("Finder 경로에 타이머 사용") end },
        eventtap = {
            keyStroke = function() error("전역 키 입력 사용") end,
            keyStrokes = function() error("전역 텍스트 입력 사용") end,
            event = { types = { systemDefined = 1 } },
            new = function() return { start = function() end } end,
        },
        pasteboard = setmetatable({}, { __index = function() error("클립보드 접근") end }),
        urlevent = { bind = function() end },
        spaces = { toggleShowDesktop = function() end },
    }
    assert(loadfile(sourcePath))()
    assert(f.invoke, "Finder 단축키 미등록")
    f.notices = {}
    function f:finish(index, exitCode)
        self.tasks[index].callback(exitCode or 0, "합성 창 식별자", "합성 오류 원문")
    end
    return f
end

local function test(name, callback)
    local ok, err = pcall(callback)
    if ok then
        passed = passed + 1
        print("ok " .. name)
    else
        failed = failed + 1
        io.stderr:write("FAIL " .. name .. ": " .. tostring(err) .. "\n")
    end
end

test("실행 중 Ghostty에 경로를 단일 데이터 인자로 전달", function()
    local paths = {
        "/tmp/finder-fixture/한글 폴더",
        "/tmp/finder-fixture/작은'큰\"따옴표",
        "/tmp/finder-fixture/역\\슬래시",
        "/tmp/finder-fixture/$() `표현` ! * ? ; &",
        "/tmp/finder-fixture/-옵션처럼 보이는 경로",
    }
    local staticScript
    for _, path in ipairs(paths) do
        local f = fixture({ path = path })
        f.invoke()
        equal(#f.tasks, 1)
        local task = f.tasks[1]
        equal(task.command, "/usr/bin/osascript")
        equal(task.starts, 1)
        equal(#task.args, 4)
        equal(task.args[1], "-e")
        equal(task.args[3], "--")
        equal(task.args[4], path)
        assert(not task.args[2]:find(path, 1, true), "경로를 스크립트에 보간함")
        if staticScript then equal(task.args[2], staticScript) else staticScript = task.args[2] end
        assert(staticScript:find('tell application id "com.mitchellh.ghostty"', 1, true))
        assert(staticScript:find("new window with configuration", 1, true))
        assert(staticScript:find("initial working directory", 1, true))
        assert(not staticScript:find("input text", 1, true))
        assert(not staticScript:find("send key", 1, true))
        f:finish(1)
        equal(#f.notices, 0)
    end
end)

test("포커스 이동과 새 창 지연 중에도 전역 입력 없음", function()
    local f = fixture()
    f.invoke()
    f.front = "com.example.unrelated"
    collectgarbage("collect")
    f:finish(1)
    equal(#f.tasks, 1)
    equal(#f.notices, 0)
end)

test("빠른 두 호출이 각 경로를 보존하고 역순 완료해도 무입력", function()
    local f = fixture({ path = "/tmp/finder-fixture/첫 폴더" })
    f.invoke()
    f.path = "/tmp/finder-fixture/둘째 폴더"
    f.invoke()
    equal(#f.tasks, 2)
    equal(f.tasks[1].args[4], "/tmp/finder-fixture/첫 폴더")
    equal(f.tasks[2].args[4], "/tmp/finder-fixture/둘째 폴더")
    f:finish(2)
    f:finish(1)
    equal(#f.notices, 0)
end)

test("클립보드 복합 내용과 요청 중 새 복사를 보존", function()
    local f = fixture()
    local original = f.clipboard
    f.invoke()
    equal(f.clipboard, original)
    f.clipboard = { text = "새 복사", image = "새 합성 이미지", files = { "새 합성 파일" } }
    local copied = f.clipboard
    f:finish(1)
    equal(f.clipboard, copied)
end)

test("생성 실패는 알림만 남기고 입력 fallback 없음", function()
    local f = fixture()
    f.invoke()
    f:finish(1, 1)
    equal(#f.tasks, 1)
    equal(#f.notices, 1)
    assert(not f.notices[1]:find("합성 오류 원문", 1, true))
    assert(not f.notices[1]:find(f.path, 1, true))
end)

test("프로세스 생성 및 시작 실패를 알림", function()
    for _, options in ipairs({ { taskMissing = true }, { startFailure = true } }) do
        local f = fixture(options)
        f.invoke()
        equal(#f.notices, 1)
    end
end)

test("개행과 NUL 경로는 앱 상태와 관계없이 실행 전 거부", function()
    for _, running in ipairs({ true, false }) do
        for _, character in ipairs({ "\r", "\n", "\0" }) do
            local f = fixture({ running = running, path = "/tmp/finder-fixture/앞" .. character .. "뒤" })
            f.invoke()
            equal(#f.tasks, 0)
            equal(#f.notices, 1)
        end
    end
end)

test("Finder 조회 실패와 잘못된 결과는 중단", function()
    for _, options in ipairs({ { finderFailure = true }, { path = {} }, { path = "" } }) do
        local f = fixture(options)
        f.invoke()
        equal(#f.tasks, 0)
        equal(#f.notices, 1)
    end
end)

test("미실행 경로는 open 인자 배열 유지", function()
    local path = "/tmp/finder-fixture/한글 ' \" $() \\ 경로"
    local f = fixture({ running = false, path = path })
    f.invoke()
    local task = f.tasks[1]
    equal(task.command, "/usr/bin/open")
    equal(table.concat(task.args, "\0"), table.concat({ "-a", "Ghostty", "--args", "--working-directory=" .. path }, "\0"))
    f:finish(1)
    equal(#f.notices, 0)
end)

test("다른 앱 또는 앞쪽 앱 없음은 기본 경로로 새 창 요청", function()
    for _, running in ipairs({ true, false }) do
        for _, front in ipairs({ "com.example.unrelated", false }) do
            local f = fixture({ running = running })
            f.front = front
            f.invoke()
            equal(#f.tasks, 1)
            if running then
                equal(f.tasks[1].args[4], "")
            else
                equal(table.concat(f.tasks[1].args, "\0"), "-a\0Ghostty")
            end
        end
    end
end)

print(string.format("Finder→Ghostty 합성 검사: 통과 %d · 실패 %d", passed, failed))
if failed > 0 then os.exit(1) end

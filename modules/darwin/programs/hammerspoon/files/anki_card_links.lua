-- Open one exact card in the local Anki browser. No sync or accessibility automation.
-- Keep a pending GUI request locked when stop() or an uncertain reply cannot cancel it.
-- The VM registry survives package.loaded cache invalidation without a diagnostic global.
-- Restarting Hammerspoon creates a new VM; resolve pending Anki work before doing that.
local registry = debug.getregistry()
local registryKey = "nixos-config.anki-card-links"
local previous = registry[registryKey]
if type(previous) == "table" and not previous.stop() then
  error("Anki card-link GUI request is still pending; check Anki before reloading the module")
end

local M = {}
local state = { stopped = true, generation = 0, active = nil, guiPending = false, state = "stopped" }
-- Deployment supplies a fixed loopback URL from constants.nix, never from the incoming link.
local URL = "@ANKI_CONNECT_URL@"
local MAX_CID = "9223372036854775807"

local function notify(message)
  hs.notify.new({ title = "Anki 카드 링크", informativeText = message }):send()
end

local function validCid(cid)
  return type(cid) == "string" and cid:match("^[1-9][0-9]*$") ~= nil
    and (#cid < 19 or (#cid == 19 and cid <= MAX_CID))
end

local function alive(op)
  return not state.stopped and state.active == op and op.generation == state.generation
end

local function stopTimers(op)
  if op.retry then op.retry:stop(); op.retry = nil end
  if op.deadline then op.deadline:stop(); op.deadline = nil end
end

local function finish(op, nextState, message)
  if not alive(op) then return end
  stopTimers(op)
  state.active = nil
  state.state = nextState
  if message then notify(message) end
end

local function cardCount(result)
  if type(result) ~= "table" then return nil end
  local count = 0
  for key, value in pairs(result) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(value) ~= "number" then return nil end
    count = count + 1
  end
  if count ~= #result then return nil end
  return count
end

local function request(op, action, params, callback)
  if not alive(op) then return end
  local payload = { action = action, version = 6, params = params }
  local delivered = false
  if action == "guiBrowse" then
    state.guiPending = true
    state.pendingOperation = op
    op.guiSent = true
  end
  hs.http.doAsyncRequest(URL, "POST", hs.json.encode(payload), { ["Content-Type"] = "application/json" },
    function(status, body)
      if delivered then return end
      delivered = true
      local decoded, response = pcall(hs.json.decode, body)
      if action == "guiBrowse" then
        local definitive = status == 200 and decoded and type(response) == "table"
          and (type(response.error) == "string" or (response.error == nil and cardCount(response.result) ~= nil))
        if not definitive then
          -- A transport timeout or malformed reply does not prove the server stopped processing.
          -- Keep the cross-reload lock until the operator resolves the outstanding GUI request.
          if alive(op) then
            stopTimers(op)
            state.state = "gui-unknown-pending"
            notify("탐색 요청의 완료 여부가 불명확합니다. Anki 화면과 요청 상태를 확인하기 전에는 다시 열지 않습니다.")
          end
          return
        end
      end
      -- Clear only this operation's transport lock, even if stop() invalidated its UI callbacks.
      if action == "guiBrowse" and state.pendingOperation == op then
        state.guiPending = false
        state.pendingOperation = nil
        if state.stopped then state.state = "stopped" end
      end
      if not alive(op) then return end
      if status ~= 200 or not decoded or type(response) ~= "table" then
        callback(nil, (status == 401 or status == 403) and "auth" or "transport")
      elseif response.error ~= nil then
        local message = tostring(response.error)
        callback(nil, message:lower():find("api key", 1, true) and "auth" or "api")
      else
        callback(response.result, nil)
      end
    end, false) -- Never follow redirects away from the fixed loopback endpoint.
end

local poll
local function retry(op, errorKind)
  if not alive(op) then return end
  if errorKind == "auth" then
    finish(op, "auth-failed", "로컬 AnkiConnect 인증 설정을 확인하세요. 자동 재시도하지 않습니다.")
    return
  end
  op.retry = hs.timer.doAfter(0.25, function()
    op.retry = nil
    if alive(op) then poll(op) end
  end)
end

poll = function(op)
  request(op, "version", nil, function(version, err)
    if err then retry(op, err); return end
    if type(version) ~= "number" or version < 6 then
      finish(op, "unsupported-api", "AnkiConnect 버전을 확인하세요.")
      return
    end
    -- version() is only a protocol check. findCards also checks collection readiness.
    request(op, "findCards", { query = "cid:" .. op.cid }, function(cards, findError)
      if findError then retry(op, findError); return end
      local count = cardCount(cards)
      if count == 0 then
        finish(op, "missing", "이 Mac에 카드가 없거나 아직 동기화되지 않았을 수 있습니다.")
      elseif count ~= 1 then
        finish(op, "unexpected-result", "카드 조회 결과를 확인할 수 없습니다. 자동으로 탐색 창을 열지 않습니다.")
      else
        state.state = "opening-browser"
        -- CID stays a string. No float round-trip or guiSelectCard numeric parameter is needed.
        request(op, "guiBrowse", { query = "cid:" .. op.cid }, function(found, browseError)
          if browseError or cardCount(found) ~= 1 then
            finish(op, "gui-unknown", "탐색 요청 결과를 확인할 수 없습니다. 열린 Anki 화면을 직접 확인하세요.")
          else
            finish(op, "requested") -- The user, not this API result, verifies the selected row.
          end
        end)
      end
    end)
  end)
end

local function receive(event, params, _, fullURL)
  if state.stopped then return end
  if state.active or state.guiPending then
    notify("앞선 카드 열기 요청이 진행 중입니다. 결과를 확인한 뒤 다시 누르세요.")
    return
  end
  local cid = type(params) == "table" and params.cid or nil
  local onlyCid = type(params) == "table"
  if onlyCid then for key in pairs(params) do if key ~= "cid" then onlyCid = false end end end
  if event ~= "anki-browse" or not onlyCid or not validCid(cid)
    or fullURL ~= "hammerspoon://anki-browse?cid=" .. cid then
    notify("카드 링크 형식이 올바르지 않습니다.")
    return
  end
  state.generation = state.generation + 1
  local op = { cid = cid, generation = state.generation }
  state.active = op
  state.state = "waiting-for-anki"
  op.deadline = hs.timer.doAfter(8, function()
    if not alive(op) then return end
    if op.guiSent then
      state.state = "gui-pending"
      notify("탐색 요청 응답을 기다리고 있습니다. 앞선 요청이 끝날 때까지 다시 열지 않습니다.")
      -- Do not release the lock: a late GUI request can still change the Anki window.
    else
      if op.openTask then op.openTask:terminate() end
      finish(op, "not-ready", "Anki 프로필이 열렸는지 확인하세요. 준비 시간이 지나 요청을 중단했습니다.")
    end
  end)
  op.openTask = hs.task.new("/usr/bin/open", function(exitCode)
    if not alive(op) then return end
    op.openTask = nil
    if exitCode == 0 then poll(op)
    else finish(op, "open-failed", "Anki를 열지 못했습니다. 앱 설치 상태를 확인하세요.") end
  end, { "-b", "net.ankiweb.anki" })
  if not op.openTask or not op.openTask:start() then
    finish(op, "open-failed", "Anki 실행 요청을 시작하지 못했습니다.")
  end
end

function M.stop()
  if registry[registryKey] ~= M then return true end
  state.stopped = true
  state.generation = state.generation + 1
  hs.urlevent.bind("anki-browse", nil)
  if state.active then
    stopTimers(state.active)
    if state.active.openTask then state.active.openTask:terminate() end
  end
  state.active = nil
  state.state = state.guiPending and "stopped-gui-pending" or "stopped"
  return not state.guiPending
end

function M.start()
  -- An old module handle cannot replace or unbind the current owner's URL handler.
  if registry[registryKey] ~= M then return false end
  if state.guiPending then
    notify("탐색 요청의 완료 여부를 확인하기 전에는 카드 링크를 다시 시작하지 않습니다.")
    return false
  end
  if not state.stopped then return true end
  state.stopped = false
  state.state = "idle"
  hs.urlevent.bind("anki-browse", receive)
  return true
end

function M.status()
  return { state = state.state, guiPending = state.guiPending }
end

registry[registryKey] = M
return M

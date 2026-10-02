-- Pure Lua fake-hs tests. Never loads Hammerspoon or contacts Anki.
local path = assert(arg[1], "pass the anki_card_links.lua source path")
local function loadModule()
  local file = assert(io.open(path, "r"))
  local source = file:read("*a")
  file:close()
  -- The Nix deployment replaces the same marker with the configured loopback URL.
  source = source:gsub("@ANKI_CONNECT_URL@", "http://127.0.0.1:8765")
  return assert((loadstring or load)(source, "@" .. path))()
end
local passed = 0
local function equal(actual, expected)
  assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end
local function fixture()
  package.loaded.anki_card_links = nil
  debug.getregistry()["nixos-config.anki-card-links"] = nil
  local f = { now = 0, requests = {}, timers = {}, tasks = {}, notices = {}, binding = nil }
  _G.hs = {
    urlevent = { bind = function(name, callback) equal(name, "anki-browse"); f.binding = callback end },
    notify = { new = function(value) return { send = function() table.insert(f.notices, value.informativeText) end } end },
    json = {
      encode = function(value) return value end,
      decode = function(value) if value == "bad-json" then error("invalid") end; return value end,
    },
    timer = { doAfter = function(delay, callback)
      local timer = { at = f.now + delay, callback = callback, stopped = false }
      function timer:stop() self.stopped = true end
      table.insert(f.timers, timer)
      return timer
    end },
    task = { new = function(command, callback, args)
      equal(command, "/usr/bin/open"); equal(args[1], "-b"); equal(args[2], "net.ankiweb.anki")
      local task = { callback = callback, terminated = false }
      function task:start() return self end
      function task:terminate() self.terminated = true end
      table.insert(f.tasks, task)
      return task
    end },
    http = { doAsyncRequest = function(url, method, payload, headers, callback, redirects)
      equal(url, "http://127.0.0.1:8765"); equal(method, "POST"); equal(redirects, false)
      equal(headers["Content-Type"], "application/json")
      assert(headers.Origin == nil); assert(payload.key == nil)
      assert(payload.action == "version" or payload.action == "findCards" or payload.action == "guiBrowse")
      table.insert(f.requests, { payload = payload, callback = callback })
    end },
  }
  f.module = loadModule()
  assert(f.module.start())
  function f:click(cid, params, url)
    self.binding("anki-browse", params or { cid = cid }, nil, url or "hammerspoon://anki-browse?cid=" .. cid)
  end
  function f:open(exit) self.tasks[#self.tasks].callback(exit or 0) end
  function f:respond(result, err, status, raw)
    local request = self.requests[#self.requests]
    request.callback(status or 200, raw or { result = result, error = err })
    return request
  end
  function f:advance(seconds)
    local target = self.now + seconds
    while true do
      local nextTimer = nil
      for _, timer in ipairs(self.timers) do
        if not timer.stopped and timer.at <= target and (not nextTimer or timer.at < nextTimer.at) then nextTimer = timer end
      end
      if not nextTimer then break end
      self.now = nextTimer.at; nextTimer.stopped = true; nextTimer.callback()
    end
    self.now = target
  end
  function f:ready(cid)
    self:click(cid or "1"); self:open(); self:respond(6); self:respond({ 1 })
    equal(self.requests[#self.requests].payload.action, "guiBrowse")
  end
  return f
end
local function test(name, callback)
  callback()
  passed = passed + 1
  print("ok " .. name)
end

test("exact IDs and one GUI request", function()
  for _, cid in ipairs({ "1", "9007199254740993", "9223372036854775807" }) do
    local f = fixture(); f:ready(cid)
    equal(f.requests[2].payload.params.query, "cid:" .. cid)
    equal(f.requests[3].payload.params.query, "cid:" .. cid)
    f:respond({ 1 }); equal(f.module.status().state, "requested"); equal(f.module.status().guiPending, false)
    f:advance(20); equal(#f.requests, 3)
  end
end)
test("invalid IDs, query arguments and raw URL are rejected", function()
  for _, cid in ipairs({ "", "0", "01", "-1", "+1", "1.0", "1e3", "1\n", "１", "1/2", "9223372036854775808", "10000000000000000000" }) do
    local f = fixture(); f:click(cid); equal(#f.tasks, 0); equal(#f.requests, 0)
  end
  local f = fixture(); f:click("1", { cid = "1", query = "deck:all" }); equal(#f.tasks, 0)
  f:click("1", nil, "hammerspoon://anki-browse?cid=1&cid=2"); equal(#f.tasks, 0)
  f:click("1", nil, "hammerspoon://anki-browse?cid=%31"); equal(#f.tasks, 0)
  f:click("1", { cid = 1 }); equal(#f.tasks, 0)
end)
test("wait for open completion before network", function()
  local f = fixture(); f:click("1"); equal(#f.requests, 0)
  f:open(1); equal(f.module.status().state, "open-failed"); equal(#f.requests, 0)
end)
test("transport readiness retries are serial", function()
  local f = fixture(); f:click("1"); f:open(); f:respond(nil, nil, -1)
  equal(#f.requests, 1); f:advance(0.25); equal(#f.requests, 2)
  f:respond(6); equal(f.requests[3].payload.action, "findCards")
  f:respond(nil, "collection not available"); f:advance(0.25)
  equal(f.requests[4].payload.action, "version")
  f:respond(6); f:respond({ 1 }); f:respond({ 1 }); equal(f.module.status().state, "requested")
end)
test("version alone does not prove collection readiness", function()
  local f = fixture(); f:click("1"); f:open(); f:respond(6)
  equal(f.requests[2].payload.action, "findCards")
  equal(f.module.status().guiPending, false)
  f:advance(8); equal(f.module.status().state, "not-ready")
  f:respond({ 1 }); equal(#f.requests, 2)
end)
test("zero matches end without GUI or sync", function()
  local f = fixture(); f:click("1"); f:open(); f:respond(6); f:respond({})
  equal(f.module.status().state, "missing"); f:advance(20); equal(#f.requests, 2)
end)
test("invalid or multiple results do not open GUI", function()
  for _, result in ipairs({ "wrong", { 1, 2 }, { found = 1 }, { "1" } }) do
    local f = fixture(); f:click("1"); f:open(); f:respond(6); f:respond(result)
    equal(f.module.status().state, "unexpected-result"); equal(#f.requests, 2)
  end
end)
test("authentication errors do not poll", function()
  for _, status in ipairs({ 401, 403 }) do
    local f = fixture(); f:click("1"); f:open(); f:respond(nil, nil, status)
    equal(f.module.status().state, "auth-failed"); f:advance(20); equal(#f.requests, 1)
  end
  local f = fixture(); f:click("1"); f:open(); f:respond(nil, "a valid API key must be provided")
  equal(f.module.status().state, "auth-failed")
end)
test("malformed response cannot send GUI", function()
  local f = fixture(); f:click("1"); f:open(); f:respond(nil, nil, 200, "bad-json")
  f:advance(8); equal(f.module.status().state, "not-ready")
  for _, req in ipairs(f.requests) do assert(req.payload.action ~= "guiBrowse") end
end)
test("double click and GUI timeout keep a single pending request", function()
  local f = fixture(); f:ready("1"); f:click("2"); equal(#f.tasks, 1)
  f:advance(8); equal(f.module.status().state, "gui-pending"); equal(f.module.status().guiPending, true)
  f:click("2"); equal(#f.tasks, 1); equal(#f.requests, 3)
  f:respond({ 1 }); equal(f.module.status().guiPending, false)
  f:click("2"); equal(#f.tasks, 2)
end)
test("old ready response cannot affect a new click", function()
  local f = fixture(); f:click("1"); f:open()
  local old = f.requests[1]
  f:advance(8); f:click("2"); f:open(); equal(#f.requests, 2)
  old.callback(200, { result = 6 }); equal(#f.requests, 2)
  f:respond(6); f:respond({ 1 }); equal(f.requests[4].payload.params.query, "cid:2")
end)
test("repeated callbacks cannot send a second GUI request", function()
  local f = fixture(); f:click("1"); f:open()
  local version = f.requests[1]
  f:respond(6)
  version.callback(200, { result = 6 }); equal(#f.requests, 2)
  local cards = f.requests[2]
  f:respond({ 1 })
  cards.callback(200, { result = { 1 } }); equal(#f.requests, 3)
  local gui = f:respond({ 1 })
  gui.callback(200, { result = { 1 } }); equal(#f.requests, 3)
  equal(f.module.status().state, "requested")
end)
test("stop prevents open/read/retry callbacks", function()
  local f = fixture(); f:click("1"); local open = f.tasks[1]
  equal(f.module.stop(), true); equal(f.binding, nil); open.callback(0); equal(#f.requests, 0)
  f = fixture(); f:click("1"); f:open(); local read = f.requests[1]
  f.module.stop(); read.callback(200, { result = 6 }); f:advance(20); equal(#f.requests, 1)
  f = fixture(); f:click("1"); f:open(); f:respond(nil, nil, -1)
  f.module.stop(); f:advance(20); equal(#f.requests, 1)
  assert(f.module.start()); f:click("2"); equal(#f.tasks, 2)
end)
test("stop does not cancel sent GUI; module reload waits for callback", function()
  local f = fixture(); f:ready("1"); local gui = f.requests[3]
  equal(f.module.stop(), false); equal(f.module.status().state, "stopped-gui-pending")
  package.loaded.anki_card_links = nil
  local ok = pcall(loadModule); equal(ok, false)
  gui.callback(200, { result = { 1 } }); equal(f.module.status().guiPending, false); equal(f.module.status().state, "stopped")
  local fresh = loadModule(); assert(fresh.start()); equal(fresh.status().state, "idle"); equal(#f.requests, 3)
end)
test("GUI errors never retry automatically", function()
  local f = fixture(); f:ready("1"); f:respond(nil, "could not open browser")
  equal(f.module.status().state, "gui-unknown"); f:advance(20); equal(#f.requests, 3)
end)
test("replaced module handles cannot change the current URL binding", function()
  local f = fixture()
  local old = f.module
  local fresh = loadModule(); assert(fresh.start())
  local binding = f.binding
  assert(fresh.start()); equal(f.binding, binding)
  equal(old.start(), false); equal(old.stop(), true); equal(f.binding, binding)
  f:ready("1"); f:respond({ 1 }); equal(fresh.status().state, "requested")
end)
test("GUI transport or malformed replies keep the lock across stop and module reload", function()
  for _, response in ipairs({
    { status = -1, body = "bad-json" },
    { status = 200, body = "bad-json" },
    { status = 200, body = {} },
    { status = 500, body = { result = { 1 } } },
  }) do
    local f = fixture(); f:ready("1")
    f.requests[3].callback(response.status, response.body)
    equal(f.module.status().state, "gui-unknown-pending"); equal(f.module.status().guiPending, true)
    f:click("2"); equal(#f.tasks, 1); equal(#f.requests, 3)
    f:advance(20); equal(f.module.status().guiPending, true)
    equal(f.module.stop(), false)
    equal(f.module.start(), false); equal(f.binding, nil)
    equal(pcall(loadModule), false)
  end
end)
print(tostring(passed) .. " isolated Lua scenarios passed")

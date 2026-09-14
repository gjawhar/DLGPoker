-- Timer Probe v2 -- throwaway diagnostic System Tool for DLG Poker GitHub
-- issues #2/#3. Run 1 (2026-09-14, firmware 26.1.2) established:
--   * timer:startCondition(<bare CATEGORY_* constant>) THROWS
--     "Source expected; got number" -- the official reference example is
--     wrong on this firmware. A real Source object is required.
--   * system.getSource(CATEGORY_ALWAYS_ON) returns nil. So the Always-on
--     Source has to be found some other way -- page "always" below tries
--     several forms and, failing those, sweeps categories.
--   * CATEGORY_TIMER enumeration works (10 slots, empties named "---");
--     model.createTimer() works; audioActions entries are
--     {type, start, step, haptic} with start = seconds remaining at which
--     the action begins and step = interval.
--
-- Pages, in order: inspect, create, always, counting, audio, off, persist.
-- Rotary = page, short ENTER = run, RTN = close. WAIT on any page that
-- says "watching" until its VERDICT row appears (~8 s) before moving on.
-- Everything is pcall-wrapped and logged to Files/timer_probe.csv.
-- Cleanup: no deleteTimer() in the API -- delete "ProbeTimer" by hand in
-- SYSTEM > TIMERS when done.

local PAGES = { "inspect", "create", "always", "counting", "audio", "off", "persist" }
local page = 1
local log = {}
local dir = nil
local probe = nil
local alwaysSrc = nil      -- the Always-on Source once found
local noneSrc = nil        -- a "---" Source captured from a timer readback
local countStartAt = nil
local countSamples = {}
local watchTag = "counting"
local WATCH_SECS = 8

local function nowstr()
  local ok, t = pcall(os.date, "%H:%M:%S")
  return ok and t or "?"
end

local function record(test, result)
  log[#log + 1] = { ts = nowstr(), test = test, result = tostring(result) }
  if dir then
    local f = io.open(dir .. "timer_probe.csv", "a")
    if f then
      f:write(string.format("%s,%s,%s\n", nowstr(), test, (tostring(result):gsub(",", ";"))))
      f:close()
    end
  end
end

local function resolveDir()
  local candidates = { "Files/", "/scripts/TimerProbe/Files/", "SCRIPTS:/TimerProbe/Files/" }
  for i = 1, #candidates do
    local ok, f = pcall(io.open, candidates[i] .. "probe.tmp", "w")
    if ok and f then
      f:write("x"); f:close()
      pcall(os.remove, candidates[i] .. "probe.tmp")
      return candidates[i]
    end
  end
  return nil
end

local function describe(v)
  if v == nil then return "nil" end
  local t = type(v)
  if t == "number" or t == "string" or t == "boolean" then return t .. ":" .. tostring(v) end
  local parts = { t }
  local ok, name = pcall(function() return v:name() end)
  if ok then parts[#parts + 1] = "name=" .. tostring(name) end
  local ok2, cat = pcall(function() return v:category() end)
  if ok2 then parts[#parts + 1] = "cat=" .. tostring(cat) end
  local ok3, mem = pcall(function() return v:member() end)
  if ok3 then parts[#parts + 1] = "member=" .. tostring(mem) end
  return table.concat(parts, " ")
end

local function dumpTable(tbl)
  if type(tbl) ~= "table" then return describe(tbl) end
  local out = {}
  for i, e in ipairs(tbl) do
    if type(e) == "table" then
      local kv = {}
      for k, v in pairs(e) do kv[#kv + 1] = tostring(k) .. "=" .. tostring(v) end
      table.sort(kv)
      out[#out + 1] = "{" .. table.concat(kv, " ") .. "}"
    else
      out[#out + 1] = tostring(e)
    end
  end
  return "[" .. table.concat(out, " ") .. "]"
end

local function readback(tag, tm)
  if not tm then record(tag, "no timer object") return end
  local props = { "name", "direction", "start", "value", "startCondition", "countingSource", "running", "persistent" }
  for _, p in ipairs(props) do
    local ok, v = pcall(function() return tm[p](tm) end)
    record(tag .. ":" .. p, ok and describe(v) or ("ERR " .. tostring(v)))
  end
  local okA, a = pcall(function() return tm:audioActions() end)
  record(tag .. ":audioActions", okA and dumpTable(a) or ("ERR " .. tostring(a)))
end

local function byName(name)
  local ok, t = pcall(model.getTimer, name)
  if ok and t then return t end
  return nil
end

local function isSource(v)
  return v ~= nil and type(v) ~= "number" and type(v) ~= "string" and type(v) ~= "boolean"
end

local function startWatch(tag, note)
  local t = probe or byName("ProbeTimer")
  if not t then record(tag, "no ProbeTimer -- run create first") return end
  pcall(function() t:start(60) end)
  pcall(function() t:reset() end)
  countStartAt = os.time()
  countSamples = {}
  watchTag = tag
  record(tag, "watching value() for " .. WATCH_SECS .. " s after reset to 60 -- WAIT for the VERDICT row" .. (note and (" -- " .. note) or ""))
end

-- ---------------------------------------------------------------- pages

local function runInspect()
  local okV, ver = pcall(system.getVersion)
  record("firmware", okV and ver and tostring(ver.version) .. " board=" .. tostring(ver.board) or "?")
  record("globals", string.format("CATEGORY_TIMER=%s CATEGORY_ALWAYS_ON=%s CATEGORY_NONE=%s COUNTDOWN_VALUE=%s COUNTDOWN_BEEP=%s PLAY_VALUE=%s PLAY_FILE=%s",
    tostring(rawget(_G, "CATEGORY_TIMER")), tostring(rawget(_G, "CATEGORY_ALWAYS_ON")), tostring(rawget(_G, "CATEGORY_NONE")),
    tostring(rawget(_G, "COUNTDOWN_VALUE")), tostring(rawget(_G, "COUNTDOWN_BEEP")), tostring(rawget(_G, "PLAY_VALUE")), tostring(rawget(_G, "PLAY_FILE"))))
  local names = {}
  for i = 0, 9 do
    local ok, src = pcall(system.getSource, { category = CATEGORY_TIMER, member = i, options = 0 })
    if ok and src then
      local okN, n = pcall(function() return src:name() end)
      names[#names + 1] = i .. "=" .. tostring(okN and n or "?")
    end
  end
  record("enum:timers", table.concat(names, " "))
  for _, n in ipairs({ "Timer3", "PokerTimer", "ProbeTimer" }) do
    local t = byName(n)
    record("byName:" .. n, t and "resolved" or "nil")
    if t then readback("rb:" .. n, t) end
  end
end

local function runCreate()
  if byName("ProbeTimer") then
    record("create", "ProbeTimer already exists -- reusing (no deleteTimer in the API)")
    probe = byName("ProbeTimer")
  else
    local ok, t = pcall(model.createTimer)
    record("create:createTimer", ok and (t and "returned a timer" or "returned nil") or ("ERR " .. tostring(t)))
    if not (ok and t) then return end
    probe = t
    local okN, eN = pcall(function() t:name("ProbeTimer") end)
    record("create:name", okN and "ok" or ("ERR " .. tostring(eN)))
  end
  local t = probe
  local okD, eD = pcall(function() t:direction(-1) end)
  record("create:direction(-1)", okD and "ok" or ("ERR " .. tostring(eD)))
  local okS, eS = pcall(function() t:start(60) end)
  record("create:start(60)", okS and "ok" or ("ERR " .. tostring(eS)))
  pcall(function() t:reset() end)
  -- capture a "none" Source from the fresh timer's own start condition
  local okC, cur = pcall(function() return t:startCondition() end)
  if okC and isSource(cur) then noneSrc = cur record("create:noneSrc captured", describe(cur)) end
  readback("rb:ProbeTimer", t)
end

-- THE page for #3 now: find a Source that makes startCondition() take,
-- then confirm the timer actually counts.
local function tryStart(t, label, src)
  if not isSource(src) then record("always:" .. label, "not a Source: " .. describe(src)) return false end
  local ok, e = pcall(function() t:startCondition(src) end)
  if not ok then record("always:" .. label, "startCondition ERR " .. tostring(e)) return false end
  local okR, r = pcall(function() return t:running() end)
  local okB, back = pcall(function() return t:startCondition() end)
  record("always:" .. label, "SET OK; running=" .. tostring(okR and r) .. "; readback=" .. (okB and describe(back) or "?"))
  if okR and r == true then return true end
  return false
end

local function runAlways()
  local t = probe or byName("ProbeTimer")
  if not t then record("always", "no ProbeTimer -- run create first") return end
  pcall(function() t:start(60) end)
  pcall(function() t:reset() end)
  local candidates = {
    { "getSource{cat=ALWAYS_ON,member=0}", function() return system.getSource({ category = CATEGORY_ALWAYS_ON, member = 0 }) end },
    { "getSource{cat=ALWAYS_ON}", function() return system.getSource({ category = CATEGORY_ALWAYS_ON }) end },
    { "getSource{cat=ALWAYS_ON,member=0,options=0}", function() return system.getSource({ category = CATEGORY_ALWAYS_ON, member = 0, options = 0 }) end },
    { "getSource('Always On')", function() return system.getSource("Always On") end },
    { "getSource('Always on')", function() return system.getSource("Always on") end },
    { "getSource('ON')", function() return system.getSource("ON") end },
    { "getSource('On')", function() return system.getSource("On") end },
    { "getSource('always')", function() return system.getSource("always") end },
  }
  for _, c in ipairs(candidates) do
    local ok, src = pcall(c[2])
    record("always:lookup " .. c[1], ok and describe(src) or ("ERR " .. tostring(src)))
    if ok and isSource(src) and tryStart(t, c[1], src) then
      alwaysSrc = src
      record("always:FOUND", c[1] .. " -> " .. describe(src))
      break
    end
  end
  if not alwaysSrc then
    -- Sweep: what is member 0 of every low category? Whichever one is
    -- literally the always-on source will show up by name here.
    local hits = {}
    for cat = 0, 40 do
      local ok, src = pcall(system.getSource, { category = cat, member = 0 })
      if ok and isSource(src) then
        local okN, n = pcall(function() return src:name() end)
        hits[#hits + 1] = cat .. "=" .. tostring(okN and n or "?")
        if okN and type(n) == "string" and (n:lower():find("always") or n == "ON" or n == "On") and not alwaysSrc then
          if tryStart(t, "sweep cat" .. cat, src) then alwaysSrc = src record("always:FOUND", "sweep cat" .. cat .. " -> " .. describe(src)) end
        end
      end
    end
    record("always:sweep member0 by category", table.concat(hits, " "))
  end
  if alwaysSrc then
    startWatch("always", "confirming it actually counts")
  else
    record("always:VERDICT", "NO Always-on Source found by any form -- see sweep row; try the names listed there next")
  end
end

local function runCounting()
  startWatch("counting")
end

local function pollCounting()
  if not countStartAt then return end
  local t = probe or byName("ProbeTimer")
  if not t then countStartAt = nil return end
  local elapsed = os.time() - countStartAt
  if #countSamples == 0 or elapsed > countSamples[#countSamples].e then
    local ok, v = pcall(function() return t:value() end)
    local okR, r = pcall(function() return t:running() end)
    local vs, rs = "ERR", "ERR"
    if ok then vs = v end
    if okR then rs = r end
    countSamples[#countSamples + 1] = { e = elapsed, v = vs, r = rs }
  end
  if elapsed >= WATCH_SECS then
    local parts = {}
    for _, s in ipairs(countSamples) do parts[#parts + 1] = string.format("t+%ds:%s/run=%s", s.e, tostring(s.v), tostring(s.r)) end
    record(watchTag .. ":samples", table.concat(parts, " "))
    local first, last = countSamples[1].v, countSamples[#countSamples].v
    if type(first) == "number" and type(last) == "number" then
      local moved = last < first
      if watchTag == "off" then
        record("off:VERDICT", moved and "STILL COUNTING -- the none-Source did not stop it" or "STOPPED -- setting the none-Source switches it off")
      else
        record(watchTag .. ":VERDICT", moved and "COUNTS DOWN -- startCondition(Always-on Source) works; #3 answered" or "did NOT move -- not running")
      end
    end
    countStartAt = nil
  end
end

-- The pilot's requested defaults, in the format run 1 revealed:
-- call the time every 30 s, then a countdown for the last 10 s.
-- A/B alternate per press: A = spoken countdown values, B = beeps.
local audioShape = 0
local function runAudio()
  local t = probe or byName("ProbeTimer")
  if not t then record("audio", "no ProbeTimer -- run create first") return end
  if not alwaysSrc then record("audio", "WARNING: Always-on not set yet -- timer won't run, you won't hear anything; run 'always' first") end
  audioShape = audioShape + 1
  local shape
  if audioShape % 2 == 1 then
    shape = { { type = PLAY_VALUE, start = 3600, step = 30, haptic = 0 }, { type = COUNTDOWN_VALUE, start = 10, step = 1, haptic = 0 } }
    record("audio:set", "A = PLAY_VALUE every 30 s from 3600 + COUNTDOWN_VALUE from 10 s step 1 -- LISTEN from 45 s")
  else
    shape = { { type = PLAY_VALUE, start = 3600, step = 30, haptic = 0 }, { type = COUNTDOWN_BEEP, start = 10, step = 1, haptic = 0 } }
    record("audio:set", "B = PLAY_VALUE every 30 s + COUNTDOWN_BEEP from 10 s step 1 -- LISTEN from 45 s")
  end
  local ok, e = pcall(function() t:audioActions(shape) end)
  record("audio:audioActions", ok and "ok" or ("ERR " .. tostring(e)))
  local okA, a = pcall(function() return t:audioActions() end)
  record("audio:readback", okA and dumpTable(a) or ("ERR " .. tostring(a)))
  pcall(function() t:start(45) end)
  pcall(function() t:reset() end)
end

local function runOff()
  local t = probe or byName("ProbeTimer")
  if not t then record("off", "no ProbeTimer -- run create first") return end
  if not noneSrc then record("off", "no none-Source captured (run create first)") return end
  local ok, e = pcall(function() t:startCondition(noneSrc) end)
  record("off:startCondition(none Source)", ok and ("ok; readback=" .. describe(select(2, pcall(function() return t:startCondition() end)))) or ("ERR " .. tostring(e)))
  startWatch("off", "expect STOPPED")
end

local function runPersist()
  local t = byName("ProbeTimer")
  record("persist:ProbeTimer", t and "STILL EXISTS (only meaningful if you power-cycled first)" or "GONE -- createTimer did not persist")
  if t then readback("rb:ProbeTimer-persist", t) end
end

local RUN = { inspect = runInspect, create = runCreate, always = runAlways, counting = runCounting, audio = runAudio, off = runOff, persist = runPersist }

-- ---------------------------------------------------------------- tool

local function create()
  dir = resolveDir()
  record("probe", "v2 opened; dir=" .. tostring(dir))
  return {}
end

local HINTS = {
  inspect = "Lists timers + reads back Timer3/PokerTimer/ProbeTimer.",
  create = "createTimer -> ProbeTimer, countdown 60. Captures a none-Source.",
  always = "Hunts for the Always-on Source, sets it, then WAITS 8 s for a VERDICT.",
  counting = "Re-check: reset to 60, watch 8 s, VERDICT.",
  audio = "Sets 30 s callouts + 10 s countdown (A: spoken / B: beeps), restarts at 45 s. LISTEN.",
  off = "Sets the none-Source; WAIT 8 s; expect STOPPED.",
  persist = "Run after a full power cycle: does ProbeTimer still exist?",
}

local function paint()
  local w, h = lcd.getWindowSize()
  lcd.font(FONT_L)
  lcd.drawText(10, 6, "Timer Probe v2 -- " .. PAGES[page] .. string.format(" (%d/%d)", page, #PAGES))
  lcd.font(FONT_S)
  lcd.drawText(10, 34, "Rotate: page  -  ENTER: run this page  -  RTN: close")
  lcd.drawText(10, 52, HINTS[PAGES[page]] or "")
  local y = 76
  local first = math.max(1, #log - math.floor((h - y) / 16) + 1)
  for i = first, #log do
    local row = log[i]
    lcd.drawText(10, y, string.format("[%s] %s: %s", row.ts, row.test, row.result), w - 20)
    y = y + 16
  end
end

local function event(widget, category, value, x, y)
  if value == KEY_ROTARY_RIGHT then page = math.min(#PAGES, page + 1) return true end
  if value == KEY_ROTARY_LEFT then page = math.max(1, page - 1) return true end
  if value == KEY_ENTER_BREAK then
    local ok, err = pcall(RUN[PAGES[page]])
    if not ok then record(PAGES[page] .. ":CRASH", tostring(err)) end
    return true
  end
  return false
end

local function wakeup()
  pcall(pollCounting)
  lcd.invalidate()
end

local iconOk, icon = pcall(lcd.loadMask, "probe_icon.png")
if not iconOk then icon = nil end

system.registerSystemTool({
  name = "Timer Probe",
  icon = icon,
  create = create,
  paint = paint,
  wakeup = wakeup,
  event = event,
})

-- Timer Probe -- throwaway diagnostic System Tool for DLG Poker GitHub
-- issues #2/#3. Answers, on real hardware, the four things the official
-- Ethos Lua reference does not:
--   1. does timer:startCondition(CATEGORY_ALWAYS_ON) actually make a
--      countdown run (and what does startCondition() read back as)?
--   2. does model.createTimer() produce a timer that survives a power
--      cycle?
--   3. what do audioActions() {type, start, step} entries actually mean?
--   4. does startCondition(CATEGORY_NONE) stop a running timer?
--
-- Every risky call is pcall-wrapped: a probe that crashes the radio has
-- failed at its one job. Results are drawn on screen AND appended to
-- Files/timer_probe.csv. Rotary = change page, short ENTER = run the
-- page, RTN = close. Pages are meant to be run in order.
--
-- Install: /scripts/TimerProbe/main.lua + probe_icon.png + Files/.
-- Cleanup afterwards: there is no deleteTimer() in the API -- delete
-- "ProbeTimer" by hand in SYSTEM > TIMERS when done.

local PAGES = { "inspect", "create", "counting", "audio", "off", "persist" }
local page = 1
local log = {}
local dir = nil
local probe = nil          -- the created ProbeTimer object, this boot only
local countStartAt = nil   -- os.time() when a value() watch started
local countSamples = {}
local watchTag = "counting" -- which page started the watch: "counting" | "off"

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

-- Describe a Source (or whatever a getter returned) without assuming it
-- is a Source -- the reference says startCondition() returns a Source,
-- but the example SETS it with a bare CATEGORY_* constant.
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

-- Read back every property the reference lists, each guarded, so one
-- missing method (e.g. countingSource on pre-26.1 firmware) can't hide
-- the rest.
local function readback(tag, tm)
  if not tm then record(tag, "no timer object") return end
  local props = { "name", "direction", "start", "value", "startCondition", "countingSource", "running", "persistent", "alarm" }
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

-- ---------------------------------------------------------------- pages

-- 1. inspect: what timers exist (as Sources, by member index), and the
-- full readback of whatever DLG Poker's default timer resolves to.
local function runInspect()
  record("firmware", describe((pcall(system.getVersion)) and select(2, pcall(system.getVersion)).version or "?"))
  record("globals", string.format("CATEGORY_TIMER=%s CATEGORY_ALWAYS_ON=%s CATEGORY_NONE=%s COUNTDOWN_VALUE=%s COUNTDOWN_BEEP=%s PLAY_VALUE=%s PLAY_FILE=%s",
    tostring(rawget(_G, "CATEGORY_TIMER")), tostring(rawget(_G, "CATEGORY_ALWAYS_ON")), tostring(rawget(_G, "CATEGORY_NONE")),
    tostring(rawget(_G, "COUNTDOWN_VALUE")), tostring(rawget(_G, "COUNTDOWN_BEEP")), tostring(rawget(_G, "PLAY_VALUE")), tostring(rawget(_G, "PLAY_FILE"))))
  local found = 0
  for i = 0, 9 do
    local ok, src = pcall(system.getSource, { category = CATEGORY_TIMER, member = i, options = 0 })
    if ok and src then
      found = found + 1
      record("enum:member" .. i, describe(src))
    end
  end
  record("enum:count", found)
  for _, n in ipairs({ "Timer3", "PokerTimer", "ProbeTimer" }) do
    local t = byName(n)
    record("byName:" .. n, t and "resolved" or "nil")
    if t then readback("rb:" .. n, t) end
  end
  local okA, always = pcall(system.getSource, CATEGORY_ALWAYS_ON)
  record("getSource(ALWAYS_ON)", okA and describe(always) or ("ERR " .. tostring(always)))
end

-- 2. create: model.createTimer(), configure exactly as DLG Poker would.
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
  -- THE test for #3: bare constant, exactly as the official example
  local okC, eC = pcall(function() t:startCondition(CATEGORY_ALWAYS_ON) end)
  record("create:startCondition(ALWAYS_ON const)", okC and "ok" or ("ERR " .. tostring(eC)))
  local okR, eR = pcall(function() t:reset() end)
  record("create:reset", okR and "ok" or ("ERR " .. tostring(eR)))
  readback("rb:ProbeTimer", t)
end

-- 3. counting: does it actually count down now? Sample value() for ~6s.
local function runCounting()
  local t = probe or byName("ProbeTimer")
  if not t then record("counting", "no ProbeTimer -- run create first") return end
  pcall(function() t:start(60) end)
  pcall(function() t:reset() end)
  countStartAt = os.time()
  countSamples = {}
  watchTag = "counting"
  record("counting", "started watching value() for 6 s after reset to 60")
end

local function pollCounting()
  if not countStartAt then return end
  local t = probe or byName("ProbeTimer")
  if not t then countStartAt = nil return end
  local elapsed = os.time() - countStartAt
  if #countSamples == 0 or elapsed > countSamples[#countSamples].e then
    local ok, v = pcall(function() return t:value() end)
    local okR, r = pcall(function() return t:running() end)
    -- explicit ifs, not `ok and x or "ERR"`: running() legitimately
    -- returns false, which that idiom would misreport as an error
    local vs, rs = "ERR", "ERR"
    if ok then vs = v end
    if okR then rs = r end
    countSamples[#countSamples + 1] = { e = elapsed, v = vs, r = rs }
  end
  if elapsed >= 6 then
    local parts = {}
    for _, s in ipairs(countSamples) do parts[#parts + 1] = string.format("t+%ds:%s/run=%s", s.e, tostring(s.v), tostring(s.r)) end
    record(watchTag .. ":samples", table.concat(parts, " "))
    local first, last = countSamples[1].v, countSamples[#countSamples].v
    if type(first) == "number" and type(last) == "number" then
      local moved = last < first
      if watchTag == "counting" then
        record("counting:VERDICT", moved and "COUNTS DOWN with startCondition(ALWAYS_ON) -- #3 confirmed" or "did NOT move -- startCondition alone insufficient")
      else
        record("off:VERDICT", moved and "STILL COUNTING -- startCondition(NONE) did not stop it" or "STOPPED -- startCondition(NONE) switches it off (expected)")
      end
    end
    countStartAt = nil
  end
end

-- 4. audio: set the candidate default callouts, read them back, then
-- restart at 45 s so the pilot can LISTEN to what actually fires and at
-- what seconds. Two shapes, one per press: A = single COUNTDOWN_VALUE
-- entry; press again for B = value every 30 + beep last 10.
local audioShape = 0
local function runAudio()
  local t = probe or byName("ProbeTimer")
  if not t then record("audio", "no ProbeTimer -- run create first") return end
  audioShape = audioShape + 1
  local shape
  if audioShape % 2 == 1 then
    shape = { { type = COUNTDOWN_VALUE, start = 10, step = 30 } }
    record("audio:set", "A = {COUNTDOWN_VALUE start=10 step=30} (official example entry) -- LISTEN from 45 s")
  else
    shape = { { type = COUNTDOWN_VALUE, start = 30, step = 30 }, { type = COUNTDOWN_BEEP, start = 10, step = 1 } }
    record("audio:set", "B = {VALUE start=30 step=30} + {BEEP start=10 step=1} -- LISTEN from 45 s")
  end
  local ok, e = pcall(function() t:audioActions(shape) end)
  record("audio:audioActions", ok and "ok" or ("ERR " .. tostring(e)))
  local okA, a = pcall(function() return t:audioActions() end)
  record("audio:readback", okA and dumpTable(a) or ("ERR " .. tostring(a)))
  pcall(function() t:start(45) end)
  pcall(function() t:reset() end)
end

-- 5. off: does startCondition(CATEGORY_NONE) stop it? (Issue #2 migration:
-- "switch Timer3 off".) Sample 3 s later via the counting poller.
local function runOff()
  local t = probe or byName("ProbeTimer")
  if not t then record("off", "no ProbeTimer -- run create first") return end
  local ok, e = pcall(function() t:startCondition(CATEGORY_NONE) end)
  record("off:startCondition(NONE const)", ok and "ok" or ("ERR " .. tostring(e)))
  readback("rb:ProbeTimer-off", t)
  pcall(function() t:start(60) end)
  pcall(function() t:reset() end)
  countStartAt = os.time()
  countSamples = {}
  watchTag = "off"
  record("off", "watching value() for 6 s after startCondition(NONE)")
end

-- 6. persist: run this AFTER a full power cycle. Reports whether the
-- timer created earlier still resolves by name, with full readback.
local function runPersist()
  local t = byName("ProbeTimer")
  record("persist:ProbeTimer after power cycle", t and "STILL EXISTS -- createTimer persists" or "GONE -- createTimer did not persist")
  if t then readback("rb:ProbeTimer-persist", t) end
end

local RUN = { inspect = runInspect, create = runCreate, counting = runCounting, audio = runAudio, off = runOff, persist = runPersist }

-- ---------------------------------------------------------------- tool

local function create()
  dir = resolveDir()
  record("probe", "opened; dir=" .. tostring(dir))
  return {}
end

local function paint()
  local w, h = lcd.getWindowSize()
  lcd.font(FONT_L)
  lcd.drawText(10, 6, "Timer Probe -- " .. PAGES[page] .. string.format(" (%d/%d)", page, #PAGES))
  lcd.font(FONT_S)
  lcd.drawText(10, 34, "Rotate: page  -  ENTER: run this page  -  RTN: close")
  local hints = {
    inspect = "Lists timers + reads back Timer3/PokerTimer/ProbeTimer.",
    create = "createTimer -> ProbeTimer, countdown 60, startCondition(ALWAYS_ON).",
    counting = "Reset to 60 and sample for 6 s. Verdict line = issue #3 answer.",
    audio = "Sets callouts (A/B alternate per press), restarts at 45 s. Listen.",
    off = "startCondition(NONE). Verdict 'did NOT move' = NONE stops it.",
    persist = "Run after a power cycle: does ProbeTimer still exist?",
  }
  lcd.drawText(10, 52, hints[PAGES[page]] or "")
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

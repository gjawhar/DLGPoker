-- Poker Probe -- test logic. Every test writes one row to RESULTS with a
-- status (nil = not run, true = pass, false = fail) and a short detail
-- string. Nothing here assumes the answer; every claim in the Poker Timer
-- spec's S6/S6.4 gets its own row so a single bench session settles all of
-- them at once, the same way the Throw Trainer project's ALT Probe did for
-- OPTION_SENSOR_MAX before the real tool was built around it.
--
-- Full-screen only, no widget cell logic -- there is nothing here to
-- shrink into a tile, because the real tool won't have one either.

local probe = {}

-- ---------------------------------------------------------------- state

local RESULTS = {}     -- ordered list of {label, status, detail}
local ROWS = {}         -- label -> index into RESULTS, so re-running a test
                         -- overwrites its own row instead of appending
local TOP = 1           -- first visible result row -- now a REAL, rotary-
                         -- controlled scroll position (see probe.event),
                         -- not an always-auto-to-bottom anchor. That
                         -- auto-anchor repeatedly hid exactly the rows
                         -- being investigated (SWITCH_POSITION, then the
                         -- file-read DETAIL rows) once enough later tests
                         -- -- including async ones added well after
                         -- create() finishes, like the Timer3/wakeup-rate
                         -- rows -- pushed them off the bottom, no matter
                         -- how carefully result ordering was tuned.
local AUTOSCROLL = true -- true until the pilot manually scrolls, then
                         -- stays wherever they left it rather than
                         -- yanking their place away on the next result
local SCREEN = "main"   -- "main" | "setup"

local S = {
  boardInfo   = "",
  timerIdx    = nil,     -- resolved 0-based index for "Timer3", once found
  timerObj    = nil,
  timerOrigStart = nil,  -- so RESTORE can put the pilot's radio back
  sourceA     = nil,     -- assignable via SETUP form -- point this at a
  sourceB     = nil,     -- flight-mode switch, a logic switch, anything
  dwellAStart = nil,     -- os.time() when sourceA last went from <=0 to >0
  dwellA      = 0,
  dwellBStart = nil,
  dwellB      = 0,
  landingSrc  = nil,      -- switch the L: readout watches -- defaults to
                          -- LANDING_MODE, overridable via SETUP; see
                          -- testNamedSwitches()
  landingSrcTouched = false,  -- true once the pilot has picked one via
                               -- SETUP, so the auto-default never clobbers it
  dwellLStart = nil,
  dwellL      = 0,
  touchCapable = false,
  wakeupCount     = 0,
  wakeupCalibStart = nil,
  wakeupCalibrated = false,
  fsImmediateSrc = nil,
  fsDelayedSrc   = nil,
  fsDelayedStart = nil,
  fsDelayedDone  = false,
  focusKey    = 1,       -- which soft key is encoder-highlighted
  keyRects    = {},       -- soft-key hit rectangles, refreshed each paint
}

-- ---------------------------------------------------------------- utility

local function setRow(label, ok, detail)
  local i = ROWS[label]
  if not i then
    RESULTS[#RESULTS + 1] = { label = label, ok = ok, detail = detail or "" }
    ROWS[label] = #RESULTS
  else
    RESULTS[i].ok = ok
    RESULTS[i].detail = detail or ""
  end
end

local function pf(fn)
  -- pcall wrapper. Every call site passes a zero-arg closure rather than
  -- args through pf itself, deliberately -- table.unpack()/unpack() is not
  -- guaranteed to exist in Ethos's Lua build, and a missing global there
  -- would be one more thing standing between this script and a working
  -- syntax-checked load. Fewer moving parts in the one helper every test
  -- funnels through.
  local ok, a, b = pcall(fn)
  return ok, a, b
end

-- ---------------------------------------------------------------- T0: environment

-- Confirms the script installed and ran at all (S3.1 in the Throw Trainer
-- spec's terms -- if this paints, install succeeded), plus records exactly
-- which board and Ethos build the rest of the results apply to. Every other
-- row on this screen is only meaningful next to this one.
local function testEnvironment()
  local ok, v = pf(function() return system.getVersion() end)
  if ok and type(v) == "table" then
    S.boardInfo = string.format("%s  ethos %s  sim:%s",
      tostring(v.board), tostring(v.version), tostring(v.simulation))
    setRow("Install / registration", true, S.boardInfo)
  else
    S.boardInfo = "system.getVersion() failed"
    setRow("Install / registration", false, S.boardInfo)
  end

  -- Heuristic only, per the spec's S12 open item: exclude touch UI on
  -- anything that looks like an X14, show it everywhere else. This needs
  -- checking against a real X14 and a real X20RS side by side -- there is
  -- no confirmed "has touchscreen" field in getVersion() to key off
  -- instead, so this row exists specifically to be argued with on hardware.
  local board = (ok and v and v.board) or ""
  S.touchCapable = not string.find(tostring(board), "X14")
  setRow("Touch-capable heuristic", true,
    string.format("board=%s -> touch UI %s", tostring(board),
      S.touchCapable and "shown" or "hidden"))
end

-- ---------------------------------------------------------------- T1: timer lookup

-- Sweeps both lookup styles across a generous index/name range. This exists
-- because a past Ethos alpha build returned nil for every numeric-index
-- lookup while name-based lookup worked fine (Poker Timer spec S6.3 #1) --
-- so this row is the thing that tells us whether that's still true on this
-- radio's exact build, before the real tool commits to one style.
local function testTimerLookup()
  local byIndex, byName = {}, {}
  for i = 0, 8 do
    local ok, t = pf(function() return model.getTimer(i) end)
    byIndex[#byIndex + 1] = string.format("%d:%s", i, (ok and t) and "ok" or "nil")
  end
  for n = 1, 9 do
    local name = "Timer" .. n
    local ok, t = pf(function() return model.getTimer(name) end)
    if ok and t then byName[#byName + 1] = name end
  end
  setRow("model.getTimer by index", true, table.concat(byIndex, " "))
  setRow("model.getTimer by name", true,
    (#byName > 0) and table.concat(byName, ",") or "none resolved")

  -- Timer3 specifically -- try index 2 (0-based) first, fall back to name.
  local ok, t = pf(function() return model.getTimer(2) end)
  if not (ok and t) then ok, t = pf(function() return model.getTimer("Timer3") end) end
  if ok and t then
    S.timerObj = t
    local ok2, startVal = pf(function() return t:start() end)
    S.timerOrigStart = ok2 and startVal or nil

    -- Direction and counting-source, read-only. Added after the first bench
    -- run showed reset() not reloading value() to the new start -- this
    -- distinguishes "timer is in count-up/stopwatch mode, start isn't what
    -- reset() reloads to" from "Start condition is gating it independent of
    -- direction" (spec S6.3 item 3 / S6.3a), instead of guessing further.
    local ok3, dir = pf(function() return t:direction() end)
    local ok4, cs  = pf(function() return t:countingSource() end)
    local ok5, curVal = pf(function() return t:value() end)
    S.timerOrigDir = ok3 and dir or nil
    S.timerOrigCountingSource = ok4 and cs or nil

    setRow("Timer3 resolved", true,
      string.format("start=%s value=%s dir=%s countingSource=%s",
        tostring(S.timerOrigStart),
        ok5 and tostring(curVal) or "?",
        ok3 and tostring(dir) or "n/a",
        ok4 and tostring(cs) or "n/a"))
  else
    S.timerObj = nil
    setRow("Timer3 resolved", false, "neither index 2 nor name \"Timer3\" worked")
  end
end

-- ---------------------------------------------------------------- T1a: set direction/countingSource from Lua

-- The real question behind this test: can the pilot's one-time manual radio
-- setup (Countdown mode + Start condition = Always, both confirmed required
-- in S6.3a) be done BY THE SCRIPT instead, removing that setup step
-- entirely? direction() and countingSource() are documented as get/set
-- pairs, same shape as start(), but neither has actually been WRITTEN
-- before now -- only read. Side-effecting, so it only runs on the AUTOCFG
-- key, never automatically, and testTimerRestore() below puts both back
-- along with start().
--
-- countingSource(nil) is a guess at how "Always" (no gating condition) is
-- represented in Lua, based on the common firmware convention that an
-- unassigned start condition means "always counts" -- untested until this
-- row runs. If it errors or doesn't stick, that's a real, useful result:
-- it means this can't be automated and the manual radio step stays
-- required.
local function testTimerAutoConfig()
  if not S.timerObj then
    setRow("Timer3 set direction/countingSource", false, "Timer3 not resolved -- run lookup first")
    return
  end
  local t = S.timerObj

  local okD1 = select(1, pf(function() t:direction(-1) end))
  local okD2, dirAfter = pf(function() return t:direction() end)
  local dirWorked = okD1 and okD2 and dirAfter == -1

  local okC1 = select(1, pf(function() t:countingSource(nil) end))
  local okC2, csAfter = pf(function() return t:countingSource() end)
  local csChanged = okC1 and okC2 and tostring(csAfter) ~= tostring(S.timerOrigCountingSource)

  setRow("Timer3 set direction/countingSource", dirWorked,
    string.format("direction(-1): wrote=%s readback=%s | countingSource(nil): wrote=%s readback=%s",
      tostring(okD1), tostring(dirAfter),
      tostring(okC1), tostring(csAfter)))
end

-- ---------------------------------------------------------------- T2: timer write/reset

-- The one test with a side effect on the pilot's own radio, so it only
-- runs on an explicit key press, never automatically -- and RESTORE (T2b)
-- puts the original start value back immediately after, so this is safe to
-- run on a radio that's actually being flown with, not just the simulator.
local function testTimerWrite()
  if not S.timerObj then
    setRow("Timer3 set start()", false, "Timer3 not resolved -- run lookup first")
    return
  end
  local t = S.timerObj
  local before = S.timerOrigStart or 0
  -- +37 rather than a round number, so it's unmistakable in the readout
  -- whether the write actually landed or the field silently ignored it.
  local target = before + 37

  local ok1 = select(1, pf(function() t:start(target) end))
  local ok2, after = pf(function() return t:start() end)
  local wrote = ok1 and ok2 and (after == target)
  setRow("Timer3 set start()", wrote,
    string.format("before=%s target=%s after=%s", tostring(before), tostring(target), tostring(after)))

  -- Read value() immediately after the write, before reset() -- if a
  -- stopped timer's value() already tracks a freshly-written start(), that
  -- tells us reset() isn't the missing piece at all.
  local okPre, valPre = pf(function() return t:value() end)
  setRow("Timer3 value() after start(), before reset()", true,
    string.format("value=%s", okPre and tostring(valPre) or "?"))

  local ok3 = select(1, pf(function() t:reset() end))
  local ok4, val = pf(function() return t:value() end)
  -- A countdown timer's value after reset should read close to its start
  -- value; allow a couple of seconds of slack for the read itself.
  local matches = ok3 and ok4 and val and math.abs(val - target) <= 2
  setRow("Timer3 reset() -> value()", matches,
    string.format("value after reset=%s (want ~%s)", tostring(val), tostring(target)))

  -- Whether reset() also RESUMES COUNTING on a timer whose Start condition
  -- (Lua-side: countingSource()) isn't "Always" is a separate question from
  -- whether the value reloaded correctly -- confirmed OK above, but a timer
  -- can show the right number and still be sitting stopped. This starts a
  -- ~3s wall-clock watch (os.time(), not os.clock() -- see the project's own
  -- documented timing pitfall) that wakeup() finishes and scores below,
  -- with no extra key press needed.
  if ok4 and type(val) == "number" then
    S.timerTrack = { startVal = val, startTime = os.time(), done = false }
    setRow("Timer3 counting after reset (auto, ~3s)", nil, "sampling...")
  end

  setRow("Timer3 restore needed", true, "press RESTORE before leaving this screen")
end

local function testTimerRestore()
  S.timerTrack = nil   -- a fresh RUN, not the restored value, is what the
                        -- counting-after-reset row should describe
  if not S.timerObj or S.timerOrigStart == nil then
    setRow("Timer3 restore needed", false, "nothing to restore")
    return
  end
  local t = S.timerObj
  local ok1 = select(1, pf(function() t:start(S.timerOrigStart) end))
  -- Also put direction/countingSource back if AUTOCFG touched them -- this
  -- probe should never leave a pilot's real timer altered on any axis, not
  -- just the start value.
  local ok3 = true
  if S.timerOrigDir ~= nil then
    ok3 = select(1, pf(function() t:direction(S.timerOrigDir) end))
  end
  local ok4 = true
  if S.timerOrigCountingSource ~= nil then
    ok4 = select(1, pf(function() t:countingSource(S.timerOrigCountingSource) end))
  end
  local ok2 = select(1, pf(function() t:reset() end))
  setRow("Timer3 restore needed", ok1 and ok2 and ok3 and ok4,
    (ok1 and ok2 and ok3 and ok4) and ("restored to " .. tostring(S.timerOrigStart))
      or "restore failed -- check Timer3 manually")
end

-- Finishes the watch started above. Called every wakeup; a no-op once
-- S.timerTrack is nil or already done.
local function updateTimerTrack()
  local tr = S.timerTrack
  if not tr or tr.done or not S.timerObj then return end
  local ok, v = pf(function() return S.timerObj:value() end)
  if not ok or type(v) ~= "number" then return end
  if os.time() - tr.startTime < 3 then return end
  local delta = tr.startVal - v
  local counting = delta > 0
  setRow("Timer3 counting after reset (auto, ~3s)", counting,
    string.format("start=%s now=%s delta=%s -> %s",
      tostring(tr.startVal), tostring(v), tostring(delta),
      counting and "counting down -- Start condition allows it"
                or "NOT counting -- check the timer's Start condition"))
  tr.done = true
end

-- ---------------------------------------------------------------- T3: flight mode category sweep

-- Tests the direct route first. Per two still-open Ethos feature requests
-- (a general "get current flight mode" call, and separately just the
-- *name* of the active one), this is expected to come back thin or empty --
-- this row exists to confirm that expectation rather than assume it.
local function testFlightModeCategory()
  local hits = {}
  for i = 0, 8 do
    local ok, src = pf(function()
      return system.getSource({ category = CATEGORY_FLIGHT_MODE, member = i })
    end)
    if ok and src then
      local ok2, val = pf(function() return src:value() end)
      hits[#hits + 1] = string.format("%d=%s", i, ok2 and tostring(val) or "?")
    end
  end
  setRow("CATEGORY_FLIGHT_MODE sweep", #hits > 0,
    (#hits > 0) and table.concat(hits, " ") or "no members resolved")
end

-- ---------------------------------------------------------------- T3a: named logic switches

-- Read-only, safe to run automatically. Two purposes at once:
--   1. Confirm system.getSource can resolve a logic switch by name in THIS
--      standalone script's own context -- Throw Trainer proved this for
--      MOM_LAUNCH/ALT_CALL, but Poker Timer is a separate script (per the
--      project's own "own script, not part of the other" decision), so
--      that result doesn't automatically carry over without being checked
--      here too.
--   2. Check for LANDED_STABLE specifically -- expected nil until the
--      pilot has actually created that switch on their model (spec S6.4),
--      so a "nil" result here isn't a failure, just a status.
local function testNamedSwitches()
  local function lookup(name)
    local ok, src = pf(function()
      return system.getSource({ category = CATEGORY_LOGIC_SWITCH, name = name })
    end)
    return ok and src or nil
  end

  local launch = lookup("MOM_LAUNCH")
  setRow("MOM_LAUNCH by name", launch ~= nil,
    launch and "resolved" or "not found -- expected only if this model isn't the DLG template")

  -- Added specifically to diagnose a real stuck-at-ARMED report in Poker
  -- Timer: if ZOOM_MODE does not resolve (or MOM_LAUNCH above does not),
  -- Poker Timer's launch edge can never fire, no matter what the pilot
  -- does physically -- that is a model/VARS setup gap, not a Poker Timer
  -- bug. Watch this row plus the L:/A:/B: dwell readouts below while
  -- actually pulling the launch switch to confirm the signal is alive.
  local zoom = lookup("ZOOM_MODE")
  setRow("ZOOM_MODE by name", zoom ~= nil,
    zoom and "resolved -- template's own LSW18" or "not found on this model")

  local landing = lookup("LANDING_MODE")
  setRow("LANDING_MODE by name", landing ~= nil,
    landing and "resolved -- template's own LSW16" or "not found on this model")

  local stable = lookup("LANDED_STABLE")
  setRow("LANDED_STABLE by name", stable ~= nil,
    stable and "resolved -- ready to edge-detect"
             or "not found -- add it once, per spec S6.4, then re-run")

  -- What the L: readout actually watches is configurable (SETUP), not
  -- hardcoded -- but it needs a sensible default the first time the probe
  -- opens, before the pilot has necessarily built LANDED_STABLE yet.
  -- Prefer LANDED_STABLE once it exists; until then, default to the
  -- template's own LANDING_MODE (LSW16, confirmed present in the Settings
  -- Reference) rather than nothing -- LANDING_MODE alone is still directly
  -- useful to watch: it has no debounce, so it's the live demonstration of
  -- exactly the problem LANDED_STABLE exists to fix. Only set on first run
  -- (S.landingSrc == nil check) so a pilot's manual SETUP choice on a later
  -- RUN isn't silently overwritten.
  if S.landingSrc == nil and not S.landingSrcTouched then
    S.landingSrc = stable or landing
  end
end

-- ---------------------------------------------------------------- T5: logic switch parameter API

-- Whether Lua can read (or write) a logic switch's OWN configuration --
-- specifically its Duration field -- rather than just its live true/false
-- value, is what would let the debounce setting below be genuinely
-- authoritative instead of a second number the pilot has to keep in sync
-- by hand (spec S11 item 5). OpenTX/EdgeTX expose model.getLogicalSwitch()
-- / model.setLogicalSwitch() for exactly this; whether Ethos carries the
-- same functions forward is unconfirmed and untested until this row runs.
-- Read-only existence check -- no write is attempted even if it exists,
-- since altering a logic switch definition from a probe would be a much
-- bigger side effect than anything else here.
local function testLogicSwitchParamApi()
  local hasGet = type(model.getLogicalSwitch) == "function"
  local hasSet = type(model.setLogicalSwitch) == "function"
  setRow("model.get/setLogicalSwitch exist", hasGet and hasSet,
    string.format("get=%s set=%s", tostring(hasGet), tostring(hasSet)))

  if hasGet then
    -- Index 0 is LS1 in the OpenTX convention this API comes from; probed
    -- read-only to see what shape (if any) comes back on Ethos.
    local ok, tbl = pf(function() return model.getLogicalSwitch(0) end)
    if ok and type(tbl) == "table" then
      local parts = {}
      for k, v in pairs(tbl) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
      setRow("getLogicalSwitch(0) shape", true,
        (#parts > 0) and table.concat(parts, " ") or "empty table")
    else
      setRow("getLogicalSwitch(0) shape", false, tostring(tbl))
    end
  end
end

-- ---------------------------------------------------------------- T7: Function Switch resolution

-- Poker Timer's FS1-FS4 default resolution has now failed on real
-- hardware twice (CATEGORY_SWITCH, then a name-only lookup with no
-- category at all -- both attempted from inside core.init(), called from
-- create()). Rather than guess a third category blindly, this tests two
-- genuinely different hypotheses side by side:
--   1. Wrong category -- sweeps several more plausible guesses.
--   2. Wrong TIMING -- an Ethos developer discussion reports getSource()
--      returning nil for a source that resolves fine moments later,
--      specifically because it was called during create() before Ethos's
--      own source registry has finished initialising. Poker Timer's
--      resolveSwitches() runs inside core.init(), called from create() --
--      exactly that window. This retries the SAME lookup a few seconds
--      into wakeup() and reports both results side by side, so a
--      timing-only fix (retry once during wakeup, cache the result) can
--      be distinguished from a genuinely wrong category.
-- Timing is ruled out (confirmed on hardware: the delayed retry also
-- failed), and blindly guessing more CATEGORY_* names has a poor hit
-- rate -- five straight misses. Instead, enumerate every global that
-- actually exists on THIS build starting with "CATEGORY_" and try "FS1"
-- against literally all of them. This is exhaustive rather than another
-- guess: whatever the real category is called, if it is a global constant
-- following the same naming convention as every other confirmed category
-- in this project (CATEGORY_LOGIC_SWITCH, CATEGORY_TIMER, etc.), this
-- finds it without needing to know its name in advance.
local function enumerateCategoryConstants()
  local names = {}
  local ok = pcall(function()
    for k, v in pairs(_G) do
      if type(k) == "string" and string.find(k, "^CATEGORY_") and v ~= nil then
        names[#names + 1] = { key = k, val = v }
      end
    end
  end)
  table.sort(names, function(a, b) return a.key < b.key end)
  return names
end

local function tryFsLookup(name)
  -- name-only, no category, tried first as the cheapest possible hit
  local ok, src = pf(function() return system.getSource({ name = name }) end)
  if ok and src then return src, "name-only" end

  local cats = enumerateCategoryConstants()
  for i = 1, #cats do
    local ok2, src2 = pf(function() return system.getSource({ category = cats[i].val, name = name }) end)
    if ok2 and src2 then return src2, cats[i].key end
  end
  return nil, nil
end

local function testFunctionSwitchImmediate()
  local cats = enumerateCategoryConstants()

  -- Split across multiple rows rather than one long line -- the previous
  -- version truncated mid-list on screen (confirmed: cut off after
  -- "CATEGORY_CHANNEL" with more clearly following), which lost exactly
  -- the information this test exists to surface.
  local CHUNK = 4
  for i = 1, #cats, CHUNK do
    local chunk = {}
    for j = i, math.min(i + CHUNK - 1, #cats) do chunk[#chunk + 1] = cats[j].key end
    setRow(string.format("CATEGORY_* globals (%d-%d of %d)", i, math.min(i + CHUNK - 1, #cats), #cats),
      true, table.concat(chunk, " "))
  end
  if #cats == 0 then
    setRow("CATEGORY_* globals found", false, "none found in _G -- unexpected")
  end

  -- Name-based lookup already tried and failed against every discovered
  -- category. Function Switches may not be found by NAME at all -- try
  -- numeric MEMBER indexing instead (the pattern CATEGORY_TIMER sometimes
  -- needs), sweeping a handful of low indices against every discovered
  -- category, so an index-based rather than name-based retrieval isn't
  -- missed just because this test assumed "FS1" was the right key.
  --
  -- General sweep across every OTHER category runs FIRST and is summarised
  -- rather than itemised -- the previous version listed all 152 hits in
  -- full, which pushed the far more important CATEGORY_SWITCH_POSITION
  -- section below it clean off the screen (this app auto-scrolls to the
  -- newest rows, so anything printed after a long section is what's
  -- visible by default). CATEGORY_SWITCH_POSITION runs LAST for exactly
  -- that reason -- it is what should be on screen without scrolling.
  local otherCount, otherSample = 0, {}
  for i = 1, #cats do
    if cats[i].key ~= "CATEGORY_SWITCH_POSITION" then
      for m = 0, 7 do
        local ok, src = pf(function() return system.getSource({ category = cats[i].val, member = m }) end)
        if ok and src then
          otherCount = otherCount + 1
          local ok2, nm = pf(function() return src:name() end)
          -- Only keep a small sample for reference, and only if it looks
          -- switch-related -- a full list here is what caused the problem
          -- in the first place.
          if ok2 and nm and string.find(tostring(nm):lower(), "fs") and #otherSample < 6 then
            otherSample[#otherSample + 1] = string.format("%s[%d]=%s", cats[i].key, m, tostring(nm))
          end
        end
      end
    end
  end
  setRow("other categories, member sweep 0-7", true,
    string.format("%d total hits across every other category%s", otherCount,
      (#otherSample > 0) and (" -- FS-like: " .. table.concat(otherSample, " ")) or ""))

  -- CATEGORY_SWITCH_POSITION deep-dive is a separate function, called
  -- LAST from probe.create() (below) rather than from inside this
  -- function -- it needs to be the very last thing added at create()-time
  -- so it is not pushed off-screen by whatever runs after it. Keeping it
  -- inline here made it dependent on staying the last statement in this
  -- function forever, which already broke once when new checks were added
  -- below it.

  -- In case getSource() by category/name simply isn't how Function
  -- Switches are reached at all -- scan the system table itself for
  -- anything that looks purpose-built for them, so a dedicated function
  -- isn't missed just because this test only tried the generic path.
  local sysHits = {}
  local ok = pcall(function()
    for k, v in pairs(system) do
      if type(k) == "string" and (string.find(k:lower(), "switch") or string.find(k:lower(), "function")) then
        sysHits[#sysHits + 1] = k
      end
    end
  end)
  table.sort(sysHits)
  setRow("system.* names mentioning switch/function", #sysHits > 0,
    (#sysHits > 0) and table.concat(sysHits, " ") or "none found")

  local src, via = tryFsLookup("FS1")
  setRow("FS1 resolved at create() (immediate)", src ~= nil,
    src and ("via " .. via) or "nil against every discovered category -- see delayed retry row below")
  S.fsImmediateSrc = src
  setRow("category=12 members 0-3 (FS1-FS4 pattern check)", nil, "sampling...")

  return cats
end

-- Called last, deliberately, from probe.create() -- see the note above.
local function testSwitchPositionDeepDive(cats)
  -- CATEGORY_SWITCH_POSITION is a strong, specific lead -- "position" is
  -- exactly the right word for how a radio would model one entry of a
  -- switch group, and CATEGORY_TRIM_POSITION (confirmed in the general
  -- sweep above, e.g. "T4 Left") shows this exact "_POSITION" naming
  -- pattern really does give back human-readable position names on this
  -- build -- a strong signal, not just a guess by analogy.
  local swPos = nil
  for i = 1, #cats do if cats[i].key == "CATEGORY_SWITCH_POSITION" then swPos = cats[i].val end end
  if swPos == nil then
    setRow("CATEGORY_SWITCH_POSITION members 0-23", false, "category itself not found in this build")
    return
  end
  local hits = {}
  for m = 0, 23 do
    local ok, src = pf(function() return system.getSource({ category = swPos, member = m }) end)
    if ok and src then
      local ok2, nm = pf(function() return src:name() end)
      hits[#hits + 1] = string.format("[%d]=%s", m, ok2 and tostring(nm) or "?")
    end
  end
  local CHUNK2 = 6
  if #hits == 0 then
    setRow("CATEGORY_SWITCH_POSITION members 0-23", false, "no members resolved at any index")
    return
  end
  for i = 1, #hits, CHUNK2 do
    local chunk = {}
    for j = i, math.min(i + CHUNK2 - 1, #hits) do chunk[#chunk + 1] = hits[j] end
    setRow(string.format("SWITCH_POSITION members (%d-%d of %d)", i, math.min(i + CHUNK2 - 1, #hits), #hits),
      true, table.concat(chunk, " "))
  end
end

-- Called once, a few seconds into wakeup(), to test the timing hypothesis.
-- Timing hypothesis already ruled out (S6.4a confirmed both immediate and
-- delayed lookups failed identically) -- this slot now verifies the real
-- finding instead: category=12 (numeric, empirically discovered via
-- Source:category() on a manually-picked FS1, not from any documented
-- constant -- see spec S11) member=0 was confirmed as FS1. If FS2-FS4 are
-- members 1-3 of the same category, that is a complete, reliable
-- resolution rule for all four; this confirms or refutes that pattern
-- directly rather than assuming it holds.
local function testFunctionSwitchDelayed()
  if S.fsDelayedDone then return end
  if not S.fsDelayedStart then S.fsDelayedStart = os.time() end
  if os.time() - S.fsDelayedStart < 1 then return end
  local hits = {}
  for m = 0, 3 do
    local ok, src = pf(function() return system.getSource({ category = 12, member = m }) end)
    if ok and src then
      local ok2, nm = pf(function() return src:name() end)
      hits[#hits + 1] = string.format("[%d]=%s", m, ok2 and tostring(nm) or "?")
    else
      hits[#hits + 1] = string.format("[%d]=nil", m)
    end
  end
  setRow("category=12 members 0-3 (FS1-FS4 pattern check)", true, table.concat(hits, " "))
  S.fsDelayedDone = true
end

-- documents os.clock() as CPU time that advances far slower than real
-- time, which produced three separate timing bugs there). Point sourceA
-- at a Landing-mode logic switch (or anything boolean) via SETUP and this
-- proves out the debounce math the real LANDED_STABLE switch depends on.
local function updateDwell(src, startKey, dwellKey)
  if not src then return end
  local ok, v = pf(function() return src:value() end)
  if not ok or type(v) ~= "number" then return end
  local active = v > 0
  if active then
    if not S[startKey] then S[startKey] = os.time() end
    S[dwellKey] = os.time() - S[startKey]
  else
    S[startKey] = nil
    S[dwellKey] = 0
  end
end

-- ---------------------------------------------------------------- T8: file read methods

-- Two guesses at file reading have now failed on real hardware for Poker
-- Timer's readRows(): f:lines() (confirmed not callable) and f:read("*a")
-- (silently returns unusable content -- confirmed via a games.csv that
-- demonstrably has correct written content, per the pilot's own paste of
-- it, yet reads back as zero rows). This threatens more than the log --
-- Poker Timer's config persistence uses the exact same function, just
-- masked there because the fallback defaults happen to match what the
-- pilot wants anyway. Exhaustive this time: write a KNOWN value, try
-- every plausible read method against it, and report exactly which ones
-- reconstruct it correctly, rather than guessing a third time.
local TESTDIR_CANDIDATES = { "Files/", "/scripts/PokerProbe/Files/", "SCRIPTS:/PokerProbe/Files/" }
local KNOWN_CONTENT = "alpha,1,2\nbeta,3,4\ngamma,5,6\n"

local function resolveTestDir()
  for i = 1, #TESTDIR_CANDIDATES do
    local dir = TESTDIR_CANDIDATES[i]
    local ok = pf(function()
      local f = io.open(dir .. "probe_rw.tmp", "w")
      if not f then return false end
      f:write("x")
      f:close()
      return true
    end)
    if ok then return dir end
  end
  return nil
end

-- Renders control characters visibly (\n, \r, \t, and anything else as
-- \xNN) so the exact bytes returned can be inspected directly, rather than
-- comparing blindly against an expected string and only learning OK/FAIL.
local function escapeVisible(s)
  if s == nil then return "<nil>" end
  if type(s) ~= "string" then return "<" .. type(s) .. ">" end
  local out = string.gsub(s, "[%c]", function(c)
    if c == "\n" then return "\\n" end
    if c == "\r" then return "\\r" end
    if c == "\t" then return "\\t" end
    return string.format("\\x%02X", string.byte(c))
  end)
  if #out > 60 then out = string.sub(out, 1, 60) .. "..." end
  return out
end

-- Tests the flush/timing hypothesis directly: the simplest possible case
-- ("hello", 5 bytes, immediate reopen-and-read) returned ok=true,
-- content=nil -- succeeded, but as if the file were empty -- despite
-- games.csv demonstrably having correct, persisted content when the
-- pilot inspected it directly on the SD card. That combination points at
-- a write not being visible to a read in the SAME script execution,
-- rather than a wrong method or bad content. Write once here (called from
-- create()), then read again a few REAL seconds later from wakeup() --
-- true elapsed wall-clock time, not just later in the same call stack --
-- and compare both attempts side by side.
local delayedTest = { path = nil, startedAt = nil, done = false }

local function startDelayedFileTest()
  local dir = resolveTestDir()
  if not dir then
    setRow("delayed re-read test", false, "no writable directory found")
    return
  end
  delayedTest.path = dir .. "probe_delaytest.tmp"

  -- Verifies the write itself, directly, before touching read at all:
  -- write()'s own return value (Lua convention: the file handle on
  -- success, nil+message on failure) and the byte offset seek("end")
  -- reports immediately afterward -- if that comes back 0, no bytes
  -- landed on disk at all, regardless of what read() does or does not
  -- return. Both read() attempts so far succeeded (no error) yet
  -- returned nothing at all, identically whether immediate or 4s later --
  -- consistent with there being nothing there to read in the first place.
  local wrOk, wrRet, wrErr, sizeAfter = pf(function()
    local f = io.open(delayedTest.path, "w")
    if not f then return false, nil, "open for write failed", nil end
    local ret, err = f:write("hello")
    local size = nil
    local sok, spos = pf(function() return f:seek("end") end)
    if sok then size = spos end
    f:close()
    return true, ret, err, size
  end)
  setRow("write() return value + size via seek(end)", wrOk and sizeAfter == 5,
    string.format("write_ok=%s write_ret=%s size_after=%s (expected 5)",
      tostring(wrOk), tostring(wrRet), tostring(sizeAfter)))

  -- Confirmed via Ethos/EdgeTX's own io library docs (luadoc.edgetx.org):
  -- this simplified io library uses GLOBAL functions with the handle as
  -- the first argument -- io.write(f, ...) and io.read(f, n) -- not the
  -- standard Lua colon method-call convention (f:write(...), f:read(...))
  -- used everywhere above. That fully explains every symptom so far:
  -- f:lines() threw outright (no such method on this restricted handle),
  -- and f:read()/f:write() silently did nothing useful (going through
  -- Lua's method-dispatch sugar on an object never designed to support
  -- it). Tested directly, matching the documented example exactly,
  -- including its documented read loop (fixed chunk size, empty string
  -- signals EOF -- not nil, and not a single "*a" whole-file read).
  local gwOk, gwErr = pf(function()
    local f = io.open(delayedTest.path, "w")
    if not f then return false, "open for write failed" end
    io.write(f, "hello")
    io.close(f)
    return true
  end)
  local grOk, grGot, grErr = pf(function()
    local f = io.open(delayedTest.path, "r")
    if not f then return nil, nil, "open for read failed" end
    local out = {}
    while true do
      local chunk = io.read(f, 10)
      if not chunk or #chunk == 0 then break end
      out[#out + 1] = chunk
    end
    io.close(f)
    return table.concat(out), true, nil
  end)
  setRow("GLOBAL io.write(f,...)/io.read(f,n) convention", gwOk and grGot == "hello",
    string.format("write_ok=%s content=[%s] err=%s",
      tostring(gwOk), escapeVisible(grGot), tostring(grErr)))

  -- Poker Timer's actual appendRow() -- the function that produced the
  -- games.csv content confirmed correct via DIRECT, EXTERNAL inspection
  -- of the SD card -- opens in "a" (append) mode, never "w". Every test
  -- run so far has used "w" specifically. This is the one combination
  -- not yet tried: colon-method write in APPEND mode, matching the
  -- pilot's own already-working file exactly, both convention and mode.
  local apPath = dir .. "probe_appendtest.tmp"
  pf(function() os.remove(apPath) end)   -- start clean
  local awOk, awRet = pf(function()
    local f = io.open(apPath, "a")
    if not f then return false, "open for append failed" end
    local ret = f:write("hello")
    f:close()
    return true, ret
  end)
  local arOk, arGot = pf(function()
    local f = io.open(apPath, "r")
    if not f then return nil, "open for read failed" end
    local v = f:read("*a")
    pf(function() f:close() end)
    return v
  end)
  setRow("APPEND mode (matches appendRow() exactly)", awOk and arGot == "hello",
    string.format("write_ok=%s write_ret=%s content=[%s]",
      tostring(awOk), tostring(awRet), escapeVisible(arGot)))
  pf(function() os.remove(apPath) end)

  local wok = wrOk
  if not wok then
    setRow("delayed re-read test", false, "could not write the test file")
    return
  end

  local iok, igot = pf(function()
    local f = io.open(delayedTest.path, "r")
    if not f then return nil end
    local v = f:read("*a")
    pf(function() f:close() end)
    return v
  end)
  setRow("delayed test: IMMEDIATE read (0s after write)", iok and igot == "hello",
    string.format("ok=%s content=[%s]", tostring(iok), escapeVisible(igot)))
  setRow("delayed test: read AGAIN (4s later, real time)", nil, "sampling...")

  delayedTest.startedAt = os.time()
end

local function pollDelayedFileTest()
  if delayedTest.done or not delayedTest.path then return end
  if not delayedTest.startedAt then return end
  if os.time() - delayedTest.startedAt < 4 then return end
  delayedTest.done = true

  local ok, got = pf(function()
    local f = io.open(delayedTest.path, "r")
    if not f then return nil, "open failed" end
    local v = f:read("*a")
    pf(function() f:close() end)
    return v
  end)
  setRow("delayed test: read AGAIN (4s later, real time)", ok and got == "hello",
    string.format("ok=%s content=[%s] -- %s", tostring(ok), escapeVisible(got),
      (ok and got == "hello") and "CONFIRMS a flush/timing issue" or "same failure -- not a timing issue"))
  pf(function() os.remove(delayedTest.path) end)
end

local function testFileReadMethods()
  local dir = resolveTestDir()
  if not dir then
    setRow("file read methods", false, "no writable directory found -- cannot test")
    return
  end

  -- Simplest possible case first, isolated from the multi-line one below:
  -- a single short word, no embedded newlines at all. If even THIS fails,
  -- the problem is not specifically about newline handling.
  local simplePath = dir .. "probe_simple.tmp"
  pf(function()
    local f = io.open(simplePath, "w")
    if f then f:write("hello"); f:close() end
  end)
  local sOk, sGot = pf(function()
    local f = io.open(simplePath, "r")
    if not f then return nil end
    local v = f:read("*a")
    pf(function() f:close() end)
    return v
  end)
  setRow("simplest case: write 'hello', read(*a)",
    sOk and sGot == "hello",
    string.format("ok=%s len=%s content=[%s]", tostring(sOk),
      tostring(sGot and #sGot or "nil"), escapeVisible(sGot)))
  pf(function() os.remove(simplePath) end)

  local testPath = dir .. "probe_readtest.csv"

  local wok = pf(function()
    local f = io.open(testPath, "w")
    if not f then return false end
    f:write(KNOWN_CONTENT)
    f:close()
    return true
  end)
  if not wok then
    setRow("file read methods", false, "could not write the known test file at all")
    return
  end
  setRow("known content written", true,
    string.format("expected len=%d, content=[%s]", #KNOWN_CONTENT, escapeVisible(KNOWN_CONTENT)))

  -- Full diagnostic detail on read(*a) and read() specifically -- the two
  -- most standard candidates -- showing the actual bytes returned rather
  -- than just OK/FAIL, so a near-miss (line-ending translation, a missing
  -- trailing newline, truncation) is visible instead of indistinguishable
  -- from a hard failure.
  local function detailedAttempt(label, fn)
    local ok, got = pf(function()
      local f = io.open(testPath, "r")
      if not f then return nil, "open failed" end
      local v = fn(f)
      pf(function() f:close() end)
      return v
    end)
    setRow(label, ok and got == KNOWN_CONTENT,
      string.format("ok=%s len=%s content=[%s]", tostring(ok),
        tostring(got and #got or "nil"), escapeVisible(got)))
  end

  detailedAttempt("DETAIL: read(*a)", function(f) return f:read("*a") end)
  detailedAttempt("DETAIL: read()", function(f) return f:read() end)

  local results = {}

  local function attempt(label, fn)
    local ok, got = pf(function()
      local f = io.open(testPath, "r")
      if not f then return nil, "open failed" end
      local v = fn(f)
      pf(function() f:close() end)
      return v
    end)
    local matches = ok and got == KNOWN_CONTENT
    results[#results + 1] = string.format("%s=%s", label, matches and "OK" or "FAIL")
  end

  attempt("read(*a)", function(f) return f:read("*a") end)
  attempt("read(a)", function(f) return f:read("a") end)
  attempt("read()", function(f) return f:read() end)
  attempt("lines-loop", function(f)
    local out = {}
    for line in f:lines() do out[#out + 1] = line end
    return table.concat(out, "\n") .. "\n"
  end)
  attempt("read(*l)-loop", function(f)
    local out = {}
    while true do
      local l = f:read("*l")
      if not l then break end
      out[#out + 1] = l
    end
    return table.concat(out, "\n") .. "\n"
  end)
  attempt("read(l)-loop", function(f)
    local out = {}
    while true do
      local l = f:read("l")
      if not l then break end
      out[#out + 1] = l
    end
    return table.concat(out, "\n") .. "\n"
  end)
  attempt("io.lines(path)", function(f)
    local out = {}
    for line in io.lines(testPath) do out[#out + 1] = line end
    return table.concat(out, "\n") .. "\n"
  end)
  attempt("read(9999)", function(f) return f:read(9999) end)

  local anyOk = false
  for i = 1, #results do if string.find(results[i], "OK") then anyOk = true end end
  local CHUNK = 3
  for i = 1, #results, CHUNK do
    local chunk = {}
    for j = i, math.min(i + CHUNK - 1, #results) do chunk[#chunk + 1] = results[j] end
    setRow(string.format("file read methods (%d-%d of %d)", i, math.min(i + CHUNK - 1, #results), #results),
      true, table.concat(chunk, " "))
  end
  if not anyOk then
    setRow("file read methods -- SUMMARY", false, "NONE of the tried methods reconstructed the known content -- see DETAIL rows above")
  else
    setRow("file read methods -- SUMMARY", true, "at least one method above worked -- use whichever says OK")
  end

  pf(function() os.remove(testPath) end)
end

-- ---------------------------------------------------------------- T6: wakeup() rate

-- Directly informs whether a Lua-side debounce (watching LANDING_MODE and
-- timing it in the script, no new Logic Switch needed) can get closer than
-- whole-second resolution. os.time() alone can't -- Ethos's own Lua has no
-- confirmed sub-second wall clock (a still-open community request asks for
-- exactly this and gets told os.clock()/os.time() are the only options,
-- neither adequate below ~1s). Counting wakeup() calls within a known
-- os.time() window is the only other lever available; this measures it
-- rather than assuming a rate.
local function updateWakeupCalib()
  S.wakeupCount = (S.wakeupCount or 0) + 1
  if not S.wakeupCalibStart then S.wakeupCalibStart = os.time() end
  if S.wakeupCalibrated then return end
  local elapsed = os.time() - S.wakeupCalibStart
  if elapsed < 3 then return end
  local rate = S.wakeupCount / elapsed
  setRow("wakeup() rate (auto, ~3s)", true,
    string.format("%d calls in %ds -> ~%.1f/s -- %s", S.wakeupCount, elapsed, rate,
      (rate >= 4) and "fine enough to approximate 0.5s by counting calls"
                   or "too slow for sub-second timing; whole-second only"))
  S.wakeupCalibrated = true
end

-- ---------------------------------------------------------------- lifecycle

function probe.create()
  -- Wrapped as a last line of defence: if any test throws outside its own
  -- pcall (a bug in the probe itself, not in the thing being probed), the
  -- tool should still open and show that as a result row instead of never
  -- opening at all.
  local ok, err = pcall(function()
    testEnvironment()
    testTimerLookup()
    testFlightModeCategory()
    testNamedSwitches()
    testLogicSwitchParamApi()
    local cats = testFunctionSwitchImmediate()
    testSwitchPositionDeepDive(cats)
    testFileReadMethods()
    startDelayedFileTest()   -- deliberately last -- see its own comment
  end)
  if not ok then
    setRow("Startup", false, tostring(err))
  end
  return {}
end

function probe.wakeup(widget)
  updateDwell(S.sourceA, "dwellAStart", "dwellA")
  updateDwell(S.sourceB, "dwellBStart", "dwellB")
  updateDwell(S.landingSrc, "dwellLStart", "dwellL")
  updateTimerTrack()
  updateWakeupCalib()
  testFunctionSwitchDelayed()
  pollDelayedFileTest()
  lcd.invalidate()
end

function probe.close(widget)
  -- Best-effort safety net: if the pilot leaves without pressing RESTORE,
  -- put Timer3 back rather than silently leaving it altered -- on every
  -- axis AUTOCFG might have touched, not just the start value.
  if S.timerObj and S.timerOrigStart ~= nil then
    pf(function() S.timerObj:start(S.timerOrigStart) end)
    if S.timerOrigDir ~= nil then
      pf(function() S.timerObj:direction(S.timerOrigDir) end)
    end
    if S.timerOrigCountingSource ~= nil then
      pf(function() S.timerObj:countingSource(S.timerOrigCountingSource) end)
    end
    pf(function() S.timerObj:reset() end)
  end
end

-- ---------------------------------------------------------------- setup form

local function nameOf(src)
  if not src then return "-- unassigned --" end
  local ok, n = pf(function() return src:name() end)
  return (ok and n) and n or "?"
end

-- Called from the Test source A/B picker callbacks below, the instant a
-- source is assigned -- tries every plausible introspection method name on
-- the object itself, since the picker has already proven it can reach
-- something 20 categories times two lookup styles could not find by
-- category+name from Lua. If the object can report its own category, that
-- is real ground truth rather than another guess.
local function introspectSource(src, label)
  if not src then return end
  local candidates = { "category", "categoryName", "type", "kind", "id", "member", "index", "source" }
  local hits = {}
  for i = 1, #candidates do
    local ok, v = pcall(function() return src[candidates[i]](src) end)
    if ok and v ~= nil then
      hits[#hits + 1] = candidates[i] .. "()=" .. tostring(v)
    end
  end
  setRow(label .. " introspection", #hits > 0,
    (#hits > 0) and table.concat(hits, " ") or "none of the tried method names exist on this object")
end

local function buildSetup()
  form.clear()

  local line = form.addLine("Landing switch under test (L:)")
  form.addSourceField(line, nil,
    function() return S.landingSrc end,
    function(v)
      S.landingSrc = v
      S.landingSrcTouched = true   -- stops the auto-default from re-picking
      S.dwellLStart = nil
    end)

  line = form.addLine("Note")
  form.addStaticText(line, nil,
    "Defaults to LANDING_MODE (the template's own LSW16) since it already " ..
    "exists on this model. Point it at LANDED_STABLE instead once that's " ..
    "been built, per spec S6.4, to test the debounced version.")

  line = form.addLine("Test source A (general purpose)")
  form.addSourceField(line, nil,
    function() return S.sourceA end,
    function(v) S.sourceA = v S.dwellAStart = nil introspectSource(v, "Source A") end)

  line = form.addLine("Test source B (general purpose)")
  form.addSourceField(line, nil,
    function() return S.sourceB end,
    function(v) S.sourceB = v S.dwellBStart = nil introspectSource(v, "Source B") end)

  line = form.addLine("Note")
  form.addStaticText(line, nil,
    "Pick any switch or logic switch here. The live readout on the main " ..
    "screen shows its raw value plus how long it has read continuously " ..
    "active, timed in Lua.")
end

-- ---------------------------------------------------------------- drawing

local function statusGlyph(ok)
  if ok == nil then return "…", lcd.GREY(140) end
  if ok == false then return "FAIL", lcd.RGB(220, 90, 70) end
  return "OK", lcd.RGB(90, 200, 120)
end

local KEYS = { "RUN", "AUTOCFG", "SETUP", "RESTORE" }

local function paintMain(w, h)
  lcd.font(FONT_S)
  local _, th = lcd.getTextSize("8")
  th = th or 18
  local pad = math.floor(th * 0.4)
  local line = th + 4

  lcd.color(lcd.RGB(255, 255, 255))
  lcd.font(FONT_M)
  lcd.drawText(pad, pad, "Poker Probe -- hardware verification")
  lcd.font(FONT_S)

  local y = pad + line + 2
  -- Reserve room for the two pinned dwell lines and the soft-key row below
  -- them -- the previous version only reserved one line total, so once
  -- enough tests had run (ten rows, after v0.2's extra diagnostics) the
  -- list overran into the dwell readout, as seen on the bench (RESTORE
  -- screenshot: "Timer3 restore needed" collided with "A: ... active 0s").
  local dwellH = line * 3
  local softH = line + pad
  local rows = math.floor((h - y - dwellH - softH - pad) / line)
  if rows < 1 then rows = 1 end

  -- Rotary now genuinely scrolls (see probe.event) rather than always
  -- auto-anchoring to the bottom -- auto-anchor only applies until the
  -- pilot scrolls manually, and re-anchors if they scroll back down to
  -- (or past) the true bottom, so the common case (just want the latest)
  -- still needs no input at all.
  local maxTop = math.max(1, #RESULTS - rows + 1)
  if AUTOSCROLL then TOP = maxTop end
  if TOP > maxTop then TOP = maxTop end
  if TOP < 1 then TOP = 1 end

  -- Scroll position indicator -- the new interaction (rotary scrolls this
  -- list, see probe.event) is not otherwise discoverable at all.
  local bottomVisible = math.min(TOP + rows - 1, #RESULTS)
  local posLabel = string.format("%d-%d/%d%s", TOP, bottomVisible, #RESULTS,
    AUTOSCROLL and " (auto)" or "")
  local posW = lcd.getTextSize(posLabel)
  lcd.color(lcd.GREY(160))
  lcd.drawText(w - pad - posW, pad + 2, posLabel)

  for i = TOP, math.min(TOP + rows - 1, #RESULTS) do
    local r = RESULTS[i]
    local glyph, col = statusGlyph(r.ok)
    lcd.color(col)
    lcd.drawText(pad + 2, y + 1, glyph)
    lcd.color(lcd.RGB(255, 255, 255))
    lcd.drawText(pad + 60, y + 1, r.label)
    lcd.color(lcd.GREY(160))
    lcd.drawText(pad + 60, y + 1 + math.floor(line * 0.5), r.detail)
    y = y + line
  end

  -- Live dwell readouts, always pinned above the soft-key row so they are
  -- visible without scrolling -- these update every wakeup, unlike the rows
  -- above which only change when a test key is pressed. L watches whatever
  -- testNamedSwitches()/SETUP picked -- LANDING_MODE by default, LANDED_STABLE
  -- once it exists and is selected (see S6.4a); A/B are the general-purpose
  -- assignable slots for anything else worth comparing.
  local dwellY = h - line * 3 - (th + 4)
  lcd.color(lcd.GREY(160))
  lcd.drawText(pad, dwellY, string.format("L: %s  active %ds",
    nameOf(S.landingSrc), S.dwellL or 0))
  lcd.drawText(pad, dwellY + line, string.format("A: %s  active %ds",
    nameOf(S.sourceA), S.dwellA or 0))
  lcd.drawText(pad, dwellY + line * 2, string.format("B: %s  active %ds",
    nameOf(S.sourceB), S.dwellB or 0))

  -- Soft keys.
  local ky = h - line - pad
  local kw = math.floor((w - pad * 2) / #KEYS)
  for i = 1, #KEYS do
    local kx = pad + (i - 1) * kw
    lcd.color(lcd.GREY(90))
    lcd.drawRectangle(kx + 2, ky, kw - 4, line, 1)
    if i == S.focusKey then
      lcd.color(lcd.RGB(255, 255, 255))
      lcd.drawRectangle(kx + 1, ky - 1, kw - 2, line + 2, 2)
    end
    lcd.color(lcd.GREY(200))
    lcd.drawText(kx + 8, ky + 4, KEYS[i])

    -- Touch targets, drawn only where the environment test decided this
    -- board looks touch-capable (S12's explicit X14-excluded requirement).
    -- Rebuilt every paint rather than cached once, since the key layout is
    -- cheap to recompute and this avoids stale rectangles after a resize.
    if S.touchCapable then
      S.keyRects[i] = { x = kx, y = ky, w = kw, h = line }
    else
      S.keyRects[i] = nil
    end
  end
end

-- Rotating the encoder always drives the soft keys, not a row list, since
-- the result rows are read-only -- matching the rest of this ecosystem's
-- convention that rotation moves between actions when there's nothing else
-- to select.

function probe.paint(widget, w, h)
  if SCREEN == "setup" then return end   -- form owns painting while open
  paintMain(w, h)
end

-- ---------------------------------------------------------------- events

local function activateKey(i)
  local k = KEYS[i]
  if k == "RUN" then
    testTimerWrite()
    AUTOSCROLL = true   -- explicit "start fresh" action -- jump back to
                          -- showing the newest rows even if scrolled away
  elseif k == "AUTOCFG" then
    -- Attempts direction(-1) + countingSource(nil), then immediately
    -- re-runs the write/reset/counting sequence so the result is visible
    -- in the very next rows: did setting these two from Lua alone produce
    -- a fully working countdown timer, with no manual radio setup at all?
    testTimerAutoConfig()
    testTimerWrite()
  elseif k == "SETUP" then
    SCREEN = "setup"
    buildSetup()
  elseif k == "RESTORE" then
    testTimerRestore()
  end
  lcd.invalidate()
end

-- Tracks whether a REPEAT arrived since the last FIRST, to distinguish a
-- short press from a hold on BREAK -- BREAK alone fires after a long hold
-- too, same lesson already learned and documented in this project's other
-- Ethos scripts (Throw Trainer's key handling): there is no separate
-- "long press" constant, only FIRST / REPEAT / BREAK to combine.
local enterHeld = false

function probe.event(widget, value, x, y)
  if SCREEN == "setup" then
    if value == KEY_RTN_FIRST or value == 99 then
      form.clear()
      SCREEN = "main"
      lcd.invalidate()
      return true
    end
    return false
  end

  -- Touch: hit-test the soft-key rectangles recorded at paint time. This
  -- is unverified against a real touch event -- see S12's open item on
  -- what "category" actually reports for a touch, so this deliberately
  -- keys off x/y alone as the safest common denominator, gated by the
  -- touch-capable heuristic so it never activates on an X14 even if a
  -- stray event arrives.
  if S.touchCapable and x and y and x > 0 and y > 0 then
    for i, r in pairs(S.keyRects) do
      if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
        activateKey(i)
        return true
      end
    end
  end

  -- Rotary now scrolls the RESULTS list directly, rather than moving
  -- focus among the four soft keys -- freed up because touch already
  -- reaches those keys directly on touch-capable radios, and because
  -- being able to actually SEE every accumulated row (not just whatever
  -- is currently anchored to the bottom) is this tool's entire purpose.
  -- Manual scroll turns off auto-anchor; scrolling back down to (or past)
  -- the true bottom turns it back on, so returning to "just show me the
  -- latest" needs no explicit reset.
  if value == KEY_ROTARY_RIGHT or value == KEY_ROTARY_LEFT then
    local n = math.abs(tonumber(x) or 1)
    if n < 1 then n = 1 end
    local d = (value == KEY_ROTARY_RIGHT) and n or -n
    TOP = TOP + d
    if TOP < 1 then TOP = 1 end
    AUTOSCROLL = false   -- re-checked/re-enabled against the true bottom
                          -- in paintMain once TOP is clamped there
    lcd.invalidate()
    return true
  end

  if value == KEY_ENTER_FIRST then
    enterHeld = false
    return true
  end
  if value == KEY_ENTER_REPEAT then
    enterHeld = true
    return true
  end
  if value == KEY_ENTER_BREAK then
    if enterHeld then
      activateKey(S.focusKey)
    else
      -- Short press cycles focus among the four keys (RUN / AUTOCFG /
      -- SETUP / RESTORE) -- hold the encoder in to activate whichever is
      -- currently focused. Non-touch (X14) radios' only path to
      -- AUTOCFG/SETUP/RESTORE now goes through this, since rotary itself
      -- is busy scrolling.
      S.focusKey = (S.focusKey % #KEYS) + 1
    end
    lcd.invalidate()
    return true
  end

  if value == KEY_RTN_FIRST or value == KEY_EXIT_FIRST or value == 99 then
    return false   -- let the tool close
  end

  return false
end

return probe

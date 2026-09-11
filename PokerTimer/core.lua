-- DLG Poker core. Own script, not part of Throw Trainer (spec S13) -- no
-- shared files, own log, own identity-free storage (poker practice isn't
-- airframe-specific the way launch height is, so there is no per-glider
-- key here at all).
--
-- Every API this file leans on was bench-verified first with Poker Probe
-- before this was written, not assumed:
--   - model.getTimer() by NAME only, never index (spec S6.3a)
--   - Timer:start()/:reset()/:direction()/:countingSource() all writable,
--     and direction(-1) + countingSource(nil) alone fully replace the
--     Countdown-mode / Start-condition-Always manual setup (S6.3b)
--   - system.getSource(CATEGORY_LOGIC_SWITCH, name=...) resolves the
--     template's own MOM_LAUNCH and LANDING_MODE switches (S6.4a)
--   - wakeup() fires ~40-52 times/sec on both boards tested (S6.4a),
--     which is what makes counting calls a viable sub-second clock
--   - model.get/setLogicalSwitch do NOT exist on Ethos (S6.4a) -- native
--     landing-detection mode's debounce field can never be authoritative,
--     confirmed, not assumed

local core = {}
core.VERSION = "1.0.1"

-- ---------------------------------------------------------------- constants

local SCREEN = { SETUP = 1, LIVE = 2, SUMMARY = 3, LOG = 4, CONFIG = 5 }
core.SCREEN = SCREEN

local LOG_CAP = 2000

-- ---------------------------------------------------------------- state

local S = {
  ready   = false,
  dir     = nil,
  ioError = nil,
  cfg     = {},

  screen  = SCREEN.SETUP,

  -- Setup-screen editable defaults, copied into a live game on START.
  setupWindow = 600,
  setupBets   = 3,

  timerObj      = nil,
  timerAutoDone = false,

  landingSrc = nil,
  launchSrc  = nil,
  zoomSrc    = nil,

  -- Resolved from cfg.*SwitchName at every init() -- see resolveSwitchByName.
  minSwitchSrc     = nil,
  secSwitchSrc     = nil,
  allinSwitchSrc   = nil,
  confirmSwitchSrc = nil,

  -- edge tracking -- os.time() is fine here (these are just rising-edge
  -- comparisons, not durations). Duration/debounce tracking below is a
  -- different matter -- see the wakeup-rate calibration note.
  prevLaunch     = -100,
  prevZoom       = -100,

  -- Sub-second durations (landing debounce default 1.0s, hold-to-reset
  -- 0.8s) CANNOT be measured with os.time() -- confirmed directly on
  -- hardware in Poker Probe (S6.4): os.time() is whole-seconds only, so
  -- two samples 0.6s apart can floor to the identical integer second and
  -- read a dwell of zero. The fix decided in S6.4 is counting wakeup()
  -- calls instead, calibrated against the measured rate (~40-52/s on the
  -- two boards tested) rather than falling back to os.time() deltas.
  wakeupCalibCount = 0,
  wakeupCalibStart = nil,
  wakeupRate       = nil,   -- calls/sec once calibrated; nil uses a
                             -- conservative fallback (see callRate())

  landingActive = false,
  landingCalls  = 0,        -- consecutive active wakeup() calls, not seconds

  -- Debounces MOM_LAUNCH itself while genuinely mid-flight (armed,
  -- confirmed, unresolved) -- see pollRelaunchDebounce(). Same
  -- call-counting pattern as landingCalls above, same reason.
  relaunchCalls = 0,

  -- Ground-fumbling safety: a release starts the timer, but a landing
  -- signal is only trusted once ZOOM_MODE has actually been exited
  -- (elevator push/pull) since that release -- see pollZoomConfirm().
  flightConfirmed  = false,
  prevZoomConfirm  = nil,

  -- Set by autoBustUnresolvedFlight() so the SAME throw's release
  -- doesn't immediately auto-confirm right back into a new attempt --
  -- see that function's own comment.
  suppressNextAutoConfirm = false,

  -- game = nil until START; see startGame()
  game = nil,

  status   = nil,
  statusAt = 0,

  -- generic per-role switch tracking for hold-to-reset and stuck-switch
  -- detection (S6.5) -- keyed "min" | "sec" | "allin" | "confirm". Also
  -- call-counted, same reason as landing above.
  switches = {
    min     = { prev = -100, activeCalls = 0, resetFired = false, pendingShort = false, warned = false },
    sec     = { prev = -100, activeCalls = 0, resetFired = false, pendingShort = false, warned = false },
    allin   = { prev = -100, activeCalls = 0, pendingShort = false, warned = false },
    confirm = { prev = -100, activeCalls = 0, pendingShort = false, warned = false },
    -- SUMMARY/LOG-specific roles, added alongside the fix that lets FS1/FS4
    -- do something on those screens instead of being blocked entirely.
    viewlog = { prev = -100, activeCalls = 0, pendingShort = false, warned = false },
    newgame = { prev = -100, activeCalls = 0, pendingShort = false, warned = false },
    back    = { prev = -100, activeCalls = 0, pendingShort = false, warned = false },
  },
}
core.S = S

-- ---------------------------------------------------------------- wakeup-rate calibration

-- Read-only, automatic, ~3s after first wakeup -- same measurement Poker
-- Probe already validated on both the X14 and X20RS simulators (S6.4a).
-- Falls back to a deliberately conservative 20/s (well under both measured
-- rates) until calibration completes, so duration checks are never wildly
-- wrong during the first few seconds after the tool opens.
local function updateWakeupCalib()
  S.wakeupCalibCount = S.wakeupCalibCount + 1
  if not S.wakeupCalibStart then S.wakeupCalibStart = os.time() end
  if S.wakeupRate then return end
  local elapsed = os.time() - S.wakeupCalibStart
  if elapsed >= 3 then
    S.wakeupRate = S.wakeupCalibCount / elapsed
  end
end

local function callRate() return S.wakeupRate or 20 end

-- Converts a duration in seconds to a call-count threshold at the current
-- (possibly still-provisional) rate. Ceilinged, minimum 1, so a threshold
-- is never accidentally satisfied by zero elapsed calls.
local function secondsToCalls(seconds)
  return math.max(1, math.ceil(seconds * callRate()))
end

-- ---------------------------------------------------------------- config

local function defaults()
  return {
    windowDefault = 600,     -- 10:00
    betsDefault   = 3,
    timerName     = "Timer3",
    landingSwitchName = "LANDING_MODE",   -- Lua-timed default (S6.4)
    landingMode   = "lua",                -- "lua" | "native" (LANDED_STABLE)
    -- 1.0s (pilot request, 2026-09, field test): a quick brake tap in
    -- flight -- fingers slipping, repositioning -- must not read as a
    -- landing. 0.5s wasn't long enough to rule that out; a full second of
    -- continuous brake is.
    landingDebounce   = 1.0,              -- seconds -- "ignore quick taps" (S5 UI)
    -- 1/3s (pilot request, 2026-09, field test): MOM_LAUNCH itself needs
    -- the same "ignore a quick brush" treatment while genuinely mid-
    -- flight -- a pilot's hand can brush the launch switch without ever
    -- meaning to relaunch, and a brush that short should not bust the
    -- attempt at all, not even silently. See pollRelaunchDebounce().
    relaunchDebounce  = 1 / 3,            -- seconds -- "ignore accidental brushes"
    stuckWarnThreshold = 2.0,             -- seconds (S6.5)
    holdResetThreshold = 0.8,             -- seconds -- +MIN/+SEC hold=0 (S5.1)
    display       = "day",                -- "day" | "night" (S5.3)
    -- Switch roles are stored as NAME STRINGS, not Source objects --
    -- Source userdata can't round-trip through saveConfig()'s CSV writer
    -- (deliberately skipped there, since it isn't serialisable), which
    -- meant a manually-picked switch was silently lost on every restart.
    -- Names persist fine and are re-resolved to live Sources at init()
    -- every time, which also gives FS1-FS4 a real default for free instead
    -- of shipping blank.
    minSwitchName     = "FS1",
    secSwitchName     = "FS2",
    allinSwitchName   = "FS3",
    confirmSwitchName = "FS4",
  }
end
core.defaults = defaults

-- ---------------------------------------------------------------- files

local function tryDir(dir)
  local path = dir .. "probe.tmp"
  local f = io.open(path, "w")
  if not f then return false end
  f:write("x")
  f:close()
  if os.remove then pcall(os.remove, path) end
  return true
end

local function resolveDir()
  local candidates = { "Files/", "/scripts/PokerTimer/Files/", "SCRIPTS:/PokerTimer/Files/" }
  for i = 1, #candidates do
    local ok, works = pcall(tryDir, candidates[i])
    if ok and works then return candidates[i] end
  end
  return nil
end

local function path(base)
  if not S.dir then return nil end
  return S.dir .. base .. ".csv"
end

local function splitLine(line)
  local out = {}
  for field in string.gmatch(line .. ",", "([^,]*),") do out[#out + 1] = field end
  return out
end

local function readRows(base)
  local p = path(base)
  if not p then return {} end
  local f = io.open(p, "r")
  if not f then return {} end
  -- CONFIRMED on real hardware via Poker Probe bench testing (spec S11):
  -- this Ethos build's io library uses GLOBAL functions with the file
  -- handle as an explicit first argument -- io.read(f, n), io.write(f,
  -- ...), io.close(f) -- documented at luadoc.edgetx.org/io-library, NOT
  -- the standard Lua colon-method convention used everywhere else in
  -- ordinary Lua. Two prior guesses both failed on real hardware for
  -- exactly this reason: f:lines() throws outright (no such method on
  -- this restricted handle), and f:read("*a") -- which looked fine in
  -- testing because Poker Probe's OWN test rig had no Files/ folder to
  -- write into, silently returning nil rather than erroring -- throws
  -- "bad argument" once given a real file to read, which is exactly what
  -- was happening to every real games.csv read: the error was silently
  -- swallowed by this function's own defensive pcall, producing "no
  -- crash, but always empty" -- precisely the originally-reported bug.
  -- io.read(f, n) in a chunked loop, ending on an empty-string EOF
  -- marker (matching the documented example exactly), is the one
  -- confirmed-working read path.
  local chunks = {}
  local ok = pcall(function()
    while true do
      local chunk = io.read(f, 512)
      if not chunk or #chunk == 0 then break end
      chunks[#chunks + 1] = chunk
    end
  end)
  pcall(function() io.close(f) end)
  local rows = {}
  if ok then
    local content = table.concat(chunks)
    for line in string.gmatch(content, "[^\r\n]+") do
      if line ~= "" and string.sub(line, 1, 1) ~= "#" then
        rows[#rows + 1] = splitLine(line)
      end
    end
  end
  return rows
end

local function appendRow(base, fields)
  local p = path(base)
  if not p then return false end
  local f = io.open(p, "a")
  if not f then S.ioError = "append " .. base return false end
  f:write(table.concat(fields, ",") .. "\n")
  f:close()
  return true
end

local function rewrite(base, rows)
  local p = path(base)
  if not p then return false end
  local f = io.open(p, "w")
  if not f then S.ioError = "rewrite " .. base return false end
  for i = 1, #rows do f:write(table.concat(rows[i], ",") .. "\n") end
  f:close()
  return true
end

-- ---------------------------------------------------------------- config io

local function loadConfig()
  S.cfg = defaults()
  local rows = readRows("config")
  for i = 1, #rows do
    local key, raw = rows[i][1], rows[i][2]
    local num = tonumber(raw)
    if num then S.cfg[key] = num
    elseif raw == "true" then S.cfg[key] = true
    elseif raw == "false" then S.cfg[key] = false
    elseif raw == "" then S.cfg[key] = nil
    else S.cfg[key] = raw end
  end
end

function core.saveConfig()
  local d = defaults()
  local rows = {}
  for k, v in pairs(S.cfg) do
    -- Only persist genuine departures from default, and only scalar
    -- values -- Source objects (min/sec/allin/confirm switches) are not
    -- serialisable and are re-resolved at init instead (S9).
    if v ~= nil and v ~= d[k] and type(v) ~= "table" and type(v) ~= "userdata" then
      rows[#rows + 1] = { k, tostring(v) }
    end
  end
  rewrite("config", rows)
end

-- ---------------------------------------------------------------- sources

local function getLogic(name)
  local ok, src = pcall(system.getSource, { category = CATEGORY_LOGIC_SWITCH, name = name })
  if ok then return src end
  return nil
end

-- Function Switches (FS1-FS4) are not logic switches, and their category
-- constant is unconfirmed (spec S11 item 9) -- tried in order, first
-- success wins. A name-only lookup (no category at all) is tried last as
-- the most permissive fallback. Every attempt is pcall-wrapped, and if all
-- of them fail the role is simply left unresolved -- exactly the same
-- "blank, pilot assigns manually" behaviour as before this fix, so a
-- wrong guess here can never make things worse than they already were.
-- Function Switches are NOT reached by name or by any documented
-- CATEGORY_* constant -- confirmed on real hardware (spec S11) after an
-- exhaustive sweep of every category discovered via _G, tried both by
-- name and by member-index, found nothing. The actual answer came from
-- asking a manually-picked FS1 source what it is: Source:category()
-- returned the raw number 12, with member()=0 -- a real category on this
-- build, just never exposed under any CATEGORY_* symbolic name in Lua.
-- FS1-FS4 are members 0-3 of that same numeric category (pattern
-- confirmed via Poker Probe, spec S11).
--
-- Ethos 26.x names this category CATEGORY_FUNCTION_SWITCH (confirmed equal
-- to 12 by the Dial In probe); the literal stays as the fallback for
-- firmware without the constant. Tried FIRST, since it is the only
-- approach confirmed to work, with the originally-documented (but
-- never-working) attempts kept as a further fallback.
local FS_CATEGORY_NUMERIC = rawget(_G, "CATEGORY_FUNCTION_SWITCH") or 12

local function resolveSwitchByName(name)
  if not name or name == "" then return nil end

  local fsNum = string.match(name, "^FS(%d)$")
  if fsNum then
    local member = tonumber(fsNum) - 1
    local ok, src = pcall(function() return system.getSource({ category = FS_CATEGORY_NUMERIC, member = member }) end)
    if ok and src then return src end
  end

  local attempts = {
    function() return system.getSource({ category = CATEGORY_SWITCH, name = name }) end,
    function() return system.getSource({ name = name }) end,
  }
  for i = 1, #attempts do
    local ok, src = pcall(attempts[i])
    if ok and src then return src end
  end
  return nil
end

local function srcValue(src)
  if not src then return nil end
  local ok, v = pcall(function() return src:value() end)
  if ok and type(v) == "number" then return v end
  return nil
end

-- ---------------------------------------------------------------- timer

-- Resolve by NAME only -- bench-confirmed (S6.3a) that numeric index
-- lookup fails past index 1 on both boards tested.
local function resolveTimer()
  local ok, t = pcall(function() return model.getTimer(S.cfg.timerName) end)
  if ok and t then S.timerObj = t else S.timerObj = nil end
end

-- Idempotent -- safe to call every init, not just the first. Confirmed on
-- the X20RS simulator (S6.3b) to fully replace the manual "set Countdown
-- mode, set Start condition to Always" steps a pilot would otherwise have
-- to do by hand in SYSTEM > TIMERS.
local function autoConfigTimer()
  if not S.timerObj then return end
  pcall(function() S.timerObj:direction(-1) end)
  pcall(function() S.timerObj:countingSource(nil) end)
  S.timerAutoDone = true
end

-- The one call that matters (S6.2): set the duration, then reset. Called
-- once when a bet is confirmed (to preload the number) and again on every
-- MOM_LAUNCH rising edge (to actually start the countdown fresh).
local function timerSet(seconds)
  if not S.timerObj then return end
  pcall(function() S.timerObj:start(seconds) end)
end

local function timerReset()
  if not S.timerObj then return end
  pcall(function() S.timerObj:reset() end)
end

local function timerValue()
  if not S.timerObj then return nil end
  local ok, v = pcall(function() return S.timerObj:value() end)
  if ok and type(v) == "number" then return v end
  return nil
end

-- Public: re-resolve + re-autoconfig the target timer right now, without
-- a tool restart. Same pattern core.resolveSwitches() already uses for
-- the FS1-4 name fields -- config.lua's Target timer field should call
-- this after every edit (added alongside this function; it never did
-- before, which made the ONE existing recovery path -- retype the
-- correct current name -- silently not take effect until next restart).
function core.resolveTimerNow()
  resolveTimer()
  autoConfigTimer()
end

-- Public: true once a persistent, visible warning should show (pilot
-- request, 2026-09, field report: renaming the target Ethos timer broke
-- DLG Poker with NO indication anywhere -- every timerSet/timerReset/
-- timerValue call already silently no-ops on a nil S.timerObj, which is
-- exactly the failure mode that needs to stop being silent). Gated on
-- S.ready so it can't fire during the brief pre-init window.
function core.timerMissing()
  return S.ready and S.timerObj == nil
end

-- Public: rename the CURRENTLY-RESOLVED timer back to the default name
-- ("Timer3") and point config at that name too (pilot request, 2026-09:
-- "can you have the lua change the name back"). Deliberately only acts
-- on S.timerObj -- the timer DLG Poker already has a live, BY-NAME-
-- resolved handle to -- rather than guessing at a numeric slot: this
-- project's own Poker Probe bench-testing (S6.3a) already confirmed
-- index-based model.getTimer() lookups are unreliable past index 1 on
-- real hardware, despite the official Lua reference documenting index
-- support, so there is no reliable way to enumerate "candidate" timers
-- by slot to guess which one the pilot means. The real recovery path is
-- still: retype the Target timer field to the timer's CURRENT actual
-- name first (already resolves correctly, by name, once it matches) --
-- this button is what runs afterward, purely to restore the standard
-- name if the pilot wants that back rather than leaving it renamed.
function core.renameTimerToDefault()
  if not S.timerObj then return false end
  local defaultName = defaults().timerName
  local ok = pcall(function() S.timerObj:name(defaultName) end)
  if not ok then return false end
  S.cfg.timerName = defaultName
  core.saveConfig()
  core.resolveTimerNow()
  return S.timerObj ~= nil
end

-- Public accessor for screen.lua -- the live, actually-counting value of
-- the physical timer, not the static bet target. Needed so S2 can show a
-- real, ticking countdown once a launch has happened, rather than a
-- frozen number that never reflects whether anything actually started,
-- reset, or is still running.
function core.liveTimerValue()
  return timerValue()
end

-- ---------------------------------------------------------------- status line

function core.setStatus(text)
  S.status = text
  S.statusAt = os.time()
end

function core.status()
  if not S.status then return nil end
  if os.time() - (S.statusAt or 0) > 3 then S.status = nil return nil end
  return S.status
end

-- Public: is the launch switch CURRENTLY held down, right now. Lets S2
-- show "you are in Launch mode, release to enter Zoom and start the
-- timer" while the pilot is mid-press, rather than the screen looking
-- identical whether the switch has been touched or not.
function core.isLaunchPressed()
  if not S.launchSrc then return false end
  local ok, v = pcall(function() return S.launchSrc:value() end)
  return ok and type(v) == "number" and v > 0
end

-- Called from main.lua's wakeup() if core.wakeup() throws. The specific
-- risk this closes: S.landingActive latches true the instant the
-- debounced brake signal is first accepted, BEFORE the hit/bust scoring
-- that follows it runs -- if that scoring throws partway through, the
-- latch stays true forever (nothing else clears it), permanently
-- blocking pollLanding() from ever trying again until brakes are
-- physically released and re-engaged. This resets it to a clean,
-- retriable state so a transient error does not become a permanent stuck
-- state on top of whatever the original bug was.
function core.recoverFromWakeupError()
  S.landingActive = false
  S.landingCalls = 0
  S.relaunchCalls = 0
end

-- ---------------------------------------------------------------- game lifecycle

local function newBet(idx)
  return { idx = idx, target_s = nil, result = "pending", attempts = 0, scored_s = 0, allIn = false }
end

function core.startGame()
  local g = {
    startTs   = os.time(),
    deadline  = os.time() + S.setupWindow,
    windowS   = S.setupWindow,
    betCount  = S.setupBets,
    bets      = {},
    idx       = 1,
    score     = 0,
    armed     = false,       -- true once a bet is locked, waiting for launch/outcome
    allInPending = false,    -- true if ALL IN was pressed but not yet launched
    editMin   = 0,
    editSec   = 30,
  }
  for i = 1, g.betCount do g.bets[i] = newBet(i) end
  S.game = g
  S.screen = SCREEN.LIVE
end

local function currentBet()
  if not S.game then return nil end
  return S.game.bets[S.game.idx]
end

-- +MIN/+SEC act on the setup window fields (S1) or the current bet's edit
-- fields (S2), depending on what is on screen and whether a bet is armed
-- (armed = locked, bumping does nothing further, per spec S4 step 4).
local function adjustTarget(deltaMin, deltaSec)
  if S.screen == SCREEN.SETUP then
    S.setupWindow = math.max(60, S.setupWindow + deltaMin * 60 + deltaSec)
    return
  end
  local g = S.game
  if not g or g.armed then return end
  local total = g.editMin * 60 + g.editSec + deltaMin * 60 + deltaSec
  if total < 0 then total = 0 end
  g.editMin = math.floor(total / 60)
  g.editSec = total % 60
end

function core.bumpMin() adjustTarget(1, 0) end
function core.bumpSec() adjustTarget(0, 10) end

-- Decrement counterparts (pilot request, 2026-09): FS1/FS2 and the
-- footer MIN/SEC keys can only count up -- a touch pilot had no way to
-- walk a value back down short of the hold-to-reset gesture, which zeros
-- the whole field rather than nudging it. adjustTarget already takes a
-- signed delta and applies the same SETUP-vs-bet-edit dispatch and floor
-- (0, or SETUP's 60s) either way, so these are just the negative calls --
-- no new clamping logic needed.
function core.bumpMinDown() adjustTarget(-1, 0) end
function core.bumpSecDown() adjustTarget(0, -10) end

-- Hold-to-reset (S5.1): zero whichever field +MIN/+SEC currently affects.
-- Split into two, one per field (Defect 3): holding +MIN must zero only
-- the minutes portion, leaving seconds untouched, and vice versa for
-- +SEC -- a single shared reset function couldn't tell which field the
-- pilot actually meant to clear.
function core.resetMin()
  if S.screen == SCREEN.SETUP then
    S.setupWindow = S.setupWindow % 60   -- keep seconds, zero minutes
    return
  end
  local g = S.game
  if not g or g.armed then return end
  g.editMin = 0
end

function core.resetSec()
  if S.screen == SCREEN.SETUP then
    S.setupWindow = math.floor(S.setupWindow / 60) * 60   -- keep minutes, zero seconds
    return
  end
  local g = S.game
  if not g or g.armed then return end
  g.editSec = 0
end

-- Wraps rather than clamps: FS3 is now the only control for this (short
-- press only, no decrement), so clamping at 5 would leave no way back down
-- to a lower count without a second control that does not exist.
function core.bumpBets(delta)
  if S.screen ~= SCREEN.SETUP then return end
  S.setupBets = ((S.setupBets - 1 + delta) % 5) + 1
end

-- ALL IN (FS3, S8): marks the bet as a claim. The real number is computed
-- at the MOM_LAUNCH edge, not here -- see handleLaunchEdge() -- so a slow
-- walk to the flight line can never over-claim.
function core.allIn()
  local g = S.game
  if not g or g.armed then return end
  g.armed = true
  g.allInPending = true
  S.flightConfirmed = false
  S.prevZoomConfirm = nil
  local bet = currentBet()
  bet.allIn = true
  core.setStatus("all in")
end

-- CANCEL (armed -> back to editing): only meaningful before the first
-- launch of this bet; once a launch has actually happened the bet is
-- locked for real (retries use the same target, S4 step 6).
function core.cancelArm()
  local g = S.game
  if not g or not g.armed then return end
  local bet = currentBet()
  if bet.attempts > 0 then return end   -- already launched at least once; too late
  g.armed = false
  g.allInPending = false
  bet.target_s = nil
  bet.allIn = false
end

local function finalizeGame()
  local g = S.game
  if not g then return end
  for i = g.idx, g.betCount do
    local b = g.bets[i]
    if b.result == "pending" then b.result = "unresolved" end
  end
  -- Hit count, added as a 6th field -- the log's "X/Y" bets display was
  -- hardcoding X to 0, a leftover stub invisible until readRows() itself
  -- got fixed and rows could actually render at all. Appended rather than
  -- inserted, so the one pre-existing row from before this fix (5 fields)
  -- still parses fine -- recentGames() below treats a missing 6th field
  -- as "unknown" rather than erroring on an old row.
  local hits = 0
  for i = 1, g.betCount do
    if g.bets[i].result == "hit" then hits = hits + 1 end
  end
  appendRow("games", {
    tostring(g.startTs), tostring(g.windowS), tostring(g.betCount),
    tostring(g.score), "1", tostring(hits),
  })
  for i = 1, g.betCount do
    local b = g.bets[i]
    appendRow("bets", {
      tostring(g.startTs), tostring(b.idx), tostring(b.target_s or 0),
      b.result, tostring(b.attempts), tostring(b.scored_s),
    })
  end
  -- Don't leave the last bet's countdown running in the background --
  -- Timer3's own countingSource is "always counts" (AUTOCFG), so with
  -- nothing to stop it, it would otherwise keep ticking (and alerting on
  -- whatever thresholds are configured in SYSTEM > TIMERS) long after the
  -- pilot has left this game, requiring a manual reset on the radio's own
  -- timer screen to clear.
  timerSet(0)
  timerReset()
  S.screen = SCREEN.SUMMARY
end

local function advanceBet()
  local g = S.game
  g.armed = false
  g.allInPending = false
  g.editMin, g.editSec = 0, 30
  if g.idx >= g.betCount then
    finalizeGame()
  else
    g.idx = g.idx + 1
  end
end


-- ---------------------------------------------------------------- launch (revised, field-tested)

-- Revised model, superseding the original ZOOM_MODE-based false-start
-- design (S6.6) after real hardware testing showed it started the timer
-- at the wrong physical moment: the ORIGINAL design reset/started the
-- countdown on MOM_LAUNCH's RISING edge -- the moment the pilot first
-- grips the switch, while still winding up, well before the model
-- actually leaves the hand. The real throw happens at RELEASE.
--
-- Confirmed correct model (matches the actual physical sequence):
--   press   (L: -100 -> 100)  = priming / winding up, not a launch yet.
--     If the bet has already had a real release (attempts > 0), this is
--     a re-grip -- reset the timer back to the full target immediately,
--     so a stale countdown from the previous attempt cannot keep running
--     while the pilot re-sets themselves to throw again.
--   release (L: 100 -> -100)  = the actual throw. THIS starts the timer
--     for real and counts as an attempt.
-- The elevator-push Zoom-exit gesture deliberately does nothing to the
-- timer either way -- it should just keep counting through it.
--
-- This no longer needs ZOOM_MODE at all for the core state machine (it is
-- still resolved and shown on the S2 debug line for reference). A rising
-- edge occurring after a real release is already, by itself, sufficient
-- evidence of a re-grip -- there is no case where sampling ZOOM_MODE adds
-- information this simpler rule does not already have.

-- Landed-without-braking / relaunched-before-landing (pilot request,
-- 2026-09, field test). pollLanding() is the ONLY path that scores a hit
-- or bust via an actual landing (LANDING_MODE/brakes going active). If a
-- flight was confirmed (elevator push happened) but the pilot never
-- brakes -- either because they overshoot and just keep flying, or
-- because they go straight into another throw sequence -- LANDING_MODE
-- never fires: the bet used to stay "armed" with a still-latched
-- flightConfirmed forever, making a second throw sequence a permanent
-- no-op (the physical timer, never stopped or reset, just kept counting
-- straight through). Going through the throw sequence again is itself
-- the pilot's own unambiguous signal that the previous flight is over.
--
-- Two different responses depending on whether the target had already
-- been reached at the moment of the relaunch -- these turned out to be
-- genuinely different situations across two separate field reports, not
-- one rule that covers both:
--
-- STILL COUNTING (liveVal > 0): relaunched well before the target, timer
-- still actively counting -- almost certainly either a genuine new
-- attempt at the same bet or an accidental mid-flight switch bump. Busts
-- the old attempt and restarts the SAME target immediately, no extra
-- throw required -- see the "no alert" note below, this is the branch
-- that's guarded by pollRelaunchDebounce() specifically because it also
-- has to tolerate an accidental brush. Mechanically identical to the
-- ground re-grip path handleLaunchRise() already has for `not
-- S.flightConfirmed` -- clearing that flag here is what lets the same
-- "reset timer, wait for the release to actually start a fresh attempt"
-- logic run for a CONFIRMED flight too.
--
-- ALREADY REACHED (liveVal <= 0): the pilot flew for AT LEAST the full
-- target duration -- pilot request, 2026-09, fourth field-test round:
-- "the user succeeded" (ran the clock out) should score as a HIT and
-- advance to the next bet, the same as a real braked landing at/past the
-- target would (pollLanding()'s own hit branch, mirrored here). This is
-- NOT the still-counting branch's situation -- there's no ambiguity about
-- accidental brushes to tolerate once the target's already been reached,
-- so no debounce concern applies here, and the audible/haptic alert
-- (removed from the still-counting branch above, per a separate report
-- about accidental brushes specifically) stays for THIS branch --
-- pilot-confirmed, 2026-09: that removal was scoped too broadly and
-- shouldn't have touched this case.
--
-- S.suppressNextAutoConfirm is still needed on this branch even though
-- it now advances rather than un-arming to the SAME bet: the pilot is
-- still physically mid-throw when this fires (the debounce-free rising
-- edge, or shortly after), with no realistic pause to look at and adjust
-- bet N+1's own target before the tail end of THIS SAME throw's release
-- would otherwise auto-confirm it sight-unseen at whatever default
-- advanceBet() just reset editMin/editSec to. Suppressing that one
-- release keeps the same "land cleanly on the new bet's editing screen,
-- a genuinely separate throw is what starts it" behavior a real landed
-- hit already gives via pollLanding() -> advanceBet().
local function autoBustUnresolvedFlight()
  local g = S.game
  if not g or not g.armed then return end
  if not S.flightConfirmed then return end
  local bet = currentBet()
  if bet.result ~= "pending" then return end   -- already hit/bust -- nothing to auto-resolve

  local liveVal = timerValue()
  if liveVal == nil or liveVal > 0 then
    -- Still counting -- bust, restart the same target. No alert here
    -- (pilot request, 2026-09, third field-test round): this is the
    -- branch pollRelaunchDebounce() guards against an accidental brush,
    -- and once a brush that short can't even reach this function, a
    -- deliberate hold doesn't need an alarm either.
    bet.result = "bust"
    S.flightConfirmed = false
    S.prevZoomConfirm = nil
    timerSet(bet.target_s)
    timerReset()
    return
  end

  -- Already reached -- score as a hit and advance, same as a real landed
  -- hit (pollLanding()'s own hit branch).
  bet.result = "hit"
  bet.scored_s = bet.target_s
  g.score = (g.score or 0) + (bet.target_s or 0)
  S.flightConfirmed = false
  S.prevZoomConfirm = nil
  S.suppressNextAutoConfirm = true
  core.setStatus("hit")
  -- Alert restored for this branch specifically (pilot correction,
  -- 2026-09: the earlier removal was scoped to the still-counting branch
  -- only) -- system.playTone/playHaptic confirmed present since Ethos
  -- 1.1.0, pcall-wrapped the same defensive way every other native call
  -- in this file already is.
  pcall(function() system.playTone(600, 150, 120) end)
  pcall(function() system.playTone(600, 150) end)
  pcall(function() system.playHaptic(300) end)
  advanceBet()
end

-- Debounces MOM_LAUNCH itself while a bet is genuinely mid-flight (armed,
-- confirmed, unresolved) -- pilot request, 2026-09, third field-test
-- round: "the user could brush up against the launch button but won't
-- hold it for say, more than a third of a second... just let them
-- continue the flight." Previously autoBustUnresolvedFlight() ran on the
-- very first rising edge of MOM_LAUNCH, so a brush that lasted a single
-- frame busted the attempt just as surely as a deliberate relaunch.
--
-- Same level-based call-counting pattern pollLanding() already uses for
-- LANDING_MODE, for the exact same reason (S6.4: os.time() can't resolve
-- sub-second durations -- two samples well under a second apart can floor
-- to the identical integer second). Deliberately watches the switch's
-- LEVEL every wakeup(), not its edge -- handleLaunchRise()/
-- handleLaunchFall() no longer call autoBustUnresolvedFlight() at all;
-- this is now the ONLY path into it. Held below the threshold and
-- released: S.relaunchCalls resets to 0 and NOTHING happens -- no bust,
-- no timer change, no alert, exactly as if the touch never occurred.
-- Held past the threshold: autoBustUnresolvedFlight() fires immediately
-- (while the switch may still be held), and the EXISTING
-- handleLaunchRise()/handleLaunchFall() logic -- unchanged below --
-- already knows what to do with the resulting state (armed+unconfirmed
-- restarts as a fresh attempt on release; un-armed+suppressed lands
-- cleanly on the editing screen) once the switch's eventual rise/fall
-- edges are processed.
local function pollRelaunchDebounce()
  local g = S.game
  if not g or not g.armed or not S.flightConfirmed then
    S.relaunchCalls = 0
    return
  end
  local bet = currentBet()
  if bet.result ~= "pending" or not S.launchSrc then
    S.relaunchCalls = 0
    return
  end

  local v = srcValue(S.launchSrc)
  local active = v and v > 0

  if active then
    S.relaunchCalls = S.relaunchCalls + 1
    if S.relaunchCalls >= secondsToCalls(S.cfg.relaunchDebounce or (1 / 3)) then
      autoBustUnresolvedFlight()
      -- Left non-zero deliberately: autoBustUnresolvedFlight()'s own
      -- `bet.result ~= "pending"` guard already makes every further call
      -- this same hold a no-op, so there is nothing to reset until the
      -- switch actually goes inactive below.
    end
  else
    S.relaunchCalls = 0
  end
end

local function handleLaunchRise()
  local g = S.game
  if not g or not g.armed then return end
  -- autoBustUnresolvedFlight() is no longer called from here -- see
  -- pollRelaunchDebounce(), the only caller now. This early-return still
  -- does the right thing on its own while genuinely mid-flight
  -- (S.flightConfirmed true): the debounce poller is what decides
  -- whether a relaunch happened at all, so this function does nothing
  -- until either the flight is un-confirmed (ground re-grip, handled
  -- below) or the debounce poller has already busted the old attempt
  -- (which clears S.flightConfirmed itself, letting this fall through).
  -- Once the elevator-exit gesture has confirmed a real flight, the
  -- countdown is locked in -- a press can no longer reset it. Physically
  -- there is no way to re-grip a flying glider, and once confirmed, only
  -- brakes (pollLanding, gated on this same flag) can end the attempt.
  if S.flightConfirmed then return end
  if g.allInPending then return end   -- no concrete target yet to reset to
  local bet = currentBet()
  timerSet(bet.target_s)
  timerReset()
  S.prevZoomConfirm = nil     -- force a fresh baseline after the next release
  if bet.attempts > 0 then
    core.setStatus("reset - waiting for launch")
  end
end

local function handleLaunchFall()
  local g = S.game
  if not g then return end
  if not g.armed then
    if S.suppressNextAutoConfirm then
      -- This release is the tail end of the same throw whose hold just
      -- triggered autoBustUnresolvedFlight() via pollRelaunchDebounce()
      -- -- land cleanly on the editing screen instead of using it to
      -- auto-arm right back.
      S.suppressNextAutoConfirm = false
      return
    end
    -- Auto-confirm (pilot request, 2026-09): CONFIRM used to be a
    -- separate required press before a throw did anything. Now the throw
    -- itself IS the confirmation -- releasing while still on the editing
    -- screen locks in whatever MIN:SEC was showing at that instant and
    -- arms the bet, in one motion, at the exact same instant the timer
    -- actually starts (matching how a confirmed bet's first launch has
    -- always worked). ALL IN is unaffected -- it's still its own explicit
    -- pre-throw action (core.allIn(), g.armed already true by the time a
    -- throw happens), so this branch only fires for a direct throw.
    local editBet = currentBet()
    editBet.target_s = g.editMin * 60 + g.editSec
    if editBet.target_s <= 0 then return end   -- nothing to bet, ignore (same guard confirmBet used to have)
    g.armed = true
    g.allInPending = false
    S.flightConfirmed = false
    S.prevZoomConfirm = nil
  end
  -- autoBustUnresolvedFlight() is no longer called from here either --
  -- see pollRelaunchDebounce(). If the debounce poller already busted
  -- the old attempt this same hold (still-counting case), g.armed is
  -- still true and S.flightConfirmed is already false by the time this
  -- release fires, so the fall-through below correctly starts a fresh
  -- attempt. If it un-armed instead (target-reached case),
  -- S.suppressNextAutoConfirm caught this release already, above.
  if not g.armed then return end
  -- Same lock-in as handleLaunchRise: once confirmed, the launch switch
  -- has no further effect on the timer at all, deliberately, even a
  -- spurious release signal.
  if S.flightConfirmed then return end
  local bet = currentBet()

  -- Keyed on bet.allIn (a permanent flag on the bet), not g.allInPending
  -- (which only reflects "hasn't launched even once yet" and goes false
  -- after the first release). Confirmed bug: a bust-and-retry on an
  -- all-in bet was keeping the FIRST attempt's target forever, so real
  -- time burned during the failed attempt was never accounted for -- the
  -- bet's own timer could silently outlast the game's remaining window.
  -- Every release is itself a fresh "moment of launch" for an all-in bet,
  -- so every release recomputes against the CURRENT remaining time.
  if bet.allIn then
    local remaining = g.deadline - os.time()
    local target = math.floor(remaining / 10) * 10
    if target < 10 then target = 10 end
    bet.target_s = target
    g.allInPending = false
  end

  timerSet(bet.target_s)
  timerReset()
  bet.attempts = bet.attempts + 1
  bet.result = "pending"   -- clears a stale BUST/HIT label from a previous
                            -- attempt at this same bet -- the exact moment
                            -- described: press primes, RELEASE is what
                            -- should flip the display green and start the
                            -- live countdown, whether this is the first
                            -- attempt or a retry after a bust
  S.flightConfirmed = false   -- fresh attempt, not yet confirmed in flight
  -- Baseline captured RIGHT NOW, at the moment of release -- not left over
  -- from whatever ZOOM_MODE happened to read at some earlier, unrelated
  -- point. ZOOM_MODE should read active here (release is the moment the
  -- model enters Zoom), so the next genuine falling edge is what
  -- pollZoomConfirm() below needs to detect.
  S.prevZoomConfirm = srcValue(S.zoomSrc)
  core.setStatus(nil)
end

-- Watches for ZOOM_MODE's exit transition (true -> false), the elevator
-- push/pull gesture that means the model has actually left Zoom and
-- entered a real flight mode. Only meaningful mid-attempt (attempts > 0,
-- still armed) -- confirms this specific release was a genuine flight, not
-- ground fumbling, before pollLanding() will trust any landing signal.
local function pollZoomConfirm()
  local g = S.game
  if not g or not g.armed then return end
  local bet = currentBet()
  if bet.attempts <= 0 then return end
  if not S.zoomSrc then return end
  local zv = srcValue(S.zoomSrc)
  if zv == nil then return end
  local falling = (S.prevZoomConfirm ~= nil and S.prevZoomConfirm > 0 and zv <= 0)
  S.prevZoomConfirm = zv
  if falling and not S.flightConfirmed then
    S.flightConfirmed = true
  end
end

-- ---------------------------------------------------------------- landing (S6.4)

-- Lua-timed default: read LANDING_MODE directly, debounce with the exact
-- mechanism already proven in Poker Probe's L:/A:/B: dwell counters. No
-- radio-side logic switch required for the default path.
-- Lua-timed default: read LANDING_MODE directly, debounce with call
-- counting (see wakeup-rate calibration above) rather than os.time() --
-- confirmed necessary, not just theoretical, by a functional test that
-- caught this exact failure mode before it ever reached hardware: two
-- samples well under a second apart can floor to the identical os.time()
-- integer second, reading a dwell of zero regardless of how close the
-- real elapsed time is to the debounce threshold.
local function pollLanding()
  local g = S.game
  if not g or not g.armed then return end
  local bet = currentBet()
  -- Defect 4: a bet only starts being eligible for a landing/bust once it
  -- has actually seen a real launch (attempts > 0). Without this gate,
  -- brakes already deployed at arm time -- entirely plausible, since
  -- brakes commonly stay applied after landing the previous flight, right
  -- up until the pilot arms the next bet -- read as an instant landing
  -- before the model ever left the ground, silently scoring a bet that
  -- was never actually flown. The DLG template's own LND_BLOCKED already
  -- protects the equivalent window *during* a launch/zoom; this closes
  -- the gap *before* the first launch of a fresh bet, which that
  -- mechanism was never designed to cover.
  if bet.attempts <= 0 then return end
  -- Extends the same protection to ground fumbling AFTER a release, not
  -- just before one: pressing and releasing a couple of times while still
  -- on the ground already increments attempts and starts the timer (as it
  -- should -- that is a real, if aborted, attempt), but a landing signal
  -- during that fumbling should not score anything either, until the
  -- elevator-exit gesture has actually confirmed a real flight happened
  -- since the most recent release. See handleLaunchFall()/pollZoomConfirm().
  --
  -- Relaxed once the target is actually reached (timer at or below zero):
  -- confirmed on real hardware to otherwise strand a pilot who reaches
  -- the full target and brakes without ever doing a deliberate elevator
  -- wag first -- a completely plausible short flight, not fumbling. By
  -- the time the timer has counted all the way down, genuine wall-clock
  -- seconds have elapsed, which is itself enough to rule out ground
  -- fumbling regardless of whether the elevator gesture happened. Before
  -- the target is reached, the original protection is unchanged -- this
  -- only ever opens the HIT path (a still-positive timer always needs
  -- confirmation to register even a bust), so early ground-fumbling
  -- protection is not weakened at all.
  local liveVal = timerValue()
  if not S.flightConfirmed and (liveVal == nil or liveVal > 0) then return end
  if not S.landingSrc then return end

  local v = srcValue(S.landingSrc)
  local active = v and v > 0

  if active then
    S.landingCalls = S.landingCalls + 1
    if not S.landingActive and S.landingCalls >= secondsToCalls(S.cfg.landingDebounce or 1.0) then
      S.landingActive = true
      -- Debounced landing signal fires exactly once per touch-down.
      -- Wrapped precisely around the scoring itself: more targeted than
      -- the outer wakeup()-level wrapper in main.lua -- isolates exactly
      -- this block if something in it throws, resets the debounce latch
      -- immediately (not waiting for a whole failed cycle), and lets the
      -- rest of THIS SAME wakeup() call keep running normally afterward.
      local scoreOk, scoreErr = pcall(function()
        local val = timerValue()
        if val and val <= 0 then
          bet.result = "hit"
          bet.scored_s = bet.target_s
          g.score = (g.score or 0) + (bet.target_s or 0)
          core.setStatus("hit")
          -- Auto-advance straight to the next bet (pilot request, 2026-09:
          -- "100% of users hit NEXT BET anyway"). This used to be skipped
          -- deliberately -- advanceBet() here once meant "hit" got
          -- overwritten in the same cycle, so a dedicated HIT screen never
          -- actually rendered before the pilot could see it. That's no
          -- longer a problem because the render side moved too:
          -- screen.lua's editing screen now shows "BET N: HIT +Ns" for
          -- whichever bet just resolved (g.idx - 1) right alongside the
          -- new bet's own editing controls, so the credit is still shown
          -- -- just without a screen that blocks on an explicit press.
          advanceBet()
        else
          bet.result = "bust"
          S.flightConfirmed = false   -- the retry gets its own fresh
          S.prevZoomConfirm = nil     -- press/release/elevator-exit cycle
          -- Silences the countdown immediately rather than leaving it
          -- running/alerting on a failed attempt -- it kept counting
          -- (and could keep beeping on whatever thresholds are configured
          -- in SYSTEM > TIMERS) all the way to zero and beyond otherwise,
          -- with nothing else stopping it until the retry's own release.
          -- The retry's own handleLaunchFall() sets it back to the real
          -- target the moment a genuine relaunch happens.
          timerSet(0)
          timerReset()
          core.setStatus("bust - relaunch to retry")
          -- stays armed; next MOM_LAUNCH edge retries the same locked target
        end
      end)
      if not scoreOk then
        S.landingActive = false
        S.landingCalls = 0
        core.setStatus("scoring error - see log: " .. tostring(scoreErr))
      end
    end
  else
    S.landingCalls  = 0
    S.landingActive = false
  end
end

-- ---------------------------------------------------------------- generic switch polling

-- Shared by +MIN/+SEC (short press = bump, hold = reset to 0) and
-- ALL IN/CONFIRM (short press only). Also feeds the stuck-switch detector
-- (S6.5): any assigned control reading continuously active longer than
-- cfg.stuckWarnThreshold likely means Function Switches is in a latching
-- mode rather than Momentary.
--
-- Short-press vs hold is resolved on RELEASE, not on the rising edge: the
-- short-press action only fires if the press never escalated into a hold.
-- Firing bump-on-press and reset-on-hold independently would double-act on
-- a single long press (bump, then immediately reset) -- this way a hold
-- fully replaces the short-press action rather than stacking with it.
-- Same call-counting fix as pollLanding above, for the same reason: the
-- default hold-to-reset threshold (0.8s) and even the stuck-switch
-- threshold (2.0s) are close enough to os.time()'s one-second floor that
-- a real press could be measured as zero elapsed seconds.
local function pollRole(role, src, onShortPress, hasHold, onHold)
  -- Lazily initialised rather than requiring perfect pre-registration in
  -- S.switches above -- confirmed a real crash from exactly this gap
  -- (three new role names added without a matching S.switches entry).
  -- Self-healing for any future new role rather than a second silent trap.
  local st = S.switches[role]
  if not st then
    st = { prev = -100, activeCalls = 0, resetFired = false, pendingShort = false, warned = false }
    S.switches[role] = st
  end
  if not src then return end
  local v = srcValue(src)
  if v == nil then return end
  local active = v > 0
  local rising  = (st.prev <= 0 and active)
  local falling = (st.prev > 0 and not active)
  st.prev = v

  if rising then
    st.activeCalls  = 0
    st.resetFired   = false
    st.pendingShort = true
  end

  if active then
    st.activeCalls = st.activeCalls + 1

    if hasHold and not st.resetFired and st.activeCalls >= secondsToCalls(S.cfg.holdResetThreshold or 0.8) then
      st.resetFired   = true
      st.pendingShort = false   -- hold replaces the short-press action
      onHold()
    end

    if st.activeCalls >= secondsToCalls(S.cfg.stuckWarnThreshold or 2.0) and not st.warned then
      st.warned = true
      core.setStatus(role .. " stuck? check Function Switches = Momentary")
    end
  end

  if falling then
    if st.pendingShort then onShortPress() end
    st.activeCalls  = 0
    st.pendingShort = false
    st.warned       = false
  end
end

-- ---------------------------------------------------------------- lifecycle

function core.init()
  if S.ready then return end
  S.dir = resolveDir()
  if not S.dir then S.ioError = "no writable Files/ folder" end
  loadConfig()

  resolveTimer()
  autoConfigTimer()

  S.launchSrc  = getLogic("MOM_LAUNCH")
  S.zoomSrc    = getLogic("ZOOM_MODE")
  local landingName = (S.cfg.landingMode == "native") and "LANDED_STABLE" or (S.cfg.landingSwitchName or "LANDING_MODE")
  S.landingSrc = getLogic(landingName)

  core.resolveSwitches()

  S.setupWindow = S.cfg.windowDefault or 600
  S.setupBets   = S.cfg.betsDefault or 3

  S.ready = true
end

-- Re-resolves all four control-role switches from their persisted names.
-- Called at init(), and callable again from config.lua after the pilot
-- changes a name in S5, so a hand-typed correction takes effect without
-- needing a full tool restart.
function core.resolveSwitches()
  S.minSwitchSrc     = resolveSwitchByName(S.cfg.minSwitchName)
  S.secSwitchSrc     = resolveSwitchByName(S.cfg.secSwitchName)
  S.allinSwitchSrc   = resolveSwitchByName(S.cfg.allinSwitchName)
  S.confirmSwitchSrc = resolveSwitchByName(S.cfg.confirmSwitchName)
end

function core.wakeup()
  if not S.ready then return end
  updateWakeupCalib()

  -- ZOOM_MODE is still sampled purely for the S2 debug readout (Z=) --
  -- the core launch state machine no longer depends on it (see the
  -- "launch (revised, field-tested)" section above).
  if S.zoomSrc then
    local zv = srcValue(S.zoomSrc)
    if zv then S.prevZoom = zv end
  end

  -- Launch press/release, edge-detected the same way as everywhere else
  -- in this ecosystem: sample, compare, fire on the transition. Press
  -- (rising) primes/resets; release (falling) is the actual throw and is
  -- what starts the timer -- see the section above for why this replaced
  -- the original rising-edge-only design.
  if S.launchSrc then
    local v = srcValue(S.launchSrc)
    if v then
      local rising  = (S.prevLaunch <= 0 and v > 0)
      local falling = (S.prevLaunch > 0 and v <= 0)
      S.prevLaunch = v
      if rising then handleLaunchRise() end
      if falling then handleLaunchFall() end
    end
  end

  pollRelaunchDebounce()
  pollZoomConfirm()
  pollLanding()

  -- Game window expiring while a bet is still armed/mid-flight -- end the
  -- game rather than let it run past the working time silently.
  if S.game and os.time() >= S.game.deadline and S.screen == SCREEN.LIVE then
    finalizeGame()
  end

  -- Function switches do something different depending on the screen --
  -- previously this was a single blanket guard that blocked FS1-4
  -- entirely outside SETUP/LIVE, which correctly fixed the CONFIRM-on-
  -- SUMMARY bug but went too far: it also silently disabled FS1/FS4 on
  -- SUMMARY and LOG, even though their on-screen buttons are visually
  -- FS1/FS4-aligned (VIEW GAME LOG / NEW GAME, OPEN / BACK) and imply
  -- they work. Each screen now gets only the roles that make sense on it.
  if S.screen == SCREEN.SUMMARY then
    pollRole("viewlog", S.minSwitchSrc, function()
      S.screen = SCREEN.LOG
    end, false, nil)
    pollRole("newgame", S.confirmSwitchSrc, function()
      S.game = nil
      S.screen = SCREEN.SETUP
    end, false, nil)
    return
  end
  if S.screen == SCREEN.LOG then
    -- FS1 has no functionality here -- OPEN (viewing a single game's
    -- detail breakdown, never built) was removed from the footer
    -- entirely (pilot request, 2026-09; see screen.lua's keysFor).
    pollRole("back", S.confirmSwitchSrc, function()
      S.screen = SCREEN.SUMMARY
    end, false, nil)
    return
  end
  if S.screen ~= SCREEN.SETUP and S.screen ~= SCREEN.LIVE then return end

  pollRole("min", S.minSwitchSrc, core.bumpMin, true, core.resetMin)
  pollRole("sec", S.secSwitchSrc, core.bumpSec, true, core.resetSec)
  -- FS3 is context-sensitive, same pattern as FS4/confirm below: on the
  -- setup screen (no game running yet) it cycles the bet count, since
  -- rotary+enter already highlights key focus rather than adjusting a
  -- value directly and BETS had no dedicated physical control before this.
  -- Once a game is live, it reverts to its other job, ALL IN.
  -- FS3 hold resets bets back to the floor (1) -- short-press-only cycling
  -- with no decrement meant overshooting past 5 had no quick way back to
  -- a lower count except wrapping all the way around.
  pollRole("allin", S.allinSwitchSrc, function()
    if S.screen == SCREEN.SETUP then core.bumpBets(1) else core.allIn() end
  end, true, function()
    if S.screen == SCREEN.SETUP then S.setupBets = 1 end
  end)
  -- FS4 is context-sensitive same as FS3: START on the setup screen (no
  -- game running yet), otherwise its existing confirm/cancel job. This was
  -- missing entirely before -- FS4 always ran the LIVE-screen logic, which
  -- silently no-ops when there is no game yet, so START never fired.
  -- FS4/"confirm" no longer arms a bet (pilot request, 2026-09) -- a
  -- throw does that now, see handleLaunchFall()'s auto-confirm branch. A
  -- hit auto-advances now too (see pollLanding's scoring block), so this
  -- role no longer has a NEXT BET job either. What's left: START on
  -- SETUP, and on LIVE, CANCEL (only reachable pre-throw via ALL IN,
  -- which still arms explicitly ahead of the throw). Not-yet-armed on
  -- LIVE has nothing for FS4 to do at all.
  pollRole("confirm", S.confirmSwitchSrc, function()
    if S.screen == SCREEN.SETUP then
      core.startGame()
      return
    end
    if S.screen ~= SCREEN.LIVE then return end
    core.cancelArm()
  end, false, nil)
end

-- ---------------------------------------------------------------- log reads

function core.recentGames(limit)
  local rows = readRows("games")
  local out = {}
  for i = #rows, 1, -1 do
    out[#out + 1] = {
      ts = tonumber(rows[i][1]) or 0,
      windowS = tonumber(rows[i][2]) or 0,
      betCount = tonumber(rows[i][3]) or 0,
      score = tonumber(rows[i][4]) or 0,
      complete = rows[i][5] == "1",
      hits = tonumber(rows[i][6]),   -- nil for rows written before this
                                       -- field existed -- screen.lua shows
                                       -- betCount alone (no "X/") for those
    }
    if limit and #out >= limit then break end
  end
  return out
end

function core.betsForGame(ts)
  local rows = readRows("bets")
  local out = {}
  for i = 1, #rows do
    if tonumber(rows[i][1]) == ts then
      out[#out + 1] = {
        idx = tonumber(rows[i][2]), target_s = tonumber(rows[i][3]),
        result = rows[i][4], attempts = tonumber(rows[i][5]),
        scored_s = tonumber(rows[i][6]),
      }
    end
  end
  return out
end

-- avg (last 5) and best ever, per S4/S9 -- computed at read time, never
-- cached, so they can never go stale.
function core.gameStats()
  local games = core.recentGames(nil)
  local complete = {}
  for i = 1, #games do if games[i].complete then complete[#complete + 1] = games[i] end end
  local avg5, best = nil, nil
  if #complete > 1 then
    local n = math.min(5, #complete - 1)
    local sum = 0
    for i = 2, n + 1 do sum = sum + complete[i].score end
    avg5 = sum / n
  end
  for i = 1, #complete do
    if not best or complete[i].score > best then best = complete[i].score end
  end
  return avg5, best
end

return core

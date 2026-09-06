-- Test harness for Poker Timer core.lua. Runs against the REAL Lua
-- interpreter with REAL io (against a scratch Files/ dir) but STUBBED
-- Ethos globals and a FAKE, fully-controllable clock.
--
-- Duration checks (landing debounce, hold-to-reset, stuck-switch) are
-- call-counted against a calibrated wakeup() rate, not raw os.time()
-- deltas -- this harness itself is what proved a raw os.time() approach
-- was broken (two samples 0.6s apart can floor to the same integer
-- second), so it has to simulate a realistic polling loop -- repeated
-- wakeup() calls at a fixed rate -- rather than one call after a clock
-- jump, or it would not actually be testing the thing it is meant to.

local fakeClock = 1000000
os.time = function() return math.floor(fakeClock) end
local function tick(seconds) fakeClock = fakeClock + seconds end

CATEGORY_LOGIC_SWITCH = "logic"

local sourceValues = {}
local function setSrc(name, v) sourceValues[name] = v end
local function makeSource(name)
  return {
    value = function(self) return sourceValues[name] or -100 end,
    name  = function(self) return name end,
  }
end
system = { getSource = function(spec) if spec.name then return makeSource(spec.name) end return nil end }

-- Getter vs setter resolved by ARGUMENT COUNT, not value -- core.lua calls
-- countingSource(nil) to mean "set to nil", bench-confirmed as a real
-- setter call on hardware in Poker Probe; a value-based check cannot tell
-- that apart from a no-argument getter call.
local fakeTimers = {}
local function makeTimer(name)
  local t = { _start = 0, _value = 0, _dir = 1, _cs = "unset", _lastTick = fakeClock }
  return {
    start = function(self, ...) if select("#", ...) == 0 then return t._start else t._start = ... end end,
    value = function(self, ...)
      if t._dir == -1 and t._cs == nil then
        t._value = t._value - (fakeClock - t._lastTick)
      end
      t._lastTick = fakeClock
      if select("#", ...) == 0 then return t._value else t._value = ... end
    end,
    reset = function(self) t._value = t._start t._lastTick = fakeClock end,
    direction = function(self, ...) if select("#", ...) == 0 then return t._dir else t._dir = ... end end,
    countingSource = function(self, ...) if select("#", ...) == 0 then return t._cs else t._cs = ... end end,
  }
end
model = { getTimer = function(name)
  if not fakeTimers[name] then fakeTimers[name] = makeTimer(name) end
  return fakeTimers[name]
end }

local core = dofile("core.lua")

local failures = 0
local function check(label, cond, detail)
  if cond then print("OK   " .. label)
  else failures = failures + 1 print("FAIL " .. label .. (detail and (" -- " .. detail) or "")) end
end

-- Pumps N seconds of simulated real time through wakeup() at a fixed
-- 40 calls/sec -- matching the confirmed order of magnitude from Poker
-- Probe's own wakeup-rate calibration (S6.4a: ~52/s X14, ~40.3/s X20RS).
local RATE = 40
local function pump(seconds)
  local n = math.floor(seconds * RATE + 0.5)
  for i = 1, n do
    tick(1 / RATE)
    core.wakeup()
  end
end

core.init()
core.S.wakeupRate = RATE   -- pin calibration to a known value for this
                            -- test run rather than waiting 3s for it to
                            -- self-calibrate through simulated time
check("init resolves timer", core.S.timerObj ~= nil)
check("timer autoconfigured to countdown", core.S.timerObj:direction() == -1)
check("timer countingSource cleared", core.S.timerObj:countingSource() == nil)

-- Defect 1: FS1-FS4 must resolve as DEFAULTS with no manual wiring at
-- all -- core.init() should already have called resolveSwitches() against
-- the persisted name defaults ("FS1".."FS4"). Deliberately NOT manually
-- assigning core.S.*SwitchSrc here, unlike earlier harness versions --
-- doing so would silently mask a regression in the auto-default path
-- itself, which is exactly the thing being fixed.
check("min switch defaulted to FS1", core.S.minSwitchSrc ~= nil)
check("sec switch defaulted to FS2", core.S.secSwitchSrc ~= nil)
check("allin switch defaulted to FS3", core.S.allinSwitchSrc ~= nil)
check("confirm switch defaulted to FS4", core.S.confirmSwitchSrc ~= nil)
check("MOM_LAUNCH resolved", core.S.launchSrc ~= nil)
check("ZOOM_MODE resolved", core.S.zoomSrc ~= nil)
check("LANDING_MODE resolved", core.S.landingSrc ~= nil)

for _, n in ipairs({"FS1","FS2","FS3","FS4","MOM_LAUNCH","ZOOM_MODE","LANDING_MODE"}) do setSrc(n, -100) end

core.startGame()
check("game started", core.S.game ~= nil)
check("default window", core.S.game.windowS == 600)
check("default bet count", core.S.game.betCount == 3)

-- ---- Test 1: bump min/sec via short press, confirm, launch resets timer

core.S.screen = core.SCREEN.LIVE
setSrc("FS1", 100); core.wakeup(); tick(0.05); setSrc("FS1", -100); core.wakeup()
check("bump min via short press", core.S.game.editMin == 1, tostring(core.S.game.editMin))

setSrc("FS2", 100); core.wakeup(); tick(0.05); setSrc("FS2", -100); core.wakeup()
check("bump sec via short press", core.S.game.editSec == 40, tostring(core.S.game.editSec))

setSrc("FS4", 100); core.wakeup(); tick(0.05); setSrc("FS4", -100); core.wakeup()
check("bet armed after confirm", core.S.game.armed == true)
check("bet target is 100s", core.S.game.bets[1].target_s == 100, tostring(core.S.game.bets[1].target_s))
check("timer start preloaded", core.S.timerObj:start() == 100)

-- ---- Test 1a: press primes (no attempt yet), release is the real launch
-- (revised model -- the ORIGINAL rising-edge-only design started the
-- countdown while the pilot was still winding up, before the model
-- actually left the hand; release is the real throw)

setSrc("MOM_LAUNCH", 100); core.wakeup()   -- press: priming only
check("press does NOT count as an attempt", core.S.game.bets[1].attempts == 0,
  "attempts=" .. tostring(core.S.game.bets[1].attempts))

setSrc("MOM_LAUNCH", -100); core.wakeup()  -- release: the actual throw
check("timer reset to target on release", core.S.timerObj:value() == 100, tostring(core.S.timerObj:value()))
check("attempts incremented on release", core.S.game.bets[1].attempts == 1,
  "attempts=" .. tostring(core.S.game.bets[1].attempts))
setSrc("ZOOM_MODE", 100)   -- latches true, same as a real press (Sticky)

-- ---- Test 1b: a re-grip (press again) after a real release resets the
-- timer immediately and shows the reset status, without touching attempts
-- again until the NEXT release

tick(3)   -- some time passes mid-"flight"
setSrc("MOM_LAUNCH", 100); core.wakeup()   -- re-press: a re-grip
check("timer reset immediately on re-press", core.S.timerObj:value() == 100,
  tostring(core.S.timerObj:value()))
check("re-press does not change attempts", core.S.game.bets[1].attempts == 1,
  "attempts=" .. tostring(core.S.game.bets[1].attempts))
check("reset status message set", core.status() == "reset - waiting for launch",
  tostring(core.status()))

setSrc("MOM_LAUNCH", -100); core.wakeup()  -- release again: a second real attempt
check("attempts incremented on second release", core.S.game.bets[1].attempts == 2,
  "attempts=" .. tostring(core.S.game.bets[1].attempts))

tick(2)
setSrc("ZOOM_MODE", -100); core.wakeup()   -- the elevator-exit gesture -- confirms flight
check("flight confirmed before this bust", core.S.flightConfirmed == true)

tick(3)
setSrc("LANDING_MODE", 100)
pump(0.6)   -- past the 0.5s default debounce, pumped at a realistic rate
check("bust recorded (timer still positive)", core.S.game.bets[1].result == "bust",
  tostring(core.S.game.bets[1].result))
check("still armed for retry after bust", core.S.game.armed == true)
setSrc("LANDING_MODE", -100); core.wakeup()

-- ---- Test 4: retry the same locked bet, this time it is a HIT

tick(1)
setSrc("MOM_LAUNCH", 100); core.wakeup()
setSrc("ZOOM_MODE", 100)
setSrc("MOM_LAUNCH", -100); core.wakeup()
check("attempts incremented on retry", core.S.game.bets[1].attempts == 3,
  "attempts=" .. tostring(core.S.game.bets[1].attempts))

tick(2)
setSrc("ZOOM_MODE", -100); core.wakeup()   -- confirm flight again for this attempt

tick(99)   -- let the full 100s target elapse (2s already ticked above)
setSrc("LANDING_MODE", 100)
pump(0.6)
check("hit recorded (timer at/below zero)", core.S.game.bets[1].result == "hit",
  tostring(core.S.game.bets[1].result))
check("score credited", core.S.game.score == 100, tostring(core.S.game.score))
check("hit stays on screen -- no auto-advance", core.S.game.idx == 1, tostring(core.S.game.idx))
check("still armed, showing the hit state", core.S.game.armed == true)
setSrc("LANDING_MODE", -100); core.wakeup()

setSrc("FS4", 100); core.wakeup(); tick(0.05); setSrc("FS4", -100); core.wakeup()
check("FS4 (nextBet) advances after a hit", core.S.game.idx == 2, tostring(core.S.game.idx))

-- ---- Test 5: hold-to-reset does not also fire a bump, and only touches
-- its OWN field (Defect 3: FS1 held was zeroing both minutes and seconds)

core.S.game.editMin, core.S.game.editSec = 2, 30
setSrc("FS1", 100)
pump(0.9)   -- past the 0.8s default hold threshold
setSrc("FS1", -100); core.wakeup()   -- release -- short-press must NOT also fire
check("FS1 hold zeroes minutes only", core.S.game.editMin == 0 and core.S.game.editSec == 30,
  string.format("min=%s sec=%s", tostring(core.S.game.editMin), tostring(core.S.game.editSec)))

core.S.game.editMin, core.S.game.editSec = 2, 30
setSrc("FS2", 100)
pump(0.9)
setSrc("FS2", -100); core.wakeup()
check("FS2 hold zeroes seconds only", core.S.game.editMin == 2 and core.S.game.editSec == 0,
  string.format("min=%s sec=%s", tostring(core.S.game.editMin), tostring(core.S.game.editSec)))
core.S.game.editMin, core.S.game.editSec = 0, 30

-- ---- Test 6: stuck-switch detection

setSrc("FS2", 100)
pump(2.1)
local st = core.status()
check("stuck-switch warning fires", st ~= nil and string.find(st, "stuck") ~= nil, tostring(st))
setSrc("FS2", -100); core.wakeup()

-- ---- Test 7: ALL IN computed at RELEASE (the actual throw), not at
-- press and not at the FS3 press that armed it

core.S.game.armed = false
core.S.game.allInPending = false
core.S.game.bets[2].attempts = 0
core.S.game.deadline = os.time() + 47

setSrc("FS3", 100); core.wakeup(); tick(0.05); setSrc("FS3", -100); core.wakeup()
check("all-in arms without a fixed target yet", core.S.game.armed == true and core.S.game.allInPending == true)

tick(6)   -- pilot takes 6s to actually walk out and throw
setSrc("MOM_LAUNCH", 100); core.wakeup()   -- press: still no concrete target
check("press alone does not compute the all-in target",
  core.S.game.bets[2].target_s == nil, tostring(core.S.game.bets[2].target_s))

setSrc("MOM_LAUNCH", -100); core.wakeup()  -- release: the actual throw
check("all-in target computed at release, not at press",
  core.S.game.bets[2].target_s == 40,   -- floor(41/10)*10
  "target_s=" .. tostring(core.S.game.bets[2].target_s))

-- ---- Test 8: brakes deployed before any real launch must NOT score
-- (Defect 4 -- brakes are commonly still down from the previous landing
-- right up until the next bet is armed)

core.S.game.armed = true
core.S.game.allInPending = false
core.S.game.idx = 2
core.S.game.bets[2] = { idx = 2, target_s = 50, result = "pending", attempts = 0, scored_s = 0, allIn = false }
setSrc("MOM_LAUNCH", -100)   -- never launched this bet
setSrc("LANDING_MODE", 100) -- brakes already down from before
pump(0.6)                    -- past the debounce
check("no scoring without a real launch first", core.S.game.bets[2].result == "pending",
  tostring(core.S.game.bets[2].result))
check("still armed, same bet, unresolved", core.S.game.armed == true and core.S.game.idx == 2)
setSrc("LANDING_MODE", -100); core.wakeup()

-- Now actually launch for real, then land -- confirms the gate only
-- blocks pre-launch brakes, not genuine post-launch landings.
setSrc("ZOOM_MODE", -100)
setSrc("MOM_LAUNCH", 100); core.wakeup()
setSrc("ZOOM_MODE", 100)
setSrc("MOM_LAUNCH", -100); core.wakeup()
check("attempts incremented by the real launch", core.S.game.bets[2].attempts == 1,
  "attempts=" .. tostring(core.S.game.bets[2].attempts))

tick(2)
setSrc("ZOOM_MODE", -100); core.wakeup()   -- confirm flight

tick(49)   -- let the 50s target elapse (2s already ticked above)
setSrc("LANDING_MODE", 100)
pump(0.6)
check("scores normally once a real launch has happened", core.S.game.bets[2].result == "hit",
  tostring(core.S.game.bets[2].result))
setSrc("LANDING_MODE", -100); core.wakeup()

-- ---- Test 9: bumpBets wraps (Defect: FS3 is the only bets control now,
-- no decrement -- clamping at 5 would strand the pilot with no way back
-- down to a lower count)

core.S.screen = core.SCREEN.SETUP
core.S.setupBets = 5
core.bumpBets(1)
check("bumpBets wraps from 5 back to 1", core.S.setupBets == 1, "setupBets=" .. tostring(core.S.setupBets))
core.bumpBets(1)
check("bumpBets increments normally otherwise", core.S.setupBets == 2, "setupBets=" .. tostring(core.S.setupBets))

-- ---- Test 10: FS3 hold resets bets back to 1

core.S.screen = core.SCREEN.SETUP
core.S.setupBets = 4
setSrc("FS3", 100)
pump(0.9)   -- past the 0.8s default hold threshold
setSrc("FS3", -100); core.wakeup()
check("FS3 hold resets bets to 1", core.S.setupBets == 1, "setupBets=" .. tostring(core.S.setupBets))

-- ---- Test 11: FS4 starts a new game from the setup screen (previously
-- always ran the LIVE-screen confirm/cancel logic instead, which silently
-- no-ops with no game yet -- START never fired)

core.S.game = nil
core.S.screen = core.SCREEN.SETUP
setSrc("FS4", 100); core.wakeup(); tick(0.05); setSrc("FS4", -100); core.wakeup()
check("FS4 starts a game from setup", core.S.game ~= nil)
check("screen switches to LIVE", core.S.screen == core.SCREEN.LIVE)

-- ---- Test 12: a landing signal after a release, but BEFORE the
-- elevator-exit gesture has confirmed a real flight, must not score --
-- ground fumbling (press, release, brakes still down from before) should
-- not falsely register a bust or hit just because attempts > 0

core.S.game.armed = true
core.S.game.allInPending = false
core.S.game.idx = 2
core.S.game.bets[2] = { idx = 2, target_s = 60, result = "pending", attempts = 0, scored_s = 0, allIn = false }
core.S.flightConfirmed = false   -- these tests build bet state directly,
core.S.prevZoomConfirm = nil     -- bypassing confirmBet()/allIn()'s own reset
setSrc("MOM_LAUNCH", -100)
setSrc("ZOOM_MODE", -100)

setSrc("MOM_LAUNCH", 100); core.wakeup()   -- press (priming)
setSrc("ZOOM_MODE", 100)                    -- latches true, same as a real press (Sticky)
setSrc("MOM_LAUNCH", -100); core.wakeup()  -- release -- starts the timer, attempt 1
check("attempt registered on release", core.S.game.bets[2].attempts == 1,
  "attempts=" .. tostring(core.S.game.bets[2].attempts))
check("not yet flight-confirmed", core.S.flightConfirmed == false)

setSrc("LANDING_MODE", 100)
pump(0.6)
check("no scoring before zoom-exit is confirmed", core.S.game.bets[2].result == "pending",
  tostring(core.S.game.bets[2].result))
setSrc("LANDING_MODE", -100); core.wakeup()

tick(2)
setSrc("ZOOM_MODE", -100); core.wakeup()   -- the real elevator-exit gesture
check("flight confirmed after zoom-exit", core.S.flightConfirmed == true)

tick(3)
setSrc("LANDING_MODE", 100)
pump(0.6)
check("scores normally once flight is confirmed", core.S.game.bets[2].result == "bust",
  tostring(core.S.game.bets[2].result))
setSrc("LANDING_MODE", -100); core.wakeup()

-- ---- Test 13: once confirmed (flying), the launch switch is locked out
-- entirely -- no reset, no attempt change -- only brakes can end it now
-- (matches: "once at #3, you can't stop the timer until brakes")

core.S.game.bets[2] = { idx = 2, target_s = 60, result = "pending", attempts = 0, scored_s = 0, allIn = false }
core.S.flightConfirmed = false
core.S.prevZoomConfirm = nil
setSrc("ZOOM_MODE", -100)
setSrc("MOM_LAUNCH", 100); core.wakeup()
setSrc("ZOOM_MODE", 100)
setSrc("MOM_LAUNCH", -100); core.wakeup()   -- release 1, attempt 1
setSrc("ZOOM_MODE", -100); core.wakeup()     -- confirms flight
check("confirmed after first release+exit", core.S.flightConfirmed == true)

local valueBeforeSpurious = core.S.timerObj:value()
setSrc("MOM_LAUNCH", 100); core.wakeup()     -- spurious/accidental press post-confirm
check("press after confirm does NOT reset the timer", core.S.timerObj:value() == valueBeforeSpurious,
  tostring(core.S.timerObj:value()))
check("press after confirm does not clear confirmation", core.S.flightConfirmed == true)
check("attempts unchanged by a post-confirm press", core.S.game.bets[2].attempts == 1,
  "attempts=" .. tostring(core.S.game.bets[2].attempts))

setSrc("MOM_LAUNCH", -100); core.wakeup()    -- spurious release too
check("release after confirm does not increment attempts either", core.S.game.bets[2].attempts == 1,
  "attempts=" .. tostring(core.S.game.bets[2].attempts))

-- ---- Test 14: liveTimerValue() -- the new public accessor screen.lua
-- needs to actually show a live countdown instead of a frozen number

check("liveTimerValue matches the real timer", core.liveTimerValue() == core.S.timerObj:value(),
  string.format("live=%s timer=%s", tostring(core.liveTimerValue()), tostring(core.S.timerObj:value())))

-- ---- Test 15: bet.result must not linger as "bust" once a retry release
-- happens -- screen.lua's live-countdown display depends on this clearing,
-- or a retry after a bust would show a stale BUST screen forever

core.S.game.idx = 1   -- currentBet() resolves via idx -- must point at the
                        -- bet actually being manipulated below, not
                        -- whatever bet earlier tests left idx pointing at
core.S.game.armed = true
core.S.game.allInPending = false
core.S.flightConfirmed = false   -- earlier tests left this true, which
core.S.prevZoomConfirm = nil     -- would otherwise block this release too
core.S.game.bets[1].result = "bust"   -- simulate a bust already recorded
setSrc("MOM_LAUNCH", 100); core.wakeup()
setSrc("ZOOM_MODE", 100)
setSrc("MOM_LAUNCH", -100); core.wakeup()   -- the retry release
check("bust label cleared by the retry release", core.S.game.bets[1].result == "pending",
  tostring(core.S.game.bets[1].result))

-- ---- Test 16: isLaunchPressed() reflects the raw switch state directly

setSrc("MOM_LAUNCH", -100)
check("isLaunchPressed false when released", core.isLaunchPressed() == false)
setSrc("MOM_LAUNCH", 100)
check("isLaunchPressed true when held", core.isLaunchPressed() == true)
setSrc("MOM_LAUNCH", -100)

-- ---- Test 17: nextBet() is a no-op for anything other than a genuine hit

core.S.game.idx = 1
core.S.game.armed = true
core.S.game.bets[1].result = "pending"
local idxBefore = core.S.game.idx
core.nextBet()
check("nextBet() does nothing when not a hit", core.S.game.idx == idxBefore)
core.S.game.bets[1].result = "bust"
core.nextBet()
check("nextBet() does nothing on a bust either", core.S.game.idx == idxBefore)

-- ---- Test 18: the flightConfirmed gate relaxes once the target is
-- actually reached -- a short flight that brakes without ever doing a
-- deliberate elevator wag should still score, once real time has passed

core.S.game.idx = 1
core.S.game.armed = true
core.S.game.allInPending = false
core.S.flightConfirmed = false
core.S.prevZoomConfirm = nil
core.S.game.bets[1] = { idx = 1, target_s = 20, result = "pending", attempts = 0, scored_s = 0, allIn = false }
setSrc("ZOOM_MODE", -100)
setSrc("MOM_LAUNCH", 100); core.wakeup()
setSrc("ZOOM_MODE", 100)
setSrc("MOM_LAUNCH", -100); core.wakeup()   -- release -- starts the 20s timer
check("not confirmed (no elevator wag simulated)", core.S.flightConfirmed == false)

tick(21)   -- let the 20s target elapse -- ZOOM_MODE never fell
setSrc("LANDING_MODE", 100)
pump(0.6)
check("scores once target is reached, even without elevator confirmation",
  core.S.game.bets[1].result == "hit", tostring(core.S.game.bets[1].result))
setSrc("LANDING_MODE", -100); core.wakeup()

-- Confirm the EARLY-flight protection is unchanged -- a landing signal
-- while the timer still has time left, and unconfirmed, still must not
-- score anything at all.
core.S.game.idx = 1
core.S.game.armed = true
core.S.flightConfirmed = false
core.S.prevZoomConfirm = nil
core.S.game.bets[1] = { idx = 1, target_s = 60, result = "pending", attempts = 0, scored_s = 0, allIn = false }
setSrc("ZOOM_MODE", -100)
setSrc("MOM_LAUNCH", 100); core.wakeup()
setSrc("ZOOM_MODE", 100)
setSrc("MOM_LAUNCH", -100); core.wakeup()
tick(5)   -- well short of the 60s target
setSrc("LANDING_MODE", 100)
pump(0.6)
check("early-flight protection unchanged (still positive, unconfirmed)",
  core.S.game.bets[1].result == "pending", tostring(core.S.game.bets[1].result))
setSrc("LANDING_MODE", -100); core.wakeup()

-- ---- Test 19: FS1/FS4 on SUMMARY and LOG do the CORRECT thing for
-- THOSE screens (view log / new game / back), and specifically do NOT
-- fall through to the SETUP/LIVE-specific roles (confirmBet/allIn/bumpMin)
-- that caused the original bug (a stray CONFIRM press on SUMMARY
-- overwriting an already-resolved bet's target with stale edit values)

core.S.screen = core.SCREEN.SUMMARY
core.S.game.armed = false
local staleTarget = core.S.game.bets[1].target_s

setSrc("FS1", 100); core.wakeup(); tick(0.05); setSrc("FS1", -100); core.wakeup()
check("FS1 on SUMMARY goes to the log screen", core.S.screen == core.SCREEN.LOG,
  tostring(core.S.screen))
check("FS1 on SUMMARY did not touch bet data", core.S.game.bets[1].target_s == staleTarget)

core.S.screen = core.SCREEN.SUMMARY   -- back, to test FS4 independently
setSrc("FS4", 100); core.wakeup(); tick(0.05); setSrc("FS4", -100); core.wakeup()
check("FS4 on SUMMARY starts a new game", core.S.game == nil)
check("screen moved to SETUP", core.S.screen == core.SCREEN.SETUP)

-- Re-create a game for the rest of the suite, and confirm LOG's FS1/FS4
core.S.game = { bets = {
                  { idx=1, target_s=staleTarget, result="pending", attempts=0, scored_s=0, allIn=false },
                  { idx=2, target_s=nil, result="pending", attempts=0, scored_s=0, allIn=false },
                  { idx=3, target_s=nil, result="pending", attempts=0, scored_s=0, allIn=false },
                },
                idx = 1, betCount = 3, score = 0, armed = false,
                editMin = 0, editSec = 30, deadline = os.time() + 600, allInPending = false }

core.S.screen = core.SCREEN.LOG
core.S.game.editMin = 7   -- sentinel -- if this changed, FS1 wrongly fell
core.S.game.editSec = 7   -- through to bumpMin's SETUP-only path
setSrc("FS1", 100); core.wakeup(); tick(0.05); setSrc("FS1", -100); core.wakeup()
check("FS1 on LOG (OPEN, unimplemented) touches nothing", core.S.game.editMin == 7,
  tostring(core.S.game.editMin))

setSrc("FS4", 100); core.wakeup(); tick(0.05); setSrc("FS4", -100); core.wakeup()
check("FS4 on LOG (BACK) returns to SUMMARY", core.S.screen == core.SCREEN.SUMMARY,
  tostring(core.S.screen))

-- ---- Test 20: ALL IN recomputes on EVERY release, not just the first --
-- a bust-retry must not keep the stale target from a failed attempt while
-- the game clock keeps running underneath it

core.S.game.idx = 1
core.S.screen = core.SCREEN.LIVE   -- Test 19 left this on LOG, where the
                                     -- new screen-guard correctly blocks
                                     -- all FS actions, including FS3
core.S.game.armed = false
core.S.game.allInPending = false
core.S.flightConfirmed = false
core.S.prevZoomConfirm = nil
core.S.game.bets[1] = { idx = 1, target_s = nil, result = "pending", attempts = 0, scored_s = 0, allIn = false }
core.S.game.deadline = os.time() + 97

setSrc("FS3", 100); core.wakeup(); tick(0.05); setSrc("FS3", -100); core.wakeup()
check("all-in arms without a fixed target yet", core.S.game.allInPending == true)

setSrc("ZOOM_MODE", -100)
setSrc("MOM_LAUNCH", 100); core.wakeup()
setSrc("ZOOM_MODE", 100)
setSrc("MOM_LAUNCH", -100); core.wakeup()   -- first release
check("first release computes a target close to the 97s window",
  core.S.game.bets[1].target_s ~= nil and core.S.game.bets[1].target_s >= 80 and core.S.game.bets[1].target_s <= 90,
  "target_s=" .. tostring(core.S.game.bets[1].target_s))

tick(2)
setSrc("ZOOM_MODE", -100); core.wakeup()   -- confirm flight
tick(3)
setSrc("LANDING_MODE", 100)
pump(0.6)
check("first attempt busts", core.S.game.bets[1].result == "bust",
  tostring(core.S.game.bets[1].result))
setSrc("LANDING_MODE", -100); core.wakeup()

tick(20)   -- real time burned during the failed attempt
setSrc("ZOOM_MODE", -100)
setSrc("MOM_LAUNCH", 100); core.wakeup()
setSrc("ZOOM_MODE", 100)
setSrc("MOM_LAUNCH", -100); core.wakeup()   -- retry release
check("retry recomputes against current remaining time, not the stale 90s",
  core.S.game.bets[1].target_s ~= nil and core.S.game.bets[1].target_s < 90,
  "target_s=" .. tostring(core.S.game.bets[1].target_s))

-- ---- Test 21: a scoring error must not permanently latch landingActive
-- -- confirmed a real gap: an unhandled error inside the debounced
-- scoring block (whatever the root cause) would leave S.landingActive
-- stuck true forever, since nothing else clears it, blocking pollLanding()
-- from ever trying again until brakes are released and re-engaged

core.S.game.idx = 1
core.S.screen = core.SCREEN.LIVE
core.S.game.armed = true
core.S.game.allInPending = false
core.S.flightConfirmed = false
core.S.prevZoomConfirm = nil
core.S.game.bets[1] = { idx = 1, target_s = 15, result = "pending", attempts = 0, scored_s = 0, allIn = false }
setSrc("ZOOM_MODE", -100)
setSrc("MOM_LAUNCH", 100); core.wakeup()
setSrc("ZOOM_MODE", 100)
setSrc("MOM_LAUNCH", -100); core.wakeup()
tick(2)
setSrc("ZOOM_MODE", -100); core.wakeup()

-- Simulate the exact failure mode: corrupt g.score so the scoring
-- arithmetic throws, matching what an unexpected nil there would do.
core.S.game.score = {}   -- deliberately not a number
tick(16)
setSrc("LANDING_MODE", 100)
pump(0.6)   -- the debounced block throws here
check("landingActive did not latch stuck after the error",
  core.S.landingActive == false, tostring(core.S.landingActive))
setSrc("LANDING_MODE", -100); core.wakeup()

-- Repair state and confirm a fresh attempt scores normally afterward --
-- proving recovery is real, not just "didn't crash the test file"
core.S.game.score = 0
core.S.game.bets[1].result = "pending"
setSrc("ZOOM_MODE", 100)
setSrc("MOM_LAUNCH", 100); core.wakeup()
setSrc("MOM_LAUNCH", -100); core.wakeup()
tick(2)
setSrc("ZOOM_MODE", -100); core.wakeup()
tick(16)
setSrc("LANDING_MODE", 100)
pump(0.6)
check("scores normally again after recovery", core.S.game.bets[1].result == "hit",
  tostring(core.S.game.bets[1].result))
setSrc("LANDING_MODE", -100); core.wakeup()

-- ---- Test 22: bust immediately silences the timer rather than leaving
-- it running/alerting on a failed attempt

core.S.game.idx = 1
core.S.screen = core.SCREEN.LIVE
core.S.game.armed = true
core.S.game.allInPending = false
core.S.flightConfirmed = false
core.S.prevZoomConfirm = nil
core.S.game.bets[1] = { idx = 1, target_s = 60, result = "pending", attempts = 0, scored_s = 0, allIn = false }
setSrc("ZOOM_MODE", -100)
setSrc("MOM_LAUNCH", 100); core.wakeup()
setSrc("ZOOM_MODE", 100)
setSrc("MOM_LAUNCH", -100); core.wakeup()
tick(2)
setSrc("ZOOM_MODE", -100); core.wakeup()
tick(5)   -- well short of the 60s target -- a genuine bust
setSrc("LANDING_MODE", 100)
pump(0.6)
check("bust recorded", core.S.game.bets[1].result == "bust")
-- Tolerance, not exact-zero: the mock timer's own "always counting"
-- simulation ticks fractionally between the reset and this check, same
-- as the real Timer3 would between reset() and the next value() read.
local bustVal = core.S.timerObj:value()
check("timer silenced immediately on bust", bustVal ~= nil and math.abs(bustVal) < 1,
  tostring(bustVal))
setSrc("LANDING_MODE", -100); core.wakeup()

-- ---- Test 23: finalizeGame() silences the timer so it doesn't keep
-- counting/alerting in the background after the pilot leaves the game

core.S.game.armed = true
core.S.game.idx = core.S.game.betCount
core.S.game.bets[core.S.game.idx].result = "hit"
core.nextBet()   -- last bet, hit -> advanceBet() -> finalizeGame()
check("game finalized to SUMMARY", core.S.screen == core.SCREEN.SUMMARY)
local endVal = core.S.timerObj:value()
check("timer silenced at game end", endVal ~= nil and math.abs(endVal) < 1,
  tostring(endVal))

print("")
if failures == 0 then print("ALL TESTS PASSED")
else print(failures .. " TEST(S) FAILED") os.exit(1) end

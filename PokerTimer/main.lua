-- DLG Poker -- DLG launch-height poker practice timer for FrSky Ethos.
--
-- Full-screen system tool ONLY -- deliberately no widget. A widget's
-- wakeup() runs continuously in the background regardless of which screen
-- is showing (confirmed via the Ethos community: "all Lua widgets are
-- always started immediately when the transmitter is switched on...
-- since Lua is then running in the background"), which is exactly what
-- Throw Trainer needs -- it logs launches quietly through a whole flying
-- session while the pilot does other things. DLG Poker's use pattern is
-- different: a game is one continuous stretch of active engagement --
-- bet, launch, wait for the outcome, bet again -- with no realistic
-- moment where the pilot steps away mid-game and expects launch detection
-- to keep working unattended. So the System Tool's own lifecycle (its
-- wakeup() stops when the pilot navigates away, confirmed by the same
-- research: System Tools don't share a widget's background-execution
-- property) is an accepted tradeoff here, not an oversight -- the cost is
-- real (stepping away mid-game does pause detection until you return) but
-- matches how this tool actually gets used.
--
-- Own script (spec S13), not part of Throw Trainer -- separate folder,
-- separate registration, separate log files, no shared code.

local core   = assert(loadfile("core.lua"))()
local draw   = assert(loadfile("draw.lua"))(core)
local config = assert(loadfile("config.lua"))(core)
local screen = assert(loadfile("screen.lua"))(core, draw, config)

local function create()
  core.init()
  return {}
end

local function paint(widget)
  local w, h = lcd.getWindowSize()
  screen.paint(w, h)
end

local function wakeup(widget)
  -- Wrapped defensively -- confirmed a real gap: screen.paint() already
  -- had this protection (added after an earlier crash report), but
  -- core.wakeup() -- where the actual scoring logic runs -- had none at
  -- all. An error here previously propagated straight to Ethos's own
  -- error indicator, and critically could leave S.landingActive latched
  -- true without ever completing a hit/bust, permanently blocking further
  -- attempts until brakes were released and re-engaged. Surfaced via
  -- core.setStatus() rather than swallowed silently, so a real recurring
  -- error is still visible and reportable, not just quietly contained.
  local ok, err = pcall(core.wakeup)
  if not ok then
    core.recoverFromWakeupError()
    core.setStatus("internal error - see log: " .. tostring(err))
  end
  lcd.invalidate()
end

local function event(widget, category, value, x, y)
  -- Wrapped for the same reason wakeup() and paint() already are -- this
  -- is the one callback that still had no protection, and it's also
  -- where the newest, least-verified code lives (touch hit-testing).
  local ok, result = pcall(screen.event, value, x, y)
  if not ok then
    core.setStatus("event error - see log: " .. tostring(result))
    return true   -- swallow the event rather than letting it propagate
                   -- further after something inside already failed
  end
  return result
end

local function close(widget)
  return true
end

local function init()
  -- Icon mandatory -- confirmed in this project's own build log (Throw
  -- Trainer S18, Poker Probe) that a registerSystemTool call with no icon
  -- silently never appears in the System menu, with no error anywhere.
  local iconOk, icon = pcall(lcd.loadMask, "pokertimer.png")
  if not iconOk then icon = nil end

  system.registerSystemTool({
    name   = "DLG Poker",
    icon   = icon,
    create = create,
    paint  = paint,
    wakeup = wakeup,
    event  = event,
    close  = close,
    title  = true,
  })
end

return { init = init }

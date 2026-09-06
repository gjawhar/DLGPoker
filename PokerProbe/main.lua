-- Poker Probe -- diagnostic-only script for the Poker Timer project.
--
-- Purpose: answer the open questions in the Poker Timer Requirements Spec
-- (S6/S6.4) on real hardware before the real tool is built around them --
-- specifically whether Timer3 can be read/written/reset from Lua, and
-- whether a flight mode's active state and dwell time can be read reliably.
--
-- Full-screen system tool ONLY. No widget is registered, because the real
-- Poker Timer tool is full-screen-only by design (see spec S5/S12), so this
-- probe deliberately tests the same surface, not a paradigm the real tool
-- will never use.
--
-- Icon is mandatory: per the Throw Trainer project's own finding, a
-- registerSystemTool call with no icon silently never appears in the
-- System menu, with no error anywhere.

local probe = assert(loadfile("probe.lua"))()

local function create()
  return probe.create()
end

local function paint(widget)
  local w, h = lcd.getWindowSize()
  probe.paint(widget, w, h)
end

local function wakeup(widget)
  probe.wakeup(widget)
end

local function event(widget, category, value, x, y)
  return probe.event(widget, value, x, y)
end

local function close(widget)
  probe.close(widget)
  return true
end

local function init()
  -- Icon loading is wrapped: a malformed or wrongly-sized mask file should
  -- not be able to take the whole script down. Per the DLG Poker Timer
  -- spec's own findings (citing the Throw Trainer project), a MISSING icon
  -- only causes the tool's tile to never appear -- but that assumes
  -- lcd.loadMask() merely returns something falsy for a bad file rather
  -- than throwing. This wrapper covers the case where it actually throws,
  -- which would otherwise abort registerSystemTool() and the entire
  -- script's init() along with it -- the difference between "no tile" and
  -- "won't load at all."
  local iconOk, icon = pcall(lcd.loadMask, "pokerprobe.png")
  if not iconOk then icon = nil end

  system.registerSystemTool({
    name   = "Poker Probe",
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

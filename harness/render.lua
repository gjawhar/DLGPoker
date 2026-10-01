-- Renders DLG Poker's REAL paint output to SVG: an lcd mock records every
-- primitive the app draws, a scripted game is played through core.lua's
-- real logic (throws, landings, busts, hits), and each scene is written
-- to out_<name>.svg. render.py turns those into the README's PNGs.
--
-- What this is and isn't: layout, colours, text and state are exactly
-- what the radio draws; glyph shapes are the host's sans-serif, not the
-- Ethos font, with text widths taken from a Helvetica-style width table
-- and pinned via textLength so every measured layout decision holds.

local W, H = 640, 316          -- X14 tool window (640 wide), title bar excluded
local RATE = 40

local fakeClock = 1789000000
os.time = function() return math.floor(fakeClock) end
local function tick(s) fakeClock = fakeClock + s end
-- Ethos's restricted io: global io.read(handle, n). Standard Lua's
-- io.read reads stdin, so shim it or the LOG screen has no rows.
local realRead = io.read
io.read = function(f, n) if type(f) == "userdata" then return f:read(n) end return realRead(f, n) end

CATEGORY_LOGIC_SWITCH = "logic"
CATEGORY_ALWAYS_ON, CATEGORY_TIMER, CATEGORY_NONE = 1, 21, 0
COUNTDOWN_VALUE, COUNTDOWN_BEEP, PLAY_FILE, PLAY_VALUE = 0, 1, 2, 3
FONT_S, FONT_M, FONT_L, FONT_XL = 1, 2, 3, 4
DOTTED, SOLID = 1, 0
KEY_ROTARY_LEFT, KEY_ROTARY_RIGHT = 4099, 4100
KEY_ENTER_BREAK, KEY_RTN_FIRST, KEY_EXIT_FIRST = 33, 99, 98

local sourceValues = {}
local function setSrc(name, v) sourceValues[name] = v end
local function makeSource(name)
  return { value = function() return sourceValues[name] or -100 end, name = function() return name end }
end
local function src(name, cat, mem)
  return { name = function() return name end, category = function() return cat end,
           member = function() return mem end, options = function() return 0 end }
end
local alwaysOn, none = src("Always on", 1, 0), src("---", 0, 0)
local fakeTimers = {}
system = {
  getSource = function(spec)
    if type(spec) ~= "table" then return nil end
    if spec.category == CATEGORY_ALWAYS_ON then return alwaysOn end
    if spec.category == CATEGORY_NONE then return none end
    if spec.category == CATEGORY_TIMER then
      local t = fakeTimers[(spec.member or 0) + 1]
      return src(t and t:name() or "---", CATEGORY_TIMER, spec.member or 0)
    end
    if spec.name then return makeSource(spec.name) end
    return nil
  end,
  playTone = function() end, playHaptic = function() end,
  getVersion = function() return { board = "X14" } end,
}
local function makeTimer(name)
  local t = { _start = 0, _value = 0, _dir = 1, _last = fakeClock, _name = name, _sc = none }
  return {
    start = function(self, ...) if select("#", ...) == 0 then return t._start else t._start = ... end end,
    value = function(self, ...)
      if t._dir == -1 and t._sc == alwaysOn then t._value = t._value - (fakeClock - t._last) end
      t._last = fakeClock
      if select("#", ...) == 0 then return t._value else t._value = ... end
    end,
    reset = function(self) t._value = t._start t._last = fakeClock end,
    direction = function(self, ...) if select("#", ...) == 0 then return t._dir else t._dir = ... end end,
    countingSource = function(self, ...) if select("#", ...) == 0 then return nil end end,
    startCondition = function(self, ...)
      if select("#", ...) == 0 then return t._sc end
      self:value()              -- settle the count before the condition changes
      t._sc = ...
    end,
    name = function(self, ...) if select("#", ...) == 0 then return t._name else t._name = ... end end,
    audioActions = function(self, ...) if select("#", ...) == 0 then return t._aa or {} else t._aa = ... end end,
  }
end
fakeTimers[1], fakeTimers[2], fakeTimers[3] = makeTimer("FlightTime"), makeTimer("Timer2"), makeTimer("Timer3")
model = {
  getTimer = function(name)
    for _, t in ipairs(fakeTimers) do if t:name() == name then return t end end
    return nil
  end,
  createTimer = function() local t = makeTimer("---") fakeTimers[#fakeTimers + 1] = t return t end,
}

-- ---- lcd -> SVG
local FONT_H  = { [1] = 20, [2] = 25, [3] = 28, [4] = 37 }   -- measured on the X14, Ethos 26.1.2
local FONT_PX = { [1] = 14, [2] = 18, [3] = 21, [4] = 29 }   -- Ethos glyphs sit small in their line box
-- Helvetica-Bold-ish advance widths, in 1/1000 em
local function adv(ch)
  if ch:match("%d") then return 556 end
  if ch == " " then return 278 end
  if ch:match("[ilIjt.,:;'|!/]") then return 300 end
  if ch:match("[frJ%-%(%)]") then return 360 end
  if ch:match("[mwMW]") then return 880 end
  if ch:match("[A-Z]") then return 690 end
  if ch:match("[+=<>#]") then return 584 end
  return 580
end
local function textW(s, font)
  local n = 0
  s = tostring(s)
  for _, cp in utf8.codes(s) do
    local ch = utf8.char(cp)
    n = n + (cp > 127 and 760 or adv(ch))
  end
  return math.floor(n * FONT_PX[font] / 1000 + 0.5)
end
local curFont, curCol, dotted, ops = 1, "#000", false, {}
local function hexc(c) return string.format("#%02x%02x%02x", c[1], c[2], c[3]) end
lcd = {
  RGB = function(r, g, b) return { r, g, b } end,
  color = function(c) curCol = hexc(c) end,
  font = function(f) curFont = FONT_H[f] and f or 1 end,
  pen = function(p) dotted = (p == DOTTED) end,
  getWindowSize = function() return W, H end,
  getTextSize = function(s) return textW(s, curFont), FONT_H[curFont] end,
  loadMask = function() return nil end,
  invalidate = function() end,
  drawText = function(x, y, s)
    s = tostring(s)
    if s == "" then return end
    x, y = math.floor(x + 0.5), math.floor(y + 0.5)
    local w = textW(s, curFont)
    local esc = s:gsub("&", "&amp;"):gsub("<", "&lt;")
    ops[#ops + 1] = string.format('<text xml:space="preserve" x="%d" y="%d" font-size="%d" fill="%s" textLength="%d" lengthAdjust="spacingAndGlyphs">%s</text>',
      x, y + math.floor(FONT_H[curFont] * 0.78), FONT_PX[curFont], curCol, w, esc)
  end,
  drawFilledRectangle = function(x, y, w, h)
    x, y, w, h = math.floor(x + 0.5), math.floor(y + 0.5), math.floor(w + 0.5), math.floor(h + 0.5)
    ops[#ops + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>', x, y, w, h, curCol)
  end,
  drawRectangle = function(x, y, w, h, t)
    t = t or 1
    x, y, w, h = math.floor(x + 0.5), math.floor(y + 0.5), math.floor(w + 0.5), math.floor(h + 0.5)
    ops[#ops + 1] = string.format('<rect x="%.1f" y="%.1f" width="%d" height="%d" fill="none" stroke="%s" stroke-width="%d"/>',
      x + t / 2, y + t / 2, w - t, h - t, curCol, t)
  end,
  drawLine = function(a, b, c, d)
    a, b, c, d = math.floor(a + 0.5), math.floor(b + 0.5), math.floor(c + 0.5), math.floor(d + 0.5)
    ops[#ops + 1] = string.format('<line x1="%d" y1="%.1f" x2="%d" y2="%.1f" stroke="%s"%s/>',
      a, b + 0.5, c, d + 0.5, curCol, dotted and ' stroke-dasharray="2,3"' or "")
  end,
}
form = { clear = function() end }

-- A little history so the LOG screen has something to show.
local function seed(name, rows)
  local f = assert(io.open("Files/" .. name .. ".csv", "w"))
  for _, r in ipairs(rows) do f:write(r .. "\n") end
  f:close()
end
local day = 86400
seed("games", {
  (fakeClock - 6 * day) .. ",600,3,210,1,2",
  (fakeClock - 6 * day + 900) .. ",600,3,390,1,3",
  (fakeClock - 2 * day) .. ",600,3,150,1,1",
  (fakeClock - 2 * day + 1100) .. ",600,5,430,1,4",
  (fakeClock - 1 * day) .. ",600,3,300,1,2",
})
seed("bets", {})

local core   = assert(loadfile("core.lua"))()
local draw   = assert(loadfile("draw.lua"))(core)
local config = assert(loadfile("config.lua"))(core)
local screen = assert(loadfile("screen.lua"))(core, draw, config)

local function pump(seconds)
  for _ = 1, math.floor(seconds * RATE + 0.5) do tick(1 / RATE) core.wakeup() end
end
local function shot(name)
  ops = {}
  local bg = draw.theme().bg
  ops[1] = string.format('<rect x="0" y="0" width="%d" height="%d" fill="#%06x"/>', W, H, bg)
  screen.paint(W, H)
  local f = assert(io.open("out_" .. name .. ".svg", "w"))
  f:write(string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" font-family="Helvetica Neue,Helvetica,Arial,sans-serif" font-weight="600">\n', W, H, W, H))
  f:write(table.concat(ops, "\n")) f:write("\n</svg>\n") f:close()
  print("shot " .. name)
end
local function throw()
  setSrc("ZOOM_MODE", -100)
  setSrc("MOM_LAUNCH", 100) core.wakeup()
  setSrc("ZOOM_MODE", 100)
  setSrc("MOM_LAUNCH", -100) core.wakeup()
  setSrc("ZOOM_MODE", -100) core.wakeup()
end
local function land()
  setSrc("LANDING_MODE", 100) pump(1.2)
  setSrc("LANDING_MODE", -100) core.wakeup()
end
local function setBet(min, sec)
  for _ = 1, min do core.bumpMin() end
  for _ = 1, math.floor(sec / 10) do core.bumpSec() end
end

core.init()
pump(2)                                  -- calibrate the wakeup rate
shot("1_first_run")                      -- one-time "PokerTimer created" screen
core.dismissTimerNotice()
shot("2_setup")

core.startGame()
core.resetMin() core.resetSec()
setBet(1, 30)
pump(4)                                  -- let any status line expire
shot("3_place_bet")

throw()
pump(38)
shot("4_in_flight")

-- RTN mid-flight asks before leaving (pilot request, 2026-09-30). Driven
-- through the real screen.event() path, and checked, so this render
-- doubles as the execution test for it.
local function rtn() return screen.event(KEY_RTN_FIRST) end
local before = { idx = core.S.game.idx, score = core.S.game.score }
assert(rtn() == true and core.S.exitConfirm, "RTN mid-game must open the question and be swallowed")
shot("10_exit_confirm")
screen.event(KEY_ROTARY_RIGHT, 1)        -- wheel: RETURN TO GAME -> EXIT
screen.event(KEY_ROTARY_RIGHT, 1)        -- and back
screen.event(KEY_ENTER_BREAK)            -- ENTER on RETURN TO GAME (the default)
assert(not core.S.exitConfirm and core.S.game and core.S.game.idx == before.idx and core.S.game.armed,
  "RETURN TO GAME must leave the game exactly as it was")
assert(rtn() == true and core.S.exitConfirm, "RTN opens it again")
assert(rtn() == true and not core.S.exitConfirm and core.S.game, "RTN on the question returns to the game")

land()                                   -- landed at ~0:50 left: bust
pump(0.5)
shot("5_bust")

throw()                                  -- retry, same 1:30 target
pump(95)
land()                                   -- past the target: hit, on to bet 2
pump(4)                                  -- status line expires; the HIT banner stays
shot("6_hit_next_bet")

core.resetMin() core.resetSec()
setBet(2, 0)
throw() pump(124) land()                 -- bet 2: hit
pump(0.5)
core.resetMin() core.resetSec()
setBet(3, 0)
throw() pump(60) land()                  -- bet 3: bust...
for _ = 1, 600 do                        -- ...and the window runs out
  if core.S.screen == core.SCREEN.SUMMARY then break end
  pump(1)
end
assert(core.S.screen == core.SCREEN.SUMMARY, "game never reached the summary")
shot("7_summary")

core.S.screen = core.SCREEN.LOG
shot("8_log")

-- EXIT through the real path: RTN, wheel to EXIT, ENTER
core.S.screen = core.SCREEN.SUMMARY      -- (back from the LOG shot)
assert(screen.event(KEY_RTN_FIRST) == false, "RTN on the summary leaves the tool, no question")
core.onClose() screen.reset()
core.startGame()
throw() pump(3)
assert(screen.event(KEY_RTN_FIRST) == true and core.S.exitConfirm)
screen.event(KEY_ROTARY_LEFT, 1)         -- wheel: -> EXIT
screen.event(KEY_ENTER_BREAK)
assert(core.S.game == nil and core.S.screen == core.SCREEN.SETUP, "EXIT ends the game")
assert(core.takeExitRequest() == true, "EXIT asks main.lua to close the tool")
screen.reset()
assert(screen.event(KEY_RTN_FIRST) == false, "RTN on SETUP leaves the tool, no question")

-- night mode, mid-flight
core.onClose()
screen.reset()
core.S.cfg.display = "night"
core.startGame()
core.resetMin() core.resetSec()
setBet(2, 0)
throw()
pump(47)
shot("9_in_flight_night")
core.S.cfg.display = nil
print("rendered")

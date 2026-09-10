-- DLG Poker rendering. Day mode is the default (spec S5.3) -- light
-- background, high-contrast semantic colours, for sunlight legibility at
-- the flying field. Night mode (the dark palette used elsewhere in this
-- ecosystem's tools) is available as a display setting. Colour values are
-- the only thing that changes between the two; layout and type scale stay
-- identical, matching the approved mockups exactly (poker_timer_screens_v5).
--
-- Palette + badge component redesign (pilot request, 2026-09: "the look
-- and feel of ThrowTrainer"). Every value below (both themes) is copied
-- verbatim from ThrowTrainer/draw.lua's own lightPalette()/darkPalette(),
-- not re-invented here -- DLG Poker's night theme was already close to
-- it by coincidence; day was the one that actually diverged (flat,
-- saturated colours vs. ThrowTrainer's softer, muted set). The *Bg
-- variants are new -- DLG Poker had no tinted-background concept before
-- this -- and exist specifically to back draw.badge() below.

local core = ...
local draw = {}

local THEMES = {
  day = {
    bg = 0xF6F6F8, alt = 0xF2F2F2, txt = 0x141416, dim2 = 0x5A5A5A, dim = 0x6E6E74,
    border = 0xC3C3C8, accent = 0x1469BE, accentBg = 0xE5EEF8,
    good = 0x238C4B, goodBg = 0xD7F0DE, bad = 0xBE372D, badBg = 0xFADEDA,
    amber = 0xC3870F, marker = 0xC35F19, dimBg = 0xDEDEE2,
    cardRed = 0xC81E2E, cardBlack = 0x141414,
  },
  night = {
    bg = 0x0E0E10, alt = 0x1A1A1A, txt = 0xEBEBEB, dim2 = 0x999999, dim = 0x8C8C8C,
    border = 0x5A5A5A, accent = 0x50AAF0, accentBg = 0x1E2C3D,
    good = 0x5AC878, goodBg = 0x142E1E, bad = 0xDC5A46, badBg = 0x321816,
    amber = 0xF0BE3C, marker = 0xE68228, dimBg = 0x2A2A2A,
    cardRed = 0xFF5468, cardBlack = 0xEAEAEA,
  },
}

local function hex(rgb)
  local r = math.floor(rgb / 0x10000) % 0x100
  local g = math.floor(rgb / 0x100) % 0x100
  local b = rgb % 0x100
  return lcd.RGB(r, g, b)
end

function draw.theme()
  local mode = (core.S.cfg.display == "night") and "night" or "day"
  return THEMES[mode]
end

function draw.color(rgbInt) lcd.color(hex(rgbInt)) end

-- ---------------------------------------------------------------- text helpers

-- Ethos clips overflowing text with no wrap and no ellipsis (confirmed in
-- the Throw Trainer project) -- measure before drawing anything that might
-- not fit.
function draw.fitText(text, maxW)
  local tw = lcd.getTextSize(text)
  if tw <= maxW then return text end
  for i = #text - 1, 1, -1 do
    local cut = string.sub(text, 1, i)
    if lcd.getTextSize(cut) <= maxW then return cut end
  end
  return ""
end

function draw.text(x, y, s, maxW, flags)
  if maxW then s = draw.fitText(s, maxW) end
  lcd.drawText(x, y, s, flags)
end

function draw.mmss(seconds)
  if not seconds then return "--:--" end
  if seconds < 0 then seconds = 0 end
  local m = math.floor(seconds / 60)
  local s = math.floor(seconds) % 60
  return string.format("%d:%02d", m, s)
end

function draw.signed(seconds)
  local n = math.floor(seconds + 0.5)
  local sign = (n >= 0) and "+" or "-"
  return sign .. tostring(math.abs(n)) .. "s"
end

-- ---------------------------------------------------------------- badge

-- A small filled-and-bordered pill: tinted background + coloured 1px
-- border + text. Ported from ThrowTrainer/draw.lua's own draw.badge()
-- (pilot request, 2026-09) -- flat corners rather than rounded, same
-- reasoning as there: no rounded-rect primitive to lean on, and a sharp-
-- cornered tinted rectangle reads the same way at this size. Assumes
-- FONT_S is already set (matches every call site -- the caller has
-- usually just set it for a label anyway, so this doesn't force a
-- redundant lcd.font() call for callers that already have the right one).
-- Returns the drawn width/height so a caller can right-align or centre a
-- badge before drawing it.
function draw.badge(x, y, text, color, bg, maxW)
  local tw = lcd.getTextSize(text)
  if maxW and tw > maxW - 10 then
    text = draw.fitText(text, maxW - 10)
    tw = lcd.getTextSize(text)
  end
  local _, th = lcd.getTextSize("0")
  th = (th and th > 0) and th or 14
  local bw, bh = tw + 10, th + 6
  draw.color(bg)
  lcd.drawFilledRectangle(x, y, bw, bh)
  draw.color(color)
  lcd.drawRectangle(x, y, bw, bh, 1)
  draw.text(x + 5, y + 3, text, tw + 2)
  return bw, bh
end

-- Same measurement math as draw.badge() without drawing anything -- lets
-- a caller right-align a badge (e.g. against the screen edge) before it
-- knows the final x, without drawing off-canvas just to measure first.
function draw.badgeSize(text, maxW)
  local tw = lcd.getTextSize(text)
  if maxW and tw > maxW - 10 then
    tw = lcd.getTextSize(draw.fitText(text, maxW - 10))
  end
  local _, th = lcd.getTextSize("0")
  th = (th and th > 0) and th or 14
  return tw + 10, th + 6
end

-- ---------------------------------------------------------------- divider

-- Thin dotted rule (pilot request, 2026-09) -- the same DOTTED-pen
-- boundary-mark treatment ThrowTrainer's draw.strip() uses for chart
-- section breaks, reused here as a general section divider. DOTTED
-- itself is the one already hardware-confirmed there ("no DASHED
-- constant has been confirmed on this target") -- same Ethos Lua pen
-- API, same radio family, not re-verified separately for this project.
function draw.dottedLine(x, y, w, color)
  draw.color(color)
  lcd.pen(DOTTED)
  lcd.drawLine(x, y, x + w, y)
  lcd.pen(SOLID)
end

-- ---------------------------------------------------------------- chrome

-- Title bar shared by every screen -- title left, ETHOS wordmark centre,
-- icons right, matching the approved mockups and the real radio's own
-- chrome (Poker Probe screenshots).
function draw.chrome(w, title)
  local t = draw.theme()
  draw.color(t.bg)
  lcd.drawFilledRectangle(0, 0, w, 26)
  draw.color(t.border)
  lcd.drawLine(0, 26, w, 26)

  lcd.font(FONT_S)
  draw.color(t.txt)
  draw.text(6, 5, title, w * 0.4)

  draw.color(t.dim)
  local word = "ETHOS"
  local tw = lcd.getTextSize(word)
  draw.text(math.floor((w - tw) / 2), 5, word)
end

return draw

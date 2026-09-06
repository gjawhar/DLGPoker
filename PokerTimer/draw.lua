-- DLG Poker rendering. Day mode is the default (spec S5.3) -- light
-- background, high-contrast semantic colours, for sunlight legibility at
-- the flying field. Night mode (the dark palette used elsewhere in this
-- ecosystem's tools) is available as a display setting. Colour values are
-- the only thing that changes between the two; layout and type scale stay
-- identical, matching the approved mockups exactly (poker_timer_screens_v5).

local core = ...
local draw = {}

local THEMES = {
  day = {
    bg = 0xFFFFFF, alt = 0xF2F2F2, txt = 0x141414, dim2 = 0x5A5A5A, dim = 0x9A9A9A,
    border = 0xDCDCDC, accent = 0x0B63C9, good = 0x1E8E3E, bad = 0xC5221F,
    amber = 0xA35C00, cardRed = 0xC81E2E, cardBlack = 0x141414,
  },
  night = {
    bg = 0x0C0C0D, alt = 0x1A1A1A, txt = 0xE8E8E8, dim2 = 0x999999, dim = 0x6B6B6B,
    border = 0x2A2A2A, accent = 0x4AA8F0, good = 0x5FC27D, bad = 0xE2534A,
    amber = 0xE8A93A, cardRed = 0xFF5468, cardBlack = 0xEAEAEA,
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

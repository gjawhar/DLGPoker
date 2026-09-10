-- DLG Poker screens. Full-screen tool only (spec S5.4) -- no widget, no
-- tier system. Physical Function Switches (FS1/FS2/FS3/FS4) drive the game
-- independently via core.wakeup()'s own polling, regardless of what's on
-- screen; the rotary + encoder path implemented here is the no-touch
-- fallback for the X14 and a bench-testing convenience, covering the same
-- four actions per screen.

local core, draw, config = ...
local screen = {}

local SCREEN = core.SCREEN
local inForm = false

-- Touch double-fire workaround: a single tap on a touch-capable radio
-- delivers TWO event() calls (press, then release) with no reliable
-- value/category signal telling them apart -- confirmed on the X20RS
-- simulator in this project's sibling ThrowTrainer widget, where an
-- unpaired hit-test toggled a key on and immediately back off from one
-- tap. Fix: treat the first touch call on a key as the action and
-- unconditionally swallow the very next touch call, regardless of where
-- it lands or what state the first call changed. See the swallow check
-- at the very top of screen.event() below for why it must run before
-- the inForm gate specifically.
local touchConsuming = false

-- Touch support (X20RS and other touch-capable radios): tap the on-screen
-- keys directly instead of routing through the rotary + FS switches. Same
-- heuristic already confirmed working in this project's own Poker Probe --
-- system.getVersion().board, excluding "X14" specifically, since there is
-- no confirmed "has touchscreen" field to check directly. Computed once,
-- not every frame -- the board is not going to change mid-session.
local touchCapable = nil
local function isTouchCapable()
  if touchCapable ~= nil then return touchCapable end
  local ok, v = pcall(system.getVersion)
  local board = (ok and v and v.board) or ""
  touchCapable = not string.find(tostring(board), "X14")
  return touchCapable
end

-- Hit-test rectangles for the current screen's keys, rebuilt every paint
-- by paintKeys()/paintConfigButton() -- keyed by the SAME index activate()
-- already uses for rotary+enter, so a tap and a rotary-select land on
-- exactly the same action.
local keyRects = {}

-- Hit-test rectangles for on-screen stepper buttons (MIN-/MIN+/SEC-/SEC+,
-- SETUP and LIVE) -- separate from keyRects because these sit in the
-- content area, not the footer row, and each one calls a bump function
-- directly rather than activate(). Rebuilt every paint() (not per-screen,
-- since screen.paint() clears it once up front) so switching screens
-- can't leave a stale hit zone from whatever was on screen before.
local valueRects = {}

-- Tap-to-edit (pilot request, 2026-09): tried native form fields first
-- (form.addNumberField, then form.addTimeField) -- both forced a
-- full-screen form takeover (form.clear() replaces the whole SETUP/LIVE
-- screen; Ethos's Dialog class has no documented way to embed a field for
-- an in-place overlay instead), which the pilot didn't want. Then a
-- compact text +/- row, then real drawn arrow triangles flanking each
-- value -- both worked but neither was the interaction the pilot wanted
-- ("the up and down triangles are way too small and I don't like that
-- interaction"). Landed (pilot request, 2026-09) on unifying with the
-- non-touch interaction instead of inventing a separate touch-only one:
-- tapping the value itself is just a touch-only shortcut into the SAME
-- rotary edit mode ENTER already provides on non-touch radios (see
-- ROTARY_EDIT_FIELDS below) -- toggleEditField()/registerEditTap(),
-- defined after keysFor() since they call it, do that toggle and
-- register the tap zone. Once toggled on, scrolling adjusts the field
-- exactly like non-touch -- no separate up/down logic needed here at all.

-- Physical FS1-FS4 sit ABOVE the touchscreen on the X14 (confirmed by
-- photo, x14_switch_mapping.png), not below it. The on-screen key row is
-- therefore placed directly under the chrome bar -- as close to the
-- physical buttons as the screen itself allows -- rather than at the
-- bottom, so each on-screen label sits right under the button it maps to
-- instead of requiring a top-to-bottom mental jump every time.
local CHROME_H  = 26
local KEY_ROW_H = 30
local CONTENT_TOP = CHROME_H + KEY_ROW_H   -- everything else starts here

-- ---------------------------------------------------------------- focus state

local focus = { [SCREEN.SETUP] = 1, [SCREEN.LIVE] = 1, [SCREEN.SUMMARY] = 1, [SCREEN.LOG] = 1 }

-- Rotary edit mode: nil | "min" | "sec" | "bets". While set, ROTARY
-- scroll bumps that field directly instead of moving footer focus --
-- same up/down functions the touch arrow steppers already use for each
-- field (BETS included, pilot request, 2026-09: "same pattern as min and
-- sec" -- core.bumpBets() already took a signed delta, just needed the
-- same up/down wiring MIN/SEC already have). Set/cleared from
-- screen.event()'s KEY_ENTER_BREAK/KEY_RTN_FIRST/KEY_EXIT_FIRST handling
-- below; self-heals in screen.paint() if the focused key stops matching
-- out from under it (e.g. a real throw arms the bet mid-edit).
local ROTARY_EDIT_FIELDS = {
  min  = { label = "MIN",  up = core.bumpMin, down = core.bumpMinDown },
  sec  = { label = "SEC",  up = core.bumpSec, down = core.bumpSecDown },
  bets = { label = "BETS", up = function() core.bumpBets(1) end, down = function() core.bumpBets(-1) end },
}
local rotaryEditField = nil
local logTop = 1
-- Cached by paintLog() every frame so the rotary handler in screen.event()
-- can clamp logTop to a real upper bound (pilot report, 2026-09: scrolling
-- right had no ceiling at all -- past the actual game count it just
-- rendered nothing, looking like the whole list vanished, rather than
-- stopping once the oldest game was in view).
local logGameCount = 0
local logVisibleRows = 1

-- ---------------------------------------------------------------- S1 setup

local function keysFor(scr)
  if scr == SCREEN.SETUP then return { "MIN", "SEC", "BETS", "START", "CONFIG" } end
  if scr == SCREEN.LIVE then
    local g = core.S.game
    if g and g.armed then
      -- A hit auto-advances in core.lua now (pollLanding), so this
      -- combination (armed + result=="hit") can't actually be observed
      -- here anymore -- by the time this next runs, g.idx/g.armed have
      -- already moved on to the next bet. No FINISH GAME/NEXT BET case
      -- needed.
      local bet = g.bets[g.idx]
      return { "-", "-", "-", bet.attempts > 0 and "-" or "CANCEL" }
    end
    -- No CONFIRM key (pilot request, 2026-09) -- just throwing arms the
    -- bet now (core.lua's handleLaunchFall), so FS4 has nothing to do
    -- here; "-" keeps MIN/SEC/ALL IN aligned to FS1-3 same as before.
    return { "MIN", "SEC", "ALL IN", "-" }
  end
  -- FS1/FS4-aligned, matching every other screen's top row, rather than
  -- two keys stretched to half the screen each -- previously these had no
  -- relationship at all to the physical FS row above the screen.
  if scr == SCREEN.SUMMARY then return { "VIEW GAME LOG", "-", "-", "NEW GAME" } end
  -- OPEN removed (pilot request, 2026-09) -- it was a speced-but-never-
  -- built placeholder (per-bet detail view for a selected game) that did
  -- nothing when pressed, which read as broken rather than "not built
  -- yet." Revisit if that detail view gets built later.
  if scr == SCREEN.LOG then return { "-", "-", "-", "BACK" } end
  return {}
end

-- Tap-to-edit (pilot request, 2026-09) -- see the comment above valueRects'
-- declaration. Defined here, after keysFor(), rather than up with the rest
-- of the touch/rotary state, because toggleEditField() calls keysFor() --
-- a local function defined below the point where it's called is invisible
-- to a closure created above it (Lua resolves an out-of-scope local as a
-- global instead of erroring), so this ordering isn't cosmetic.
local function toggleEditField(field)
  local scr = core.S.screen
  local label = ROTARY_EDIT_FIELDS[field].label
  local keys = keysFor(scr)
  for i, lbl in ipairs(keys) do
    if lbl == label then focus[scr] = i break end
  end
  -- Toggle, not just set: touch has no physical ENTER to press a second
  -- time to leave edit mode, so tapping the same value again has to do
  -- what a second ENTER press does on non-touch.
  rotaryEditField = (rotaryEditField == field) and nil or field
end

local function registerEditTap(x, y, w, h, field)
  valueRects[#valueRects + 1] = {
    x = x, y = y, w = w, h = h,
    action = function() toggleEditField(field) end,
  }
end

local function paintSetup(w, h)
  local t = draw.theme()
  draw.chrome(w, "DLG Poker")
  draw.color(t.bg); lcd.drawFilledRectangle(0, CHROME_H, w, h - CHROME_H)

  local cy = CONTENT_TOP + 18
  lcd.font(FONT_S)
  draw.color(t.dim2)
  local welcome = "WELCOME TO"
  draw.text(math.floor((w - lcd.getTextSize(welcome)) / 2), cy, welcome)

  cy = cy + 16
  lcd.font(FONT_XL)
  draw.color(t.txt)
  local title = "POKER TIMER"
  draw.text(math.floor((w - lcd.getTextSize(title)) / 2), cy, title)

  -- Persistent, visible timer-missing warning (pilot request, 2026-09,
  -- field report: renaming the target Ethos timer broke DLG Poker with
  -- no indication anywhere -- every timerSet/timerReset call was already
  -- silently no-oping on a nil timer object). Shown here rather than only
  -- via core.status() -- that's a transient 3s message, and this needs to
  -- stay up until actually fixed in Settings.
  if core.timerMissing() then
    cy = cy + 20
    lcd.font(FONT_S)
    draw.color(t.bad)
    local err = "TIMER \"" .. tostring(core.S.cfg.timerName) .. "\" NOT FOUND - check Settings"
    draw.text(math.floor((w - lcd.getTextSize(err)) / 2), cy, err, w - 12)
  end

  cy = cy + 34
  lcd.font(FONT_L)
  local suits = { { "\xE2\x99\xA5", t.cardRed }, { "\xE2\x99\xA0", t.cardBlack },
                  { "\xE2\x99\xA6", t.cardRed }, { "\xE2\x99\xA3", t.cardBlack } }
  local totalW = 0
  for i = 1, #suits do totalW = totalW + lcd.getTextSize(suits[i][1]) + 14 end
  local sx = math.floor((w - totalW) / 2)
  for i = 1, #suits do
    draw.color(suits[i][2])
    lcd.drawText(sx, cy, suits[i][1])
    sx = sx + lcd.getTextSize(suits[i][1]) + 14
  end

  -- Dotted section break (pilot request, 2026-09: "the start screen can
  -- use the visual upgrade we gave some other screens") -- LIVE already
  -- uses this exact treatment (t.marker DOTTED rule) under its own header
  -- row; SETUP had nothing separating the branding (title/suits) from the
  -- actual game-setup controls below it.
  cy = cy + 20
  draw.dottedLine(6, cy, w - 12, t.marker)
  cy = cy + 24
  local windowStr = draw.mmss(core.S.setupWindow)
  local betsStr = tostring(core.S.setupBets)

  -- True centred-pair-with-gap layout, matching the mockup's flex
  -- centering, rather than fixed offsets from the midpoint -- each column
  -- is sized to its own widest content (label or value) so short/long
  -- values (e.g. "3" vs "10:00") don't throw off the pairing. Same layout
  -- for touch and non-touch radios (pilot request, 2026-09: "the only
  -- behavior that's different is that you can tap directly on the number
  -- rather than scroll to min and sec at the top of the screen") -- touch
  -- gets tap zones over WINDOW/BETS added below, nothing else changes.
  lcd.font(FONT_S)
  local labelWindowW, labelBetsW = lcd.getTextSize("WINDOW"), lcd.getTextSize("BETS")
  lcd.font(FONT_XL)
  local valWindowW, valBetsW = lcd.getTextSize(windowStr), lcd.getTextSize(betsStr)
  local col1W = math.max(labelWindowW, valWindowW)
  local col2W = math.max(labelBetsW, valBetsW)
  local gap = 48
  local col1X = math.floor((w - (col1W + gap + col2W)) / 2)
  local col2X = col1X + col1W + gap

  lcd.font(FONT_S)
  draw.color(t.dim2)
  draw.text(col1X, cy, "WINDOW")
  draw.text(col2X, cy, "BETS")
  cy = cy + 16

  -- Boxed, tinted background behind each value -- same treatment LIVE's
  -- MIN/SEC digit groups already get (pilot request, 2026-09, same "visual
  -- upgrade" ask). Drawn for touch and non-touch alike -- this is a look-
  -- and-feel change, not a touch affordance; only the accent EDIT border
  -- drawn on top of it below is touch-only.
  lcd.font(FONT_XL)
  local _, valH = lcd.getTextSize("0")
  valH = (valH and valH > 0) and valH or 28
  local boxH = valH + 8
  draw.color(t.alt)
  lcd.drawFilledRectangle(col1X - 8, cy - 4, col1W + 16, boxH)
  lcd.drawFilledRectangle(col2X - 8, cy - 4, col2W + 16, boxH)

  draw.color(t.txt)
  draw.text(col1X, cy, windowStr)
  draw.text(col2X, cy, betsStr)

  if isTouchCapable() then
    -- Tap WINDOW or BETS to enter the same rotary edit mode ENTER gives
    -- non-touch radios (pilot request, 2026-09). WINDOW is one combined
    -- "M:SS" string, not two separate boxes the way LIVE's MIN/SEC
    -- already are -- split its tap zone at the digit boundary between
    -- the minutes part and the ":SS" remainder so "tap minutes or
    -- seconds" works without restructuring the display.
    local minPartW = lcd.getTextSize(tostring(math.floor(core.S.setupWindow / 60)))
    local secPartW = valWindowW - minPartW

    local function editZone(field, x, zw)
      if rotaryEditField == field then
        draw.color(t.accent)
        lcd.drawRectangle(x - 4, cy - 4, zw + 8, boxH, 2)
      end
      registerEditTap(x - 4, cy - 4, zw + 8, boxH, field)
    end
    editZone("min", col1X, minPartW)
    editZone("sec", col1X + minPartW, secPartW)
    -- BETS gets the FULL box width (col2W, not just valBetsW) since it has
    -- no split -- "BETS" the label is usually wider than a 1-digit value,
    -- so this avoids leaving a dead, unresponsive strip inside its own box.
    editZone("bets", col2X, col2W)

    cy = h - 40
    lcd.font(FONT_S)
    draw.color(t.dim)
    draw.text(6, cy, "tap WINDOW or BETS, then scroll to adjust - tap CONFIG, bottom right", w - 12)
  else
    cy = h - 60
    lcd.font(FONT_S)
    draw.color(t.dim)
    local hint = "FS1/FS2 adjust window (hold=0) - FS3 picks bets - FS4 deals you in"
    draw.text(6, cy, hint, w - 12)
    cy = cy + 16
    draw.color(t.dim)
    draw.text(6, cy, "rotate to CONFIG, bottom right", w * 0.6)
  end
end

-- ---------------------------------------------------------------- S2 live

local function paintLive(w, h)
  local t = draw.theme()
  local g = core.S.game
  draw.chrome(w, "DLG Poker")
  draw.color(t.bg); lcd.drawFilledRectangle(0, CHROME_H, w, h - CHROME_H)
  if not g then return end
  local bet = g.bets[g.idx]

  -- SCORE as a badge, not plain text (pilot request, 2026-09, ThrowTrainer
  -- look-and-feel review) -- a filled/bordered pill reads as "data" the
  -- way BET N OF M's plain label doesn't need to. A thin dotted rule
  -- (ThrowTrainer's own chart-boundary marker colour) replaces the empty
  -- gap below the row as an explicit section break.
  lcd.font(FONT_S)
  draw.color(t.dim2)
  draw.text(6, CONTENT_TOP + 6, string.format("BET %d OF %d", g.idx, g.betCount), w * 0.5)
  local scoreStr = "SCORE " .. tostring(g.score) .. "s"
  local scoreBw = draw.badgeSize(scoreStr)
  draw.badge(w - 6 - scoreBw, CONTENT_TOP + 3, scoreStr, t.accent, t.accentBg)

  draw.dottedLine(6, CONTENT_TOP + 28, w - 12, t.marker)

  -- GAME LEFT is shown in every state (editing, armed, bust, hit, all-in
  -- pending), matching the approved mockup -- it had been accidentally
  -- scoped to only the editing branch, so it silently vanished the moment
  -- a bet was armed. Centred, matching the mockup's text-align rather than
  -- the left-aligned draw it had before.
  local cy = CONTENT_TOP + 36
  draw.color(t.dim2)
  local gl = "GAME LEFT"
  draw.text(math.floor((w - lcd.getTextSize(gl)) / 2), cy, gl)
  cy = cy + 14
  lcd.font(FONT_L)
  draw.color(t.txt)
  local glVal = draw.mmss(g.deadline - os.time())
  draw.text(math.floor((w - lcd.getTextSize(glVal)) / 2), cy, glVal)
  cy = cy + 34

  if not g.armed then
    -- "Just hit" banner (pilot request, 2026-09): a hit now auto-advances
    -- straight here instead of stopping on its own screen first, so the
    -- credit needs to be shown somewhere -- alongside the NEW bet's own
    -- editing controls, since g.idx has already moved on by the time
    -- this paints. g.idx - 1's own result can only be "hit" here at all
    -- immediately after that auto-advance (any other not-armed state --
    -- game start, cancelled all-in -- has no fresher bet to reference, or
    -- that bet was never a hit), so this can't show stale info from
    -- several bets back.
    if g.idx > 1 and g.bets[g.idx - 1].result == "hit" then
      lcd.font(FONT_S)
      local hitMsg = string.format("BET %d: HIT +%ds credited", g.idx - 1, g.bets[g.idx - 1].scored_s or 0)
      -- Gap sized from the badge's OWN measured height, not a guessed
      -- constant (pilot report, 2026-09, real hardware photo: the fixed
      -- 26px gap this used to use was too tight against FONT_S's real
      -- line height on real hardware, so the badge visibly overlapped the
      -- MIN:SEC boxes drawn right below it).
      local hitBw, hitBh = draw.badgeSize(hitMsg)
      draw.badge(math.floor((w - hitBw) / 2), cy, hitMsg, t.good, t.goodBg)
      cy = cy + hitBh + 12
    end

    lcd.font(FONT_XL)
    draw.color(t.accent)
    local minStr = string.format("%02d", g.editMin)
    local secStr = string.format("%02d", g.editSec)
    local minW = lcd.getTextSize(minStr)
    local colonW = lcd.getTextSize(":")
    local secW = lcd.getTextSize(secStr)
    local totalW = minW + colonW + secW + 40
    local minX = math.floor((w - totalW) / 2)
    local colonX = minX + minW + 20
    local secX = colonX + colonW + 20

    -- Boxed, tinted background behind each digit group (spec: mockup's
    -- "giant, boxed, tied to its switch" treatment) -- this had been
    -- planned but never actually drawn.
    local _, boxH = lcd.getTextSize("0")
    boxH = (boxH and boxH > 0) and boxH + 8 or 48
    draw.color(t.alt)
    lcd.drawFilledRectangle(minX - 8, cy - 4, minW + 16, boxH)
    lcd.drawFilledRectangle(secX - 8, cy - 4, secW + 16, boxH)

    draw.color(t.accent)
    draw.text(minX, cy, minStr)
    draw.text(colonX, cy, ":")
    draw.text(secX, cy, secStr)

    -- Touch pilots (pilot request, 2026-09) tap the boxed digit group
    -- directly to enter the same rotary edit mode ENTER gives non-touch
    -- radios -- the box itself (already drawn above) is the tap zone, no
    -- separate arrow widget needed. Everyone still gets the FS1/FS2
    -- captions underneath -- FS1/FS2 still bump the field one-shot same
    -- as always, touch or not.
    if isTouchCapable() then
      local function editZone(field, bx, bw)
        if rotaryEditField == field then
          draw.color(t.accent)
          lcd.drawRectangle(bx, cy - 4, bw, boxH, 2)
        end
        registerEditTap(bx, cy - 4, bw, boxH, field)
      end
      editZone("min", minX - 8, minW + 16)
      editZone("sec", secX - 8, secW + 16)
    end

    lcd.font(FONT_S)
    draw.color(t.dim)
    local capMin, capSec = "FS1 MIN", "FS2 SEC"
    draw.text(minX + math.floor((minW - lcd.getTextSize(capMin)) / 2), cy + boxH + 6, capMin)
    draw.text(secX + math.floor((secW - lcd.getTextSize(capSec)) / 2), cy + boxH + 6, capSec)

    -- Spells out what used to need a CONFIRM press explaining itself
    -- (pilot request, 2026-09): now that a throw is the only thing that
    -- arms+starts a bet, it needs to say so somewhere, or "how do I
    -- actually start this" isn't evident from the screen alone anymore.
    lcd.font(FONT_S)
    draw.color(t.dim)
    local launchHint = "LAUNCH to lock bet & start timer"
    draw.text(math.floor((w - lcd.getTextSize(launchHint)) / 2), cy + boxH + 26, launchHint)
  elseif g.allInPending then
    lcd.font(FONT_XL)
    draw.color(t.cardRed)
    local allin = "ALL IN"
    draw.text(math.floor((w - lcd.getTextSize(allin)) / 2), cy + 10, allin)
    lcd.font(FONT_M)
    draw.color(t.amber)
    local est = draw.mmss(math.max(0, g.deadline - os.time()))
    draw.text(math.floor((w - lcd.getTextSize("~" .. est)) / 2), cy + 52, "~" .. est)
    lcd.font(FONT_S)
    draw.color(t.dim)
    local note = "locks in the instant you launch"
    draw.text(math.floor((w - lcd.getTextSize(note)) / 2), cy + 80, note)
  else
    lcd.font(FONT_XL)
    local attemptY = cy + 68   -- default; pushed down for the two-line
                                 -- TARGET REACHED state below, to avoid
                                 -- the two overlapping

    -- bet.result == "hit" is unreachable here (pilot request, 2026-09):
    -- a hit now auto-advances in core.lua's pollLanding the instant it's
    -- scored, so g.idx/g.armed have already moved on to the next bet by
    -- the time this next paints. See the "BET N: HIT +Ns" banner in the
    -- `not g.armed` branch above instead -- that's where the credit is
    -- shown now, alongside the new bet's own editing controls, rather
    -- than on a dedicated screen that blocked on an explicit press.
    if core.isLaunchPressed() then
      -- Explicit press confirmation -- previously the screen looked
      -- identical whether the switch had been touched or not, giving no
      -- feedback that a press even registered. This confirms Launch mode
      -- directly and states what release will do next. Checked BEFORE
      -- bust deliberately: a retry press after a bust was still showing
      -- the stale "BUST" screen throughout the whole press, since bust
      -- only clears on release (see handleLaunchFall) -- this is the same
      -- "confirm the press itself" fix already applied to the initial
      -- arm, just no longer skipped when the underlying result is "bust".
      lcd.font(FONT_L)
      draw.color(t.amber)
      local big = "LAUNCH MODE"
      draw.text(math.floor((w - lcd.getTextSize(big)) / 2), cy, big)
      lcd.font(FONT_S)
      draw.color(t.amber)
      local sub = (bet.attempts > 0)
        and "release to enter Zoom - timer will RESTART"
        or  "release to enter Zoom and START the timer"
      draw.text(math.floor((w - lcd.getTextSize(sub)) / 2), cy + 40, sub)

    elseif bet.result == "bust" then
      draw.color(t.bad)
      local big = "BUST"
      draw.text(math.floor((w - lcd.getTextSize(big)) / 2), cy, big)
      lcd.font(FONT_S)
      draw.color(t.bad)
      local sub = "stays locked - relaunch to retry"
      draw.text(math.floor((w - lcd.getTextSize(sub)) / 2), cy + 46, sub)

    elseif bet.attempts > 0 then
      -- A real release has happened -- this is what was missing entirely
      -- before: the screen showed a frozen "ARMED - LAUNCH TO START" no
      -- matter what state the bet was actually in, giving no visual
      -- confirmation that a launch was even detected. This now reads the
      -- ACTUAL live timer value every frame, in green, so the pilot can
      -- glance down and see it really is counting rather than needing to
      -- wait for Timer3's own audio callout. A re-press before the
      -- elevator-exit confirms it will show up here automatically too --
      -- it is just displaying whatever the real timer currently reads,
      -- and core.lua's own reset already changed that value directly.
      draw.color(t.good)
      local liveVal = core.liveTimerValue()
      local live = draw.mmss(liveVal)
      draw.text(math.floor((w - lcd.getTextSize(live)) / 2), cy, live)
      local targetReached = liveVal and liveVal <= 0
      if targetReached then
        -- Bigger AND bolder, per direct feedback -- this is the moment
        -- that matters most and it was using the same small sub-label
        -- font as every other status line, easy to miss at a glance.
        lcd.font(FONT_L)
        draw.color(t.good)
        local sub = "TARGET REACHED"
        draw.text(math.floor((w - lcd.getTextSize(sub)) / 2), cy + 44, sub)
        lcd.font(FONT_S)
        local sub2 = "land when ready"
        draw.text(math.floor((w - lcd.getTextSize(sub2)) / 2), cy + 84, sub2)
        attemptY = cy + 106
      else
        lcd.font(FONT_S)
        draw.color(t.good)
        local sub = core.S.flightConfirmed and "LOCKED - brakes to land" or "COUNTING - push elevator to confirm"
        draw.text(math.floor((w - lcd.getTextSize(sub)) / 2), cy + 46, sub)
      end

    else
      -- Genuinely never launched yet -- the only state where the static
      -- target (not yet a live countdown) is the correct thing to show.
      draw.color(t.amber)
      local big = draw.mmss(bet.target_s)
      draw.text(math.floor((w - lcd.getTextSize(big)) / 2), cy, big)
      lcd.font(FONT_S)
      draw.color(t.amber)
      local sub = "ARMED - LAUNCH TO START"
      draw.text(math.floor((w - lcd.getTextSize(sub)) / 2), cy + 46, sub)
    end

    -- Attempt count, shown once at least one real launch has happened --
    -- this is what explains CANCEL disappearing from the footer (only
    -- available before the first real attempt): without this, the pilot
    -- has no way to see why it vanished. Wording made explicit (pilot
    -- question, 2026-09: "is this per-bet or a game total?") -- bet.attempts
    -- already WAS per-bet all along (newBet() starts every bet at 0,
    -- see core.lua), this was purely a label-clarity gap, not a data
    -- model change. A badge specifically on a BUST (matching the SCORE/
    -- HIT badges above -- pilot request, 2026-09, ThrowTrainer look-and-
    -- feel review), since that's the exact moment a pilot needs this
    -- number to decide whether to retry; a small dim line was easy to
    -- miss right when it mattered most. Plain dim text elsewhere -- those
    -- states don't need the same visual weight.
    if bet.attempts > 0 then
      local at = string.format("Attempt %d on this bet", bet.attempts)
      lcd.font(FONT_S)
      if bet.result == "bust" then
        local atBw = draw.badgeSize(at)
        draw.badge(math.floor((w - atBw) / 2), attemptY, at, t.bad, t.badBg)
      else
        draw.color(t.dim)
        draw.text(math.floor((w - lcd.getTextSize(at)) / 2), attemptY, at)
      end
    end
  end

  local st = core.status()
  if st then
    lcd.font(FONT_S)
    draw.color(t.amber)
    draw.text(6, h - 44, st, w - 12)
  end

  -- Same persistent timer-missing warning as SETUP (pilot request,
  -- 2026-09) -- reuses the space the old L=/Z=/Br= debug readout used to
  -- occupy at the very bottom, so nothing else needs to move to fit it.
  if core.timerMissing() then
    lcd.font(FONT_S)
    draw.color(t.bad)
    local err = "TIMER \"" .. tostring(core.S.cfg.timerName) .. "\" NOT FOUND - check Settings"
    draw.text(6, h - 20, err, w - 12)
  end
end

-- ---------------------------------------------------------------- S3 summary

local function paintSummary(w, h)
  local t = draw.theme()
  draw.chrome(w, "DLG Poker")
  draw.color(t.bg); lcd.drawFilledRectangle(0, CHROME_H, w, h - CHROME_H)
  local g = core.S.game
  if not g then return end

  lcd.font(FONT_M)
  draw.color(t.txt)
  local title = "GAME COMPLETE"
  draw.text(math.floor((w - lcd.getTextSize(title)) / 2), CONTENT_TOP + 8, title)

  -- Brought up to the same divider language as LIVE and LOG (pilot
  -- report, 2026-09: this screen was skipped entirely in the ThrowTrainer
  -- look-and-feel pass -- no dividers at all, the one screen that never
  -- got it). Rows stay plain colored text rather than full badges,
  -- deliberately -- up to 5 bets (config.lua clamps Bets per game to
  -- 1-5) have to fit in the ~180px between the header and the score, and
  -- a badge's extra chrome per row, multiplied by 5, risks pushing TOTAL
  -- SCORE off the bottom of a 272px-tall screen. Row height (20px) is
  -- unchanged from before this pass for exactly that reason -- only the
  -- two dividers are new vertical cost, and that's a one-time ~22px, not
  -- 5x-multiplied.
  draw.dottedLine(10, CONTENT_TOP + 28, w - 20, t.marker)

  local cy = CONTENT_TOP + 38
  lcd.font(FONT_S)
  for i = 1, g.betCount do
    local b = g.bets[i]
    draw.color(t.dim2)
    draw.text(10, cy, "Bet " .. i)
    local col = t.txt
    if b.result == "hit" then col = t.good
    elseif b.result == "bust" then col = t.bad
    elseif b.result == "unresolved" then col = t.amber end
    draw.color(col)
    local resultStr = string.format("%ds - %s (%d)", b.target_s or 0, b.result, b.attempts)
    draw.text(w - 10 - lcd.getTextSize(resultStr), cy, resultStr)
    cy = cy + 20
  end

  cy = cy + 8
  draw.dottedLine(10, cy, w - 20, t.marker)
  cy = cy + 16

  draw.color(t.dim2)
  local lbl = "TOTAL SCORE"
  draw.text(math.floor((w - lcd.getTextSize(lbl)) / 2), cy, lbl)
  cy = cy + 16
  lcd.font(FONT_XL)
  draw.color(t.good)
  local scoreStr = tostring(g.score) .. "s"
  draw.text(math.floor((w - lcd.getTextSize(scoreStr)) / 2), cy, scoreStr)
end

-- ---------------------------------------------------------------- S4 log

local function paintLog(w, h)
  local t = draw.theme()
  draw.chrome(w, "DLG Poker")
  draw.color(t.bg); lcd.drawFilledRectangle(0, CHROME_H, w, h - CHROME_H)

  local games = core.recentGames(20)
  local avg5, best = core.gameStats()
  logGameCount = #games

  -- Surfaced here for the first time -- previously a storage/write failure
  -- (S.ioError, set by appendRow/rewrite on any I/O error) was silently
  -- invisible on this specific screen: the log would just look empty with
  -- no indication why, indistinguishable from "genuinely no games yet."
  if core.S.ioError then
    lcd.font(FONT_S)
    draw.color(t.bad)
    draw.text(10, CONTENT_TOP + 6, "storage error: " .. tostring(core.S.ioError), w - 20)
    draw.text(10, CONTENT_TOP + 26, "check CONFIG > About > Storage", w - 20)
    return
  end

  lcd.font(FONT_S)
  draw.color(t.dim2)
  draw.text(10, CONTENT_TOP + 6, "DATE", w * 0.3)
  draw.text(w * 0.34, CONTENT_TOP + 6, "SCORE", w * 0.3)
  draw.text(w * 0.62, CONTENT_TOP + 6, "BETS", w * 0.35)

  if #games == 0 then
    -- Disambiguates "genuinely no completed games yet" from a silent
    -- write failure -- previously these looked identical (an empty table
    -- with nothing below the headers, no explanation either way).
    lcd.font(FONT_S)
    draw.color(t.dim)
    draw.text(10, CONTENT_TOP + 30, "no completed games yet", w - 20)
    return
  end

  local cy = CONTENT_TOP + 24
  local rows = math.floor((h - cy - 70) / 20)
  logVisibleRows = math.max(1, rows)
  -- Wrapped defensively: a single malformed CSV row (a partial write from
  -- an earlier crash/power-loss, for instance) should degrade to a
  -- placeholder line, not take down the whole screen with a hard error.
  for i = logTop, math.min(logTop + rows - 1, #games) do
    local ok, err = pcall(function()
      local gm = games[i]
      if i == 1 then
        draw.color(t.alt); lcd.drawFilledRectangle(0, cy - 2, w, 20)
        draw.color(t.accent)
      else
        draw.color(t.dim2)
      end
      draw.text(10, cy, os.date("%b %d", gm.ts), w * 0.3)
      draw.text(w * 0.34, cy, tostring(gm.score) .. "s", w * 0.25)
      local betsStr
      if gm.hits then
        betsStr = string.format("%d/%d", gm.hits, gm.betCount)
      else
        betsStr = tostring(gm.betCount)   -- older row, written before hit
      end                                  -- counts were tracked
      draw.text(w * 0.62, cy, betsStr .. (i == 1 and " - latest" or ""), w * 0.35)
    end)
    if not ok then
      draw.color(t.bad)
      draw.text(10, cy, "row unavailable", w - 20)
    end
    cy = cy + 20
  end

  cy = h - 56
  -- Same thin dotted section-break as LIVE's top row (pilot request,
  -- 2026-09, ThrowTrainer look-and-feel review) -- separates the game
  -- list from the vs-average/vs-best stats below it.
  draw.dottedLine(10, cy, w - 20, t.marker)
  cy = cy + 8
  lcd.font(FONT_S)
  if avg5 then
    draw.color(t.dim2)
    draw.text(10, cy, string.format("vs avg (last 5) %ds", math.floor(avg5)))
    local delta = (games[1] and games[1].score or 0) - avg5
    draw.color(delta >= 0 and t.good or t.bad)
    local ds = draw.signed(delta)
    draw.text(w - 10 - lcd.getTextSize(ds), cy, ds)
  end
  cy = cy + 20
  if best then
    draw.color(t.dim2)
    draw.text(10, cy, string.format("vs best ever %ds", best))
    local delta = (games[1] and games[1].score or 0) - best
    draw.color(delta >= 0 and t.good or t.bad)
    local ds = draw.signed(delta)
    draw.text(w - 10 - lcd.getTextSize(ds), cy, ds)
  end
end

-- ---------------------------------------------------------------- key row

local function paintKeys(w, h, scr)
  local t = draw.theme()
  local keys = keysFor(scr)
  keyRects = {}   -- rebuilt every paint -- see the touch-support note above
  if #keys == 0 then return end
  local kh = KEY_ROW_H
  local ky = CHROME_H   -- directly under the chrome bar / physical FS row,
                         -- not the bottom -- see the CONTENT_TOP note above

  -- S1 specifically has a 5th item (CONFIG) with no physical FS mapping --
  -- FS1-FS4 only cover MIN/SEC/BETS/START. Rendering all 5 in the top row
  -- would break the FS-alignment this row exists for, so CONFIG renders
  -- as its own button in the bottom-right corner instead, reachable by
  -- rotating focus onto it (FS-only radios) or tapping it directly
  -- (touch-capable radios) -- never a physical key label like "FS1 MIN"
  -- anywhere else in the UI either way.
  local topKeys = keys
  local configIdx = nil
  if scr == SCREEN.SETUP and #keys == 5 then
    topKeys = { keys[1], keys[2], keys[3], keys[4] }
    configIdx = 5
  end

  -- Nothing to press (pilot request, 2026-09): if every slot in the row
  -- is "-" -- e.g. mid-flight, when none of the footer keys do anything
  -- until landing -- the row is pure clutter, four empty bordered boxes
  -- with nothing behind them. Skip drawing it entirely rather than
  -- rendering four dashes; the CONFIG button (drawn separately below, if
  -- present) is unaffected either way.
  local anyActive = false
  for i = 1, #topKeys do
    if topKeys[i] ~= "-" then anyActive = true break end
  end

  if anyActive then
    local kw = math.floor(w / #topKeys)
    lcd.font(FONT_S)
    for i = 1, #topKeys do
      local kx = (i - 1) * kw
      local label = topKeys[i]
      -- Rotary edit mode (pilot request, 2026-09): scroll focus to
      -- MIN/SEC/BETS, press ENTER to start editing it directly -- rotary
      -- scroll then bumps that field up/down instead of moving focus,
      -- press ENTER again to leave. Filled instead of outlined so it
      -- reads as unmistakably different from plain focus -- "you're
      -- inside this field now."
      local editing = rotaryEditField and focus[scr] == i
        and label == ROTARY_EDIT_FIELDS[rotaryEditField].label
      draw.color(t.border)
      lcd.drawRectangle(kx + 1, ky, kw - 2, kh - 2, 1)
      if editing then
        draw.color(t.accent)
        lcd.drawFilledRectangle(kx, ky, kw, kh - 1)
      elseif focus[scr] == i then
        draw.color(t.accent)
        lcd.drawRectangle(kx, ky, kw, kh - 1, 2)
      end
      if editing then
        draw.color(t.bg)
      else
        draw.color((label == "-") and t.dim or t.txt)
      end
      local tw = lcd.getTextSize(label)
      draw.text(kx + math.floor((kw - tw) / 2), ky + 8, label, kw - 4)
      if isTouchCapable() and label ~= "-" then
        keyRects[i] = { x = kx, y = ky, w = kw, h = kh }
      end
    end
  end

  if configIdx then
    local label = keys[configIdx]
    lcd.font(FONT_S)
    local tw = lcd.getTextSize(label)
    local bw = tw + 24
    local bh = KEY_ROW_H
    local bx = w - bw - 6
    local by = h - bh - 6
    draw.color(t.border)
    lcd.drawRectangle(bx + 1, by, bw - 2, bh - 2, 1)
    if focus[scr] == configIdx then
      draw.color(t.accent)
      lcd.drawRectangle(bx, by, bw, bh - 1, 2)
    end
    draw.color(t.txt)
    draw.text(bx + 12, by + 8, label)
    if isTouchCapable() then
      keyRects[configIdx] = { x = bx, y = by, w = bw, h = bh }
    end
  end
end

-- ---------------------------------------------------------------- paint / event

function screen.paint(w, h)
  if inForm then return end   -- form owns painting while open
  valueRects = {}   -- cleared every dispatched paint, not just SETUP/LIVE's
                     -- own -- otherwise a stale rect from whichever screen
                     -- was last shown would keep intercepting taps on a
                     -- screen (SUMMARY/LOG) that never repopulates it.
  local scr = core.S.screen
  if rotaryEditField then
    if keysFor(scr)[focus[scr] or 1] ~= ROTARY_EDIT_FIELDS[rotaryEditField].label then
      rotaryEditField = nil
    end
  end
  -- Wrapped defensively -- confirmed a real bug (CONFIRM reachable on
  -- SUMMARY/LOG, corrupting bet data) via code review after a hard Ethos
  -- error was reported opening the log, and fixed that in core.lua's
  -- wakeup() dispatch. This wrapper is the belt to that fix's suspenders:
  -- any OTHER rendering error, on any screen, degrades to a visible,
  -- recoverable message instead of the tool erroring out entirely.
  local ok, err = pcall(function()
    if scr == SCREEN.SETUP then paintSetup(w, h)
    elseif scr == SCREEN.LIVE then paintLive(w, h)
    elseif scr == SCREEN.SUMMARY then paintSummary(w, h)
    elseif scr == SCREEN.LOG then paintLog(w, h)
    end
  end)
  if not ok then
    draw.color(draw.theme().bad)
    lcd.font(FONT_S)
    draw.text(6, CONTENT_TOP + 10, "display error - try BACK or restart", w - 12)
    draw.text(6, CONTENT_TOP + 30, tostring(err), w - 12)
  end
  paintKeys(w, h, scr)
end

local function activate(scr, i)
  local keys = keysFor(scr)
  local label = keys[i]
  if not label or label == "-" then return end

  -- MIN/SEC/BETS below toggle rotary edit mode rather than bumping once --
  -- on non-touch these labels are never reached here at all (screen.event()'s
  -- ENTER handler intercepts them via ROTARY_EDIT_FIELDS before activate()
  -- is ever called), so this branch only ever runs from a touch tap on the
  -- FOOTER key itself. It used to just bump the field once, inconsistent
  -- with tapping the value/box directly (which already toggled edit mode)
  -- -- pilot report, 2026-09: "clicking on MIN should highlight the min box
  -- and allow me to adjust it using the scroll -- it does neither." Footer
  -- key and value are now just two tap targets for the identical action.
  if scr == SCREEN.SETUP then
    if label == "MIN" then toggleEditField("min")
    elseif label == "SEC" then toggleEditField("sec")
    elseif label == "BETS" then toggleEditField("bets")
    elseif label == "START" then core.startGame()
    elseif label == "CONFIG" then
      inForm = true
      form.clear()
      config.build()
    end
  elseif scr == SCREEN.LIVE then
    if label == "MIN" then toggleEditField("min")
    elseif label == "SEC" then toggleEditField("sec")
    elseif label == "ALL IN" then core.allIn()
    elseif label == "CANCEL" then core.cancelArm()
    elseif label == "NEXT BET" then core.nextBet() end
  elseif scr == SCREEN.SUMMARY then
    if label == "VIEW GAME LOG" then core.S.screen = SCREEN.LOG logTop = 1
    elseif label == "NEW GAME" then core.S.game = nil core.S.screen = SCREEN.SETUP end
  elseif scr == SCREEN.LOG then
    if label == "BACK" then core.S.screen = SCREEN.SUMMARY end
  end
end

function screen.event(value, x, y)
  -- Must run before EVERY other gate, including inForm -- activate() can
  -- itself flip inForm true (CONFIG key) or change core.S.screen (VIEW
  -- GAME LOG, NEW GAME, BACK). If this swallow check were nested inside
  -- the inForm branch below, the release half of a tap that just opened
  -- the form would arrive with inForm already true and fall through to
  -- "let the form own everything else" unswallowed.
  if touchConsuming and isTouchCapable() and x and y and x > 0 and y > 0 then
    touchConsuming = false
    return true
  end

  if inForm then
    if value == KEY_RTN_FIRST or value == KEY_EXIT_FIRST or value == 99 then
      form.clear()
      inForm = false
      return true
    end
    return false   -- let the form own everything else
  end

  local scr = core.S.screen

  -- Touch: hit-test against the rectangles paintKeys()/paintSetup()/
  -- paintLive() recorded this same frame. Same caveat already documented
  -- in this project's Poker Probe -- what a genuine touch event reports
  -- for `category` is unconfirmed, so this deliberately keys off raw x/y
  -- rather than category, gated by the touch-capable board check so it
  -- can never activate on an X14 even if a stray event arrives.
  --
  -- valueRects checked first: it's the more specific target (the +/-
  -- stepper buttons), and a button can sit close to other content, so
  -- resolving it before the footer keyRects avoids any ambiguity if the
  -- two ever overlapped.
  if isTouchCapable() and x and y and x > 0 and y > 0 then
    for _, r in ipairs(valueRects) do
      if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
        r.action()
        touchConsuming = true
        return true
      end
    end
    for i, r in pairs(keyRects) do
      if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
        focus[scr] = i
        activate(scr, i)
        touchConsuming = true
        return true
      end
    end
  end

  if value == KEY_ROTARY_RIGHT or value == KEY_ROTARY_LEFT then
    local n = math.abs(tonumber(x) or 1)
    if n < 1 then n = 1 end
    local d = (value == KEY_ROTARY_RIGHT) and n or -n
    if rotaryEditField then
      -- In edit mode: scroll bumps the field directly, same granularity
      -- (whole minutes / 10s / 1 bet) as the footer key and the touch
      -- arrow steppers -- reuses those exact functions rather than
      -- inventing a separate step size.
      local field = ROTARY_EDIT_FIELDS[rotaryEditField]
      local fn = (d > 0) and field.up or field.down
      for _ = 1, math.abs(d) do fn() end
    elseif scr == SCREEN.LOG then
      -- Clamped at both ends (pilot report, 2026-09): previously only
      -- floored at 1, with no ceiling -- scrolling right past the actual
      -- game count rendered nothing at all (logTop > #games means the
      -- paintLog() draw loop's range is empty), which looked like the
      -- whole list had vanished rather than stopping once the oldest
      -- game was in view.
      local maxTop = math.max(1, logGameCount - logVisibleRows + 1)
      logTop = math.max(1, math.min(maxTop, logTop + d))
    else
      local keys = keysFor(scr)
      if #keys > 0 then
        focus[scr] = ((focus[scr] - 1 + d) % #keys) + 1
      end
    end
    return true
  end

  if value == KEY_ENTER_BREAK then
    if rotaryEditField then
      rotaryEditField = nil   -- second ENTER leaves edit mode
      return true
    end
    -- LOG's ROTARY is fully dedicated to scrolling the list (see above),
    -- so focus[SCREEN.LOG] never moves off its initial value -- ENTER
    -- would otherwise always try to activate whatever that stuck value
    -- happens to be (OPEN, a placeholder that does nothing -- see
    -- keysFor) and BACK would be unreachable except via the FS4 physical
    -- switch or RTN/EXIT (pilot report, 2026-09: exactly this gap).
    -- ENTER goes straight to BACK on this one screen instead.
    if scr == SCREEN.LOG then
      local keys = keysFor(scr)
      for i, lbl in ipairs(keys) do
        if lbl == "BACK" then
          activate(scr, i)
          return true
        end
      end
    end
    -- Rotary edit mode (pilot request, 2026-09): ENTER on MIN/SEC/BETS
    -- starts editing that field directly instead of just bumping it once
    -- -- matches Ethos's own "focus a field, press ENTER, scroll to
    -- adjust" pattern rather than treating them as plain one-shot buttons.
    local label = keysFor(scr)[focus[scr] or 1]
    for key, field in pairs(ROTARY_EDIT_FIELDS) do
      if field.label == label then
        rotaryEditField = key
        return true
      end
    end
    activate(scr, focus[scr] or 1)
    return true
  end

  if value == KEY_RTN_FIRST or value == KEY_EXIT_FIRST or value == 99 then
    if rotaryEditField then
      rotaryEditField = nil
      return true
    end
    if scr == SCREEN.LOG then core.S.screen = SCREEN.SUMMARY return true end
    return false
  end

  return false
end

return screen

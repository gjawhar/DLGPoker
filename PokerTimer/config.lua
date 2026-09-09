-- DLG Poker S5 config. Real Ethos form API, same pattern already proven
-- in Throw Trainer's config.lua -- source pickers for switch assignment
-- use the radio's own picker rather than a hand-rolled one.

local core = ...
local config = {}

local function cfg() return core.S.cfg end

local function numField(line, min, max, key, suffix)
  local f = form.addNumberField(line, nil, min, max,
    function() return cfg()[key] end,
    function(v) cfg()[key] = v core.saveConfig() end)
  if suffix then f:suffix(suffix) end
  return f
end

-- Sub-second thresholds (default 1.0s, 0.8s) are edited as whole TENTHS
-- of a second, not raw seconds -- Ethos's number field coerced a 0.8
-- default toward 0 on real hardware (confirmed: the field displayed "0s"),
-- which silently broke hold-to-reset by making it fire on virtually the
-- first wakeup() cycle after a press. Editing in integer tenths sidesteps
-- needing decimal support in the field at all; the getter/setter here is
-- the only place the /10 and *10 conversion happens, so core.lua's own
-- logic keeps working in real seconds throughout, unchanged.
local function tenthsField(line, min, max, key)
  local f = form.addNumberField(line, nil, min, max,
    function() return math.floor((cfg()[key] or 0) * 10 + 0.5) end,
    function(v) cfg()[key] = v / 10 core.saveConfig() end)
  f:suffix("x0.1s")
  return f
end

-- Switch roles are stored as NAME STRINGS (core.lua S9), not Source
-- objects -- Source userdata can't survive saveConfig()'s CSV writer, so
-- storing it directly meant a manual pick was silently lost on every
-- restart. This bridges Ethos's own Source picker (which naturally wants
-- to hand back a live Source) to the persisted name underneath it.
local function switchField(line, nameKey)
  return form.addSourceField(line, nil,
    function()
      local n = cfg()[nameKey]
      if not n then return nil end
      local ok, src = pcall(system.getSource, { name = n })
      if ok then return src end
      return nil
    end,
    function(v)
      if v then
        local ok, n = pcall(function() return v:name() end)
        cfg()[nameKey] = ok and n or nil
      else
        cfg()[nameKey] = nil
      end
      core.saveConfig()
      core.resolveSwitches()   -- take effect immediately, no restart needed
    end)
end

function config.build()
  local panel = form.addExpansionPanel("Game defaults")

  local line = panel:addLine("Window default")
  numField(line, 60, 3600, "windowDefault", "s")

  line = panel:addLine("Bets per game")
  numField(line, 1, 5, "betsDefault")

  -- Target timer / Landing switch (spec S12: dropdowns, pre-filled) --
  -- Ethos's own source/choice fields double as the "dropdown" the mockups
  -- show; a plain text field is used here rather than a source picker
  -- since these name a specific Ethos entity (a timer, a logic switch) by
  -- string, and there is no enumerable fixed list to offer as real choices.
  panel = form.addExpansionPanel("Timer")
  line = panel:addLine("Target timer")
  form.addTextField(line, nil,
    function() return cfg().timerName end,
    -- Takes effect immediately now (pilot request, 2026-09) -- this used
    -- to only save the name, not re-resolve, so retyping the CORRECT
    -- current name here silently didn't fix anything until the next
    -- restart. Same pattern switchField() already uses for FS1-4 names.
    function(v) cfg().timerName = v core.saveConfig() core.resolveTimerNow() end)

  line = panel:addLine("Status")
  form.addStaticText(line, nil, core.timerMissing()
    and ("NOT FOUND: \"" .. tostring(cfg().timerName) .. "\" -- see below")
    or "Resolved OK")

  line = panel:addLine("Rename back to default")
  form.addButton(line, nil, { text = "Use \"" .. core.defaults().timerName .. "\" again", press = function()
    -- Only acts on the CURRENTLY-RESOLVED timer (pilot request, 2026-09:
    -- "can you have the lua change the name back") -- if Target timer
    -- above isn't resolved yet, fix that first (retype it to the
    -- timer's actual current name); this then renames THAT timer back
    -- to the default and points Target timer at it again.
    core.renameTimerToDefault()
    return true
  end })

  line = panel:addLine("REQUIRED one-time setup")
  form.addStaticText(line, nil,
    "In SYSTEM > TIMERS, set this timer's Start condition to Always. " ..
    "Confirmed on real hardware: without this, the countdown is set up " ..
    "correctly but never actually starts counting down. The app attempts " ..
    "this automatically, but that alone was not sufficient on a real radio " ..
    "even though it worked in the simulator -- this manual step is the " ..
    "one that's actually confirmed necessary.")
  line = panel:addLine("Note")
  form.addStaticText(line, nil,
    "Set countdown and alert beeps for this timer in SYSTEM > TIMERS -- " ..
    "DLG Poker never touches those, only the duration (spec S6.2).")

  panel = form.addExpansionPanel("Landing detection")
  line = panel:addLine("Mode")
  form.addChoiceField(line, nil,
    { { "Lua-timed (no radio setup)", 1 }, { "Native logic switch", 2 } },
    function() return (cfg().landingMode == "native") and 2 or 1 end,
    function(v) cfg().landingMode = (v == 2) and "native" or "lua" core.saveConfig() end)

  line = panel:addLine("Landing switch")
  form.addTextField(line, nil,
    function() return cfg().landingSwitchName end,
    function(v) cfg().landingSwitchName = v core.saveConfig() end)

  line = panel:addLine("Ignore quick taps")
  tenthsField(line, 1, 50, "landingDebounce")
  line = panel:addLine("Note")
  form.addStaticText(line, nil,
    "Blocks an accidental brake tap mid-flight from ending your bet early.")

  panel = form.addExpansionPanel("Controls")
  panel:open(false)
  line = panel:addLine("+MIN switch")
  switchField(line, "minSwitchName")
  line = panel:addLine("+SEC switch")
  switchField(line, "secSwitchName")
  line = panel:addLine("ALL IN switch")
  switchField(line, "allinSwitchName")
  -- Still named "confirm" internally (S.confirmSwitchSrc, cfg key
  -- confirmSwitchName) -- that's just the saved config key, unrelated to
  -- what it's actually labelled or does now. Relabelled here (pilot
  -- request, 2026-09: a throw arms/starts a bet now, so this switch's
  -- remaining jobs are START on Setup and CANCEL/NEXT BET on Live).
  line = panel:addLine("START/CANCEL/NEXT switch")
  switchField(line, "confirmSwitchName")
  line = panel:addLine("Hold-to-reset")
  tenthsField(line, 2, 30, "holdResetThreshold")
  line = panel:addLine("Stuck switch warning")
  numField(line, 0.5, 10, "stuckWarnThreshold", "s")

  panel = form.addExpansionPanel("Display")
  panel:open(false)
  line = panel:addLine("Mode")
  form.addChoiceField(line, nil,
    { { "Day (default)", 1 }, { "Night", 2 } },
    function() return (cfg().display == "night") and 2 or 1 end,
    function(v) cfg().display = (v == 2) and "night" or "day" core.saveConfig() end)

  panel = form.addExpansionPanel("About")
  panel:open(false)
  line = panel:addLine("Version")
  form.addStaticText(line, nil, core.VERSION)
  line = panel:addLine("Storage")
  form.addStaticText(line, nil, core.S.dir or "unavailable")
end

return config

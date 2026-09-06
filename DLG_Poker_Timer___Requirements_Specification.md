Status: Draft v0.1 — design in progress, not yet implemented
Date: 3 September 2026
Target: FrSky Ethos 26 · same hardware/software baseline as the Throw Trainer project
Working title: Poker Timer (name not final)

# DLG Poker Timer — Requirements Specification

## 1. Purpose

A field tool for practising the F3K "Poker" task (Task E). The pilot opens a
10-minute working-time window, quickly commits to a target time before each
launch, and the radio's own timer — with whatever warning/countdown beeps the
pilot already has configured on it — counts that target down in flight. At the
end of the window the tool has logged what was bet, what was achieved, and the
game's total score, so results can be reviewed over time.

The core design problem, same shape as Throw Trainer: **don't reinvent what
Ethos already does well.** Ethos timers already have configurable start values,
countdown beeps, and voice announcements. This tool's job is to *drive* an
existing timer with the pilot's bet, at the moment it matters, not to build a
second timekeeping system next to it.

## 2. Rules being implemented

This targets the **UK club variant** of Task E (BARCS, 2020 rule change),
not the full FAI rule:

- Working time: 10 minutes (configurable)
- Number of announced targets ("bets"): 3 (configurable)
- Unlimited relaunches per target — a missed target is not a lost turn, it's
  a locked number you keep trying to hit until you do, or the window ends
- Score per achieved target = the announced time itself, not the flight time
- Once a target is achieved, the next announced time may be lower, equal, or
  higher than the last
- No "call it in" for open-ended flights — a real time must always be
  announced (see §8 on why the "all-in" idea in the earlier conversation
  doesn't match the actual rule, and what's offered instead)

Defaults: **10 minutes, 3 bets.** Both are config fields, so the full 5-bet
FAI version is reachable by changing one setting rather than a different build.

## 3. Vocabulary

| Concept | UI label |
|---|---|
| The 10-minute session | Game |
| One announced target time | Bet |
| A target reached or exceeded | Hit |
| A target not reached, model landed | Bust |
| Re-launching to try the same locked target again | Retry |
| Sum of achieved target times | Score |

"All-in" is dropped as a mechanic — see §8. "Bust" replaces the poker-table
language for a missed target only because it's the shortest unambiguous word
for a log column; it carries no penalty beyond zero for that flight.

## 4. Interaction flow

1. Pilot opens the tool. Screen shows game setup: window length, bet count
   (both pulled from config, editable per-game via the same +MIN/+SEC bumpers
   used for betting — see below — so a pilot can shrink the window on a short
   evening without opening full config).
2. Pilot presses START. The 10-minute game clock begins. Bet 1 entry is live.
3. Pilot bumps the bet up using two controls:
   - **+SEC** — adds 10 seconds, rolling into +1 minute past 50s
   - **+MIN** — adds 1 minute directly
   Both are assignable to momentary switches (field use) and also live as
   soft keys / encoder targets on screen (bench use), same pattern as Throw
   Trainer's CHANGE/UNDO. A running mm:ss readout updates live as the pilot
   bumps it.
4. Pilot presses CONFIRM. This:
   - Locks the bet at its current value (no further bumping until it
     resolves)
   - Sets the target Ethos timer's **start value** to that duration
     (see §6 — this is the one Lua call that matters)
   - Arms the tool to watch for the next launch
5. Pilot launches. The launch edge (reusing the same MOM_LAUNCH detection
   already proven in Throw Trainer) triggers the target timer to reset and
   start counting down from the just-set bet value. The pilot hears whatever
   warning/countdown beeps they've already configured on that timer — the
   tool does not add its own audio, matching the "one source of truth for
   audio" principle from Throw Trainer §6. If this launch turns out to be a
   **false start** — the model never actually leaves Zoom mode before the
   launch switch is pressed again — the same edge naturally fires a second
   reset, restarting the countdown cleanly; see §6.6 for exactly how that's
   distinguished from an ordinary fresh attempt.
6. **Landing is detected directly, via the brake flight mode.** Landing mode
   (FM4 in the DLG template) is entered whenever the throttle/brake stick is
   pulled — which is also how a pilot brakes momentarily in flight by
   accident, so a single instantaneous entry into FM4 is not trustworthy on
   its own. The signal used here is **FM4 sustained continuously for a
   debounce period (default 0.5s, configurable)** — long enough that an
   accidental in-air brake tap doesn't register, short enough not to delay
   real landings noticeably. See §6.4 for how this is built without relying
   on any Lua "get current flight mode" call, which is a known-weak part of
   the API (§6.4).

   The moment that debounced landing signal fires, the tool reads the target
   timer's **current value** and decides the result from that single sample:
   - Value has reached zero (or gone negative, depending on the pilot's own
     timer configuration) → **Hit**. The bet's announced time is credited.
     CONFIRM unlocks and the pilot can bump the next bet.
   - Value is still above zero → **Bust**. The bet stays locked at its
     current value. The tool re-arms silently; the pilot just launches again
     (Retry) and the same Special-Function reset-on-launch (§6.2) restarts
     the countdown from the same locked duration. No button press needed to
     retry.

   This is deliberately a single event (the debounced landing signal), not
   two separate ones — there's no need to also watch for the timer crossing
   zero mid-flight, since the pilot already hears that happen through their
   own configured timer audio, and the tool only needs to know the outcome
   once the flight is over.
7. After the configured number of bets are resolved (hit or window expires),
   the game ends. Final score is shown and written to the log.
8. Pilot can end the game early; whatever's been scored so far is logged as a
   partial game, clearly marked.

## 5. Screens (draft)

| # | Screen | Purpose |
|---|---|---|
| S1 | Game setup | Window length, bet count, START |
| S2 | Live game | Bet readout (giant minutes/seconds), game time left, bet N of M, running score, +MIN/+SEC/CONFIRM |
| S3 | Game summary | Shown at game end: 3 bets, hit/bust/time for each, total score, "view game log" |
| S4 | Log | Past games newest-first, with date, score, and the current game compared against the 5-game average and the best game ever |
| S5 | Config | Window/bet defaults, target timer (dropdown), landing switch (dropdown), debounce, switch assignment, display mode |

S2 is the one screen a pilot actually interacts with mid-session, so it
carries the same "usable one-handed at the field" requirement Throw Trainer
placed on CHANGE/UNDO.

### 5.1 Default switch assignment

Rather than shipping with §7's switch-assignment fields unassigned, the
config defaults to a specific physical mapping so the tool is usable the
moment it's installed, not just once the pilot has visited config: the four
**Function Switches** — this radio's own name for them, confirmed by the
pilot, which is why they're printed `FS1`–`FS4` rather than the earlier
placeholder "Button 1–4" — in a row directly above the X14's touchscreen
(photo — see `x14_switch_mapping.png`):

| Control | Default | Long press |
|---|---|---|
| +MIN | **FS1** | Reset that field to 0 |
| +SEC | **FS2** | Reset that field to 0 |
| ALL IN | **FS3** | — (§8: marks the bet to claim whatever is left in the game window, computed at launch, not at the press) |
| CONFIRM | **FS4** | — |

All three remain reassignable in S5 the same way Throw Trainer's CHANGE/UNDO
are — this is a default, not a hardcoded binding. Long-press-to-reset applies
independently to whichever field +MIN/+SEC currently affects: on S1 that's
the window length; on S2 it's the current bet.

**Still open, narrower than before:** `FS1`–`FS4` is the pilot-facing name
printed on/associated with the radio, but whether that's *exactly* the
string Ethos's own source picker shows (some radios expose these with a
slightly different internal name than their silkscreen label) is worth a
quick confirm the same way `MOM_LAUNCH`/`ALT_CALL` were — open S5's source
picker and press one, see what lights up. Low-risk either way, since the
picker is driven by Ethos's own list regardless of what this document
assumes the name is.

### 5.2 Information hierarchy

An early mockup pass buried the two numbers a pilot actually needs to read
at a glance — game time remaining, and the minutes/seconds they're currently
adjusting — in small top-corner text, while giving equal or greater visual
weight to secondary status lines. Revised principle: **font size follows
how urgently the number needs to be read, not how it's categorized.**

- Giant (biggest element on the screen): the bet's minutes and seconds on
  S2, each in its own boxed segment, labelled with the switch that adjusts
  it (`FS1` / `FS2`) directly underneath — this is what a pilot
  needs to confirm correct at a glance before confirming a bet.
- Large: game time remaining on S2; total score on S3; the current-game
  score on S4.
- Small, secondary: bet-N-of-M, running score-so-far, dates, switch names —
  present, but not competing with the numbers above for attention.

### 5.3 Day mode default

The screen defaults to **day mode** — light background, dark text, high-
contrast semantic colours — for legibility in direct sunlight at the flying
field, rather than the dark theme used elsewhere in this ecosystem's tools
(Throw Trainer, Poker Probe). **Night mode** (the dark palette) remains
available as a display setting in S5 for anyone flying at dusk or indoors,
but day is the shipped default. Both palettes use the same layout — only
colour values change, not information hierarchy or type scale.

### 5.4 Full-screen only — no widget

Unlike Throw Trainer, this tool is registered **only** as a
`system.registerSystemTool` — there is no `registerWidget` call and no
compact-cell fallback. There's nothing to shrink into a model-screen tile:
betting mid-session needs the whole game state on screen at once (bet
readout, score, game clock, soft keys), and a quarter-screen widget cell
can't hold that legibly, which is exactly the failure mode Throw Trainer's
own tier-C widget cell exists to avoid falling into. So instead of building
a compact tier for a use case that doesn't apply here, the tool simply isn't
a widget at all. `draw.lua` for this project needs no tier system, no
`metrics()` bucketing, and no bar-count-from-width logic — one layout,
sized off `lcd.getWindowSize()` at whatever the System-menu tool cell
actually measures on each radio (per the Throw Trainer project's own
measurements, that's roughly 790×406 on the X20RS and a comparable full-page
size on the X14).

**This decision was revisited once, deliberately, and kept.** Implementing
this tool surfaced a real lifecycle difference worth recording, confirmed
via the Ethos developer community rather than assumed: a **widget's**
`wakeup()` runs continuously in the background once placed on any screen,
independent of which screen is currently showing — this is exactly why
Throw Trainer keeps logging launches while the pilot is looking at
something else entirely. A **System Tool's** `wakeup()`, by contrast, stops
the moment the pilot navigates away from it; System Tools don't share that
background-execution property, and experienced Ethos developers have hit
the same limitation and worked around it by pairing a System Tool with
something that runs independently, because the System Tool alone doesn't
provide it.

For a tool whose whole job is catching a launch edge whenever it happens,
that sounds disqualifying at first. It isn't, for this specific tool,
because of how a game is actually played: one continuous stretch of active
engagement — bet, launch, wait for the outcome, bet again — with no
realistic moment where the pilot steps away mid-game and expects launch
detection to keep working unattended, unlike Throw Trainer's whole-session,
do-other-things-in-between usage pattern. The System Tool's lifecycle
limitation is therefore an **accepted, understood tradeoff** rather than an
oversight: stepping away mid-game genuinely does pause detection until the
pilot returns to this screen, and that cost was weighed against the
alternative (adding a widget purely for background continuity, with a
separate compact readout and no full interaction) and judged not worth the
added surface for how this tool is actually used.

### 5.5 Controls — X14 and X20RS specifically

Two radios, two different physical realities, one shared control scheme:

- **Physical controls always exist and are always primary.** +MIN, +SEC,
  and CONFIRM are each assignable to a momentary switch (same pattern as
  Throw Trainer's CHANGE/UNDO), plus the on-screen soft-key row is reachable
  by rotary + encoder press on both radios. This is the path that has to
  work one-handed at the flight line, and it's identical on both radios —
  nothing about it depends on a touchscreen existing.
- **Touch is additive, X20RS only.** The X20RS's touchscreen gets on-screen
  up/down (and left/right, where relevant — e.g. bumping +MIN/+SEC by touch
  alongside the assigned switches) as a convenience for bench use, review of
  the log, and config. The **X14 has no touchscreen at all**, so no touch
  targets are drawn there — not hidden-but-present, actually absent, so
  there's nothing on screen implying a tap will do anything.
- Which radio is which is decided once, at startup, from `system.getVersion()`
  (board name), not assumed from screen size — see §11 for the specific risk
  in that heuristic and the probe test that checks it.

This mirrors Throw Trainer's own hardware findings almost exactly: that
project measured real cell geometry on both an X14 and an X20RS before
committing to layout thresholds (§17–18a), rather than assuming one radio's
numbers would transfer to the other. Same discipline applies here, just with
touch capability as the axis instead of cell size.

## 6. Ethos timer integration — the question that matters most

**Short answer: yes, this is possible, and it's a small, well-documented API
surface — but it needs the same kind of hardware verification pass Throw
Trainer did for `OPTION_SENSOR_MAX`, because this exact corner of the Lua API
has changed across Ethos versions before.**

### 6.1 What's confirmed from the published LuaDoc

Timers are reached through `model.getTimer()`, not `system.getSource()`.
`system.getSource({category = CATEGORY_TIMER, ...})` gives you a read-only-ish
view (good for *displaying* a timer, which this tool doesn't even need to do,
since the pilot is already looking at their own Ethos timer readout/widget).
To *change* a timer's settings you need the `Timer` object:

```lua
local t = model.getTimer(2)        -- or model.getTimer("Timer3") by name — index 2 is Timer3, 0-based
t:start(betSeconds)                -- get/set the timer's start (duration) value
t:reset()                          -- reload the timer from its start value
```

Documented `Timer` methods relevant here (FrSky Ethos LuaDoc, `classTimer.html`):

| Method | Purpose | Since |
|---|---|---|
| `start()` | get/set the timer's start value | — |
| `value()` / `stringValue()` | get/set current value / read as HH:MM:SS | — |
| `reset()` | reset the timer to its start value | — |
| `audioActions()` | get/set the table of warning beeps / voice callouts (`COUNTDOWN_BEEP`, `PLAY_FILE`, `PLAY_VALUE`, each with `start`/`step`) | 1.5.0 |
| `countingSource()` | get/set what drives the timer's counting | 26.1.0 |
| `direction()` | count up (1) or down (-1) | — |

### 6.2 What this tool actually needs to call

Because the pilot wants to keep using the countdown beeps **already set up on
that timer** (their existing 30s-warning / 15s-countdown), this tool should
touch only `start()`. It should not need `audioActions()` at all — that's the
pilot's own one-time timer configuration, done the normal way in
`SYSTEM > TIMERS`, exactly like the "brake-aware trim" principle elsewhere in
this ecosystem: configure it once, let the transparent mechanism do its job.

That leaves two ways to get the reset-on-launch behaviour, and — updated
after §6.3a's AUTOCFG results — the balance between them has flipped:

- **Recommended — Lua drives the reset, zero manual radio setup at all.**
  The script watches the same MOM_LAUNCH rising edge Throw Trainer already
  validated on hardware (`system.getSource({category = CATEGORY_LOGIC_SWITCH,
  name = "MOM_LAUNCH"})`, edge-detected in `wakeup()`) and calls `t:reset()`
  itself. This used to be the fallback, kept smaller-footprint-first because
  it meant touching the Timer object at all. That tradeoff no longer applies:
  §6.3a confirms the script already has to hold and configure that same
  Timer object at startup (`direction(-1)`, `countingSource(nil)`) to
  eliminate the Countdown-mode/Start-condition setup step, so having it also
  call `reset()` on launch is a marginal addition, not new complexity — and
  it removes the pilot's last manual setup step (the Special Function) on
  top of the two already removed.
- **Alternative — no Lua for the reset itself.** The pilot adds one Special
  Function, once: `Reset Timer:<PokerTimer> on <MOM_LAUNCH>`. Same pattern
  as the DLG template's own SF11 (`Reset Telemetry:Altitude on MOM_LAUNCH`).
  Still documented as a config toggle for anyone who'd rather see the reset
  happen natively and inspect it in the Special Functions list, but with
  §6.3a's result this is no longer needed to keep the script simple — it's
  purely a preference now, not a risk tradeoff.

### 6.3 What's *not* yet confirmed, and needs a bench check before this is built

Flagged as open items, same as Throw Trainer's §19/§18a treatment of
`OPTION_SENSOR_MAX`:

1. **`model.getTimer()` by numeric index vs by name.** A historical Ethos
   issue (alpha-era) reported numeric-index lookups returning `nil` while
   name-based lookups worked. Almost certainly fixed by 26.1.1, but this is
   exactly the kind of thing that silently breaks a script, so it should be
   probed the same way `system.getSource` was probed for the DLG logic
   switches in Throw Trainer — before writing the rest of the tool around it.
2. **`countdownStart()` / `countdownStep()` / `audioMode()` were removed in
   1.5.0**, replaced by the `audioActions()` table. This tool doesn't plan to
   touch beep configuration at all (see 6.2), so this shouldn't matter — but
   it's a concrete example of this API area moving under developers' feet
   across versions, which is the reason for treating even `start()`/`reset()`
   as unverified until checked on 26.1.1 specifically, not just "documented
   therefore safe."
3. **Does `reset()` also restart a *stopped* timer, or only reload its
   value?** A timer's running state is governed by its own Start condition
   (set once by the pilot in `SYSTEM > TIMERS`, independent of `start()`/
   `reset()`). **Confirmed on the bench (§6.3a): yes, this is a real
   requirement, not a hypothetical.** With Start condition left at its
   stock default, `reset()` reloaded the correct value every time but the
   timer never counted down. Setting Start condition to Always fixed it
   completely. This is now a required one-time pilot setup step (§7),
   not a Lua workaround.
4. **Timer index collision with the DLG-for-Ethos template.** The template
   already uses **Timer1** as the flight timer, reset/started by
   `SW_Launch` (Setup Guide §2.5). This tool must target a *different* timer
   — Timer2 or Timer3 — selected in config, not hardcoded, so it never fights
   the template for the same slot.

None of these are blockers; they're the same shape of "probe it on the
simulator/hardware before locking the design" work Throw Trainer already did
successfully for its own trickiest dependency (§17–18a). This section will be
updated with confirmed results the same way, before implementation starts.

### 6.3a Confirmed on the Ethos 26.1.1 simulator (X14)

First two Poker Probe runs, X14 board, `ethos 26.1.1 sim:true`:

- **Item 1 confirmed still present.** `model.getTimer(i)` for `i = 0..8`
  resolved only indices 0 and 1 — index 2, which should be Timer3, came
  back `nil`. The probe's name-based fallback (`model.getTimer("Timer3")`)
  resolved fine, reading `start=0`. **Decision: the real tool resolves its
  target timer by name only** (`model.getTimer("Timer3")`), never by
  numeric index. §7's config default is updated accordingly — the
  pilot-facing "target timer" setting is a name string, not an index.
- **`CATEGORY_FLIGHT_MODE` sweep returned nothing** — members 0–8 all
  `nil`. Confirms §6.4's premise directly: there is no working route to
  flight-mode state via `system.getSource`, which is why the design
  commits to a named Logic Switch instead of retrying this category.
- **Touch-capable heuristic worked as intended on the X14** —
  `board=X14 -> touch UI hidden`, matching §5.5.
- **`t:start(37)` writes correctly** — `before=0 target=37 after=37`. The
  setter itself is confirmed working.
- **`t:reset()` reloads `value()` correctly once Timer3 is in Countdown
  mode — CONFIRMED, PASS.** Second bench run, after manually setting
  Timer3's mode to Countdown in `SYSTEM > TIMERS`: `Timer3 resolved` now
  reports `dir=-1` (countdown) and a non-nil `countingSource`. Repeating
  the write test gives `Timer3 set start()` → `before=0 target=37
  after=37`, and — the row that failed on the first run — `Timer3 reset()
  -> value()` → **`value after reset=37 (want ~37)` — PASS.**

  This confirms hypothesis one from the first run and closes item 3's
  value-reload half: the earlier `FAIL` was Timer3 being in
  count-up/stopwatch mode by default in the sim's stock model, not a
  problem with `start()`/`reset()` themselves.

- **`reset()` does *not* resume counting on its own — the timer's Start
  condition genuinely gates it, independent of the value being correct —
  CONFIRMED both ways.** With Countdown mode set but Start condition left
  at its stock default, three separate RUN passes (targets 37, 74, 111)
  all showed the identical pattern: `Timer3 reset() -> value()` passed
  every time (`74→74`, `74→111`, `111→111`), but the automatic
  post-reset watch (`Timer3 counting after reset`, sampling `value()`
  ~3s apart) showed `delta=0 -> NOT counting` every time, reproducibly. A
  side check confirmed this wasn't a simulator-wide real-time limitation —
  Ethos's own built-in Timer widget, no script involved, was checked
  separately.

  With Timer3's **Start condition set to Always**, the same test then
  passed cleanly: `start=111 now=109 delta=2 -> counting down`.

  **Decision, closing item 3 and the whole timer-integration question —
  since superseded by §6.3b:** at this point in testing, the tool's setup
  required two manual radio settings on the target timer, in addition to
  the `Reset Timer:X on MOM_LAUNCH` Special Function:
  1. Mode = **Countdown**
  2. Start condition = **Always**

  With both set, `t:start(betSeconds)` followed by `t:reset()` — called
  once, when CONFIRM is pressed — was a fully bench-confirmed way to load a
  bet duration into a real Ethos timer and have it actually count down.
  §6.3b below removes the need for either manual step.

### 6.3b Confirmed on the X20RS simulator — manual setup eliminated entirely

Repeating the same bench pass on an X20RS board, plus one new test
(`AUTOCFG`, added after this question came up directly): can the script set
Countdown mode and "Start condition = Always" **itself**, rather than
asking the pilot to do it once in `SYSTEM > TIMERS`?

- **`wakeup()` rate: ~40.3/s** (121 calls in 3s) — same order of magnitude
  as the X14's ~52.3/s. The Lua-timed landing-debounce design (§6.4) holds
  up across both boards, not just the one it was first measured on.
- **`t:direction(-1)` — CONFIRMED writable.** `wrote=true readback=-1`.
  Setting Countdown mode no longer requires opening `SYSTEM > TIMERS` at
  all — the script can do it directly.
- **`t:countingSource(nil)` — CONFIRMED writable, and CONFIRMED to
  actually enable counting.** `wrote=true`, and immediately after, with no
  manual radio setting touched anywhere: `Timer3 counting after reset` —
  `start=111 now=109 delta=2 -> counting down`. `countingSource(nil)`
  behaves as "no gating condition" (i.e. Always) exactly as guessed in
  §6.3a's original hypothesis — this was genuinely untested until this run,
  not assumed.

**Decision, superseding §6.3a's setup requirement entirely:** the pilot
setup for Timer3 is now **zero manual steps**. The tool calls
`t:direction(-1)` and `t:countingSource(nil)` once at startup (idempotent —
safe to call every time, not just the first), and combined with §6.2's
updated recommendation (Lua also drives `reset()` on the `MOM_LAUNCH` edge,
no Special Function needed either), the entire timer-integration mechanism
is now fully self-contained. A pilot installing this tool never has to
visit `SYSTEM > TIMERS` or `SPECIAL FUNCTIONS` for it to work.

One thing worth one more confirmation pass on, not because the result is in
doubt but because it's a new code path tested only once: repeating the
AUTOCFG test on the X14 as well (it was only run manually-configured there,
before AUTOCFG existed), to rule out any board-specific quirk in how
`countingSource(nil)` behaves.

### 6.3c Real hardware correction (v1.0 field report) — §6.3b's "zero manual
steps" claim does not hold

Confirmed by the pilot on an actual X14 radio, not the simulator: with
AUTOCFG's `direction(-1)` + `countingSource(nil)` as the only Timer3 setup
and no manual step taken, the app "sets correctly" (the target value and
countdown direction display right) but **the countdown never actually
starts** -- it sits at the target and does not tick down. Manually opening
`SYSTEM > TIMERS` and setting Timer3's Start condition to **Always** (the
exact §6.3a manual step §6.3b's decision was written to eliminate)
immediately fixed it, with no other change -- "sets correctly and runs
right" once that one setting is in place.

This means §6.3b's simulator result does not transfer to real hardware --
`countingSource(nil)` is confirmed writable and confirmed to read back
correctly on both platforms, but only confirmed to actually gate counting
on the simulator. Whatever the simulator does differently to make a nil
counting-source behave as "always count" is not what happens on this real
X14. Rather than remove the AUTOCFG call (it does not appear to be
harmful, and is presumably still setting direction correctly), the fix
shipped is to stop presenting the manual step as optional or superseded:
DLG Poker's own CONFIG screen (Timer panel) now states it as a **required
one-time step**, separately from the general "beeps and thresholds live in
SYSTEM > TIMERS" note that was already there and had been read as merely
informational.

**Still open:** whether this is genuinely an X14-specific firmware gap
(matching §6.3b's own flagged-but-never-completed open item to repeat
AUTOCFG on the X14) or would also reproduce on a real X20RS -- the
simulator/hardware split observed so far is X20RS-simulator-worked,
X14-hardware-didn't, so the X14-real-hardware and X20RS-real-hardware cells
of that matrix are both still unconfirmed individually.

### 6.4 Detecting a stable landing without a flaky API

There is an open, unresolved Ethos feature request for a straightforward
"give me the current flight mode" Lua call — as of the most recent public
discussion it's described by FrSky's own team as "under-described," and a
separate request just to get the *name* of the active flight mode is still
open too. That's not a foundation to build a debounced landing signal on.

**The template already has the base signal built**, though, so this
doesn't need a flight-mode read at all. The Settings Reference's Logical
Switches sheet defines `LSW16`:

```
LANDING_MODE = BRAKE_PULLED and not LND_BLOCKED
```

which is what actually drives FM4 (the "Controls and FMs" sheet's "Throttle
stick" description for FM4 is the plain-language gloss of this same
switch). `LANDING_MODE` has **no duration debounce of its own** — it goes
true the instant the brake stick crosses the deadband, any time
`LND_BLOCKED` is already false, which per `LSW15` it will be for the rest
of a normal flight after the pilot first releases the brake post-Zoom. So
a mid-air brake tap during a thermal really does trip it instantly — that's
exactly the failure mode the debounce exists to filter out.

**Decision: debounce it in Lua, reading `LANDING_MODE` directly — no new
radio-side Logic Switch required.** The original draft here had the pilot
build a second switch (`LANDED_STABLE`) purely to add a Duration on top of
`LANDING_MODE`, mirroring the `MOM_LAUNCH`/`ALT_CALL` pattern. That's no
longer necessary: Poker Probe's own `L:`/`A:`/`B:` dwell counters already
prove the mechanism works — reading a raw switch every `wakeup()` and
timing how long it's stayed continuously true, entirely in Lua, with no
extra switch. There's no reason the real tool can't do the same thing with
`LANDING_MODE`, avoiding a manual radio-side setup step the pilot would
rather skip.

```lua
local landing = system.getSource({category = CATEGORY_LOGIC_SWITCH, name = "LANDING_MODE"})
-- in wakeup(): if landing:value() > 0, accumulate dwell time (os.time());
-- once dwell >= configured debounce, treat as a stable landing.
-- Reset the accumulator the instant landing:value() <= 0.
```

**The one real tradeoff, stated plainly:** Ethos's Lua has no confirmed
sub-second wall clock. `os.time()` is whole seconds only; `os.clock()` is
CPU time, already documented elsewhere in this project (Throw Trainer §23)
as unreliable for real-time measurement. A still-open Ethos community
request asks for exactly a sub-second internal timer and is told those are
the only two options, neither adequate below roughly a second. So a
Lua-only debounce timed against `os.time()` can't hit a crisp 0.5000s the
way the native Logic Switch engine can (which is proven to support it —
`LSW24`'s 0.1s, `LSW17`'s 2s) — in practice it behaves closer to "held for
a full additional second past the boundary" than an exact half-second cutoff.

Whether that's good enough depends on what the debounce actually needs to
reject: a *brief* accidental brake tap, not a precisely-timed one. Whole-
second resolution is very likely sufficient for that job. Poker Probe v0.7
adds a `wakeup() rate` calibration (§6.4a) to get a real number instead of
assuming — if `wakeup()` fires often enough per second, counting calls
rather than whole seconds gets meaningfully closer to a true 0.5s without
needing any new radio-side switch.

**Config option, not a hard choice:** §7 exposes both. Landing detection
defaults to **Lua-timed** (this section, no extra setup), with **native
Logic Switch** (the original `LANDED_STABLE` design, still documented
below for anyone who wants exact sub-second precision and doesn't mind the
one-time radio setup) available as an alternative:

```
LSW: LANDED_STABLE   (optional, only if "native" mode is selected)
Condition: LANDING_MODE
Duration: 0.5s
```

This is the same "reference another named logic switch, add a duration"
pattern the template already uses elsewhere — `LSW17 (BRAKE_ALERT)` is
`BRAKE_PULLED and not ZOOM_MODE and LND_BLOCKED (2s)` — so if a pilot does
want this path, it's proven, not a guess.

### 6.4a Making the debounce duration configurable — CONFIRMED on the X14 simulator

The pilot-facing debounce is a config field (§7), default **0.5s**. With
Lua-timed detection now the default (§6.4), this field is directly
authoritative for that path — no extra API needed, it's just the threshold
the script's own dwell counter compares against. It only becomes a
documentation-only, manually-mirrored number in the **native** mode, where
it needs to match whatever's typed into `LANDED_STABLE`'s own Duration
field on the radio.

**`model.get/setLogicalSwitch` do not exist on Ethos — CONFIRMED, settled,
not just likely.** Poker Probe's existence check came back
`get=false set=false`. So this is no longer a contingent "if confirmed
present" — it's decided: **native mode's debounce field can never be made
authoritative.** Anyone who chooses native mode over the Lua-timed default
permanently keeps two numbers in sync by hand (this tool's config field,
and `LANDED_STABLE`'s own Duration field on the radio). Worth stating
plainly in that mode's setup instructions rather than leaving it as an
open question.

**`wakeup()` rate — CONFIRMED, much better than the worst case.** 157
calls in 3 seconds on the X14 simulator, **~52 calls/sec**. At that rate,
counting `wakeup()` calls instead of relying on whole-second `os.time()`
gets the Lua-timed debounce to roughly **19ms resolution** — nowhere near
the "rounds up to a full second" worst case §6.4 flagged as the tradeoff
for going Lua-timed. **Decision:** the Lua-timed implementation counts
consecutive `wakeup()` calls while `LANDING_MODE` reads active, converting
to a time threshold via this measured rate, rather than falling back to
`os.time()`'s whole-second granularity. `os.time()` is kept only as a
coarse sanity clamp (in case the call rate varies under load — e.g. a
form is open, or the radio is busy elsewhere), not as the primary
timing signal.

One thing this doesn't yet tell us: whether ~52/s holds steady across
different conditions (screen off vs. on, other apps running, real hardware
vs. simulator, X20RS vs. X14) or whether it's a best-case number that dips
under load. The implementation should treat the measured rate as
recalibrated periodically rather than fixed once at startup, and this is
worth re-checking on a real X20RS alongside the other still-open X20RS
items (§11).

Also in this same probe run, read-only and safe to call automatically on
open:

- **`MOM_LAUNCH` and `LANDING_MODE` by name — both CONFIRMED resolved.** This
  *separate, standalone* script (per this project's own "own script, not
  part of Throw Trainer" decision) can resolve the template's existing
  switches just as reliably as Throw Trainer already proved for itself —
  that result doesn't automatically transfer between two independent
  scripts without being checked again, and now it has been.
- **`LANDED_STABLE` by name** — reads `nil`/FAIL as expected, since it
  hasn't been built and, with Lua-timed now the default (§6.4), doesn't
  need to be. **The `L:` live readout itself is configurable, not
  hardcoded:** it defaults to `LANDING_MODE` (the template's existing
  `LSW16`, confirmed present) so it's immediately useful with zero setup —
  confirmed live in this same run, showing `L: LANDING_MODE active 4s`
  while the brake stick was held — and can be repointed at `LANDED_STABLE`
  via a SETUP source-picker field for anyone testing native mode
  specifically.

### 6.5 Detecting a misconfigured (non-momentary) control switch

The X14's four Function Switches (FS1–FS4, §5.1) default to a **latching**
mode — `4-Pos`, `4-Pos with OFF`, `2×2-Pos`, or `4×2-Pos` in the radio's own
`Edit model > Function switches` picker — where pressing one holds it
electrically "on" until a different one is pressed, rather than springing
back. This tool's default control mapping (§5.1) needs them in **Momentary**
mode instead; a pilot who has not changed that default will have every
control latch on the first press.

**No API confirms this directly.** Searched for a Lua equivalent of
`model.getLogicalSwitch()` scoped to the Function Switches group — the
closest candidate is that same function, already confirmed absent from
Ethos entirely (§6.4a). There is no dedicated query for "what mode is this
switch group in."

**So this is inferred behaviourally, using a mechanism already proven
working in this project.** Poker Probe's `L:`/`A:`/`B:` dwell counters have
already demonstrated, live, on hardware, exactly the primitive this needs —
timing how long a source reads continuously active against `os.time()`
(e.g. `L: LANDING_MODE active 28s` from an earlier bench run). Detecting a
stuck switch is that same mechanism pointed at a different source.

**Why this is a functional bug, not just a rough edge.** A latched switch
does not cause runaway repeated bumps — +MIN/+SEC trigger on the rising
edge, so one tap still only fires once even if the switch never
electrically releases. The real failure is the **hold-to-reset** behaviour
(§5.1): with no way to distinguish "still physically held" from
"electrically latched and will never release," the script will eventually
cross the long-press threshold on an ordinary single tap and fire the
reset-to-zero action the pilot never asked for, silently wiping out the
value they just set.

**Design:**
- Watch all four currently-assigned control roles (+MIN, +SEC, ALL IN,
  CONFIRM) — not hardcoded to the Function Switches specifically, so a
  pilot who mistakenly assigns an ordinary toggle instead of a momentary
  switch is caught by the same check.
- Threshold: **2.0s default, configurable** in S5, same pattern as the
  landing debounce (§6.4a).
- Fires **once per stuck event**, not every `wakeup()` while the condition
  persists — a banner, not a spam of repeated warnings.
- Wording stays honest about what the tool actually knows — it can observe
  that a switch is behaving like it never releases, not that Function
  Switches is specifically in a given mode — while still pointing at the
  most likely real-world cause and fix:

  > *"FS2 has read ON continuously for 2+ seconds — that usually means
  > Function Switches is set to a latching mode instead of Momentary. Go to
  > Edit model → Function switches → select Momentary."*

- Since there is no known way to change the Function Switches group mode
  from Lua either, the tool cannot fix this itself — the pilot has to leave
  the tool, fix it in `Edit model`, and come back. The warning should
  therefore be impossible to miss but not destructive: it should not lose
  or corrupt in-progress game state while it is showing.

### 6.6 Defining a launch: false starts vs confirmed launches

Raised directly: the launch switch can be pressed, released into Zoom mode
*while the model is still on the ground* (regripping, aborting a bad swing),
then pressed again — a false start, not a real throw. The template already
distinguishes this internally without Lua needing to read a flight mode
directly, using two logic switches already confirmed readable by name
(`MOM_LAUNCH` for the first; `ZOOM_MODE` untested but structurally
identical to `MOM_LAUNCH`/`ALT_CALL`, both already confirmed in §6.4a):

```
LSW1  MOM_LAUNCH = VAR:SW_Launch = 100          -- launch switch held
LSW18 ZOOM_MODE   = Sticky(MOM_LAUNCH, ZOOM_RESET)  -- latches true the
                                                      -- instant the switch
                                                      -- is first pressed;
                                                      -- only releases on
                                                      -- the elevator-push
                                                      -- exit gesture
```

That `Sticky` behaviour is exactly what makes a false start detectable: a
second `MOM_LAUNCH` rising edge arriving *while `ZOOM_MODE` is still latched
true from the previous press* means the model never actually left Zoom —
the exit gesture never fired. A **confirmed launch**, by contrast, is
`ZOOM_MODE` falling from true to false with no intervening re-press —
i.e. the elevator-push exit gesture actually happened, meaning the model
progressed into whichever of Cruise / Speed / Thermal1 / Thermal2 (or, rare
edge case, straight into Landing if brakes happen to be pulled at that
exact instant) the flight-mode switches select. Terminology, so the rest of
this section can refer to these precisely:

| Term | Definition |
|---|---|
| Launch attempt | Any `MOM_LAUNCH` rising edge |
| False start | A `MOM_LAUNCH` rising edge while `ZOOM_MODE` is still latched true from the previous attempt |
| Confirmed launch | `ZOOM_MODE` falling (true → false) with no intervening re-press |

**The existing reset mechanism already does the right thing here, without
needing to change it.** §6.2 already resets the target timer on *every*
`MOM_LAUNCH` rising edge, unconditionally — which means a false start's
re-press already produces a fresh reset, restarting the countdown from the
full bet duration exactly as wanted. Nothing about the core reset trigger
needs to change; a false start and a genuine second attempt are handled
identically by the same edge-triggered `t:reset()` call, which is the
correct behaviour either way.

**Scoring is separately, and independently, immune to false starts.**
Hit/Bust (§4) is decided by sampling the timer's value at the
`LANDED_STABLE`-equivalent debounced landing signal — a false start never
reaches that signal at all, since the model never leaves the hand and the
brakes are never touched mid-regrip. So a false start can never be
miscounted as a wasted attempt in `bets.csv`'s `attempts` field; there is
nothing to undo, because nothing was ever recorded.

**What is actually new, then, is a small piece of pilot-facing feedback,
not a scoring or timing change:** when a false start is specifically
detected (as opposed to an ordinary fresh launch attempt), S2 briefly shows
a status line — *"false start — timer restarted"* — purely as
reassurance that the reset the pilot just heard/felt was intentional
behaviour, not a glitch. This requires reading `ZOOM_MODE` in addition to
`MOM_LAUNCH`, which is why it is called out as its own open item below
rather than assumed to already work.

## 7. Configuration

| Setting | Default | Notes |
|---|---|---|
| Window length | 10:00 | per-game override available on S1 |
| Bets per game | 3 | per-game override available on S1 |
| Target timer | **Timer3**, shown as a dropdown pre-filled with Timer3 | must not be Timer1 — the DLG template already uses that as its flight timer (Setup Guide §2.5); Timer2 left free for other uses; **resolved by name, not index** (§6.3a). Config note reminds the pilot to set countdown/alert beeps for this timer in `SYSTEM > TIMERS`, since the tool deliberately never touches `audioActions()` (§6.2) |
| Timer mode | **one manual step required: SYSTEM > TIMERS > Start condition = Always** | AUTOCFG (`t:direction(-1)` + `t:countingSource(nil)`) was believed per §6.3b to supersede this entirely, confirmed only on the X20RS simulator; a real X14 field report (§6.3c) showed the countdown never starts without this manual step regardless of AUTOCFG, so the "zero manual steps" claim did not hold on real hardware and the step is required again until/unless further hardware testing shows otherwise |
| +MIN switch | **FS1** (§5.1) | reassignable; long-press resets the current field to 0 |
| +SEC switch | **FS2** (§5.1) | reassignable; long-press resets the current field to 0, +10s per short press |
| ALL IN switch | **FS3** (§5.1/§8) | reassignable; claims whatever is left in the game window as the bet, computed at launch |
| CONFIRM switch | **FS4** (§5.1) | reassignable |
| Landing detection mode | **Lua-timed** (default) / Native Logic Switch | Lua-timed reads `LANDING_MODE` directly and debounces in the script — no radio-side setup. Native mode requires the pilot to build `LANDED_STABLE` once (§6.4) but gets exact sub-second precision from Ethos's own Duration engine |
| Landing switch | dropdown, pre-filled with **`LANDING_MODE`** (Lua-timed) or `LANDED_STABLE` (native) | which name the tool resolves depends on the mode above; tool warns if not found, same as Throw Trainer's missing-ALT_CALL fallback warning. On-screen this row carries no explanatory note — the "Ignore quick taps" row directly below it already explains the behaviour in plain language, so repeating "Lua-timed debounce" here would be redundant jargon |
| Ignore quick taps | **0.5s**, configurable | pilot-facing rename of the landing debounce, since "debounce" was not self-explanatory — this is what stops an accidental brake tap mid-flight from being read as a landing. In Lua-timed mode this value is directly authoritative — the script's own threshold, no duplication. In native mode it's documentation only: it must match whatever's typed into `LANDED_STABLE`'s own Duration field on the radio, unless §6.4a's `model.get/setLogicalSwitch` check comes back positive, in which case it could become authoritative there too |
| Stuck switch warning | **2.0s**, configurable | §6.5 — if any of the four assigned controls reads continuously active longer than this, the tool warns that the switch may be latching (Function Switches not set to Momentary) rather than momentary, and points at the fix |
| Reset-on-launch method | **Lua-driven** (recommended, §6.2) | Special Function alternative still available as a config toggle, but no longer needed to keep the script simple — see §6.3b |
| Display | **Day mode** (default) / Night mode | §5.3 — day is light-background/high-contrast for sunlight legibility; night is the dark palette used elsewhere in this ecosystem's tools |

## 8. Why "all-in" isn't in this design — and what replaced it

Worth stating plainly, since it came up earlier in planning: the actual Task E
rule explicitly forbids announcing an open-ended "rest of the window" time —
a real number of minutes/seconds must always be called. So there's no rules
basis for an all-in mechanic, and building one would train a habit that
doesn't transfer to a real contest.

What the earlier idea was reaching for — a fast way to bet big near the end
of the window — is now a real, decided feature: **FS3, ALL IN.** A short
press marks the bet as "claim whatever's left," and the game computes a
real, specific number of seconds at the moment of launch — a genuine target,
not an open-ended call, so it satisfies the same rule an ordinary bumped-up
bet would.

**Why the number is computed at launch, not at the FS3 press.** The
original idea considered a hold-gesture on CONFIRM that would snapshot
"time remaining" and lock it in immediately. The problem, raised directly:
if there's any delay between that press and the actual throw — walking out,
lining up — the window keeps draining during that gap, so a target
calculated at press-time is already stale, and worse than an ordinary bet
would have been. The fix isn't a better gesture, it's deferring the
calculation entirely: FS3 only *marks* the bet as a claim; the actual
`target_s` is computed from `(game deadline − now)`, rounded down to the
nearest 10s, at the exact moment the `MOM_LAUNCH` edge fires — the same
signal that already resets the target timer (§6.2). That edge is
effectively instantaneous relative to the press, so the staleness problem
disappears by construction rather than by estimation.

This also simplifies the interaction rather than complicating it: FS3 was
sitting unused (§5.1), so this becomes one dedicated button with one plain
action — no hold-vs-short-press distinction on FS4 to remember at the field.
S2 shows this state as a large, deliberately eye-catching **blinking
"ALL IN"** in card red — going all in is the exciting move at a poker
table, and the screen should feel like it, not like a quiet status line —
with the current live-estimate number shown smaller underneath so the
pilot can see roughly what they are about to lock in, without it being
treated as final until the throw actually happens.

## 9. Data model (draft)

Two files, following the Throw Trainer convention of one global CSV filtered
by an identity key — here keyed on radio/date rather than per-glider, since
poker practice isn't airframe-specific the way launch height is.

`games.csv`
| Field | Description |
|---|---|
| ts | Game start timestamp |
| window_s | Configured window length |
| bet_count | Configured number of bets |
| score_s | Total achieved seconds |
| complete | Whether all bets resolved or the game was ended early |

`bets.csv`
| Field | Description |
|---|---|
| game_ts | Foreign key to games.csv |
| idx | Bet number within the game (1..N) |
| target_s | Announced/locked time |
| result | hit / bust / unresolved |
| attempts | Number of launches against this locked target |
| scored_s | target_s if hit, else 0 |

The log screen (S4) reads `games.csv` **newest-first** for the list with
dates and totals — reversed from an earlier draft, which had it
oldest-first; most-recent-first is what a pilot actually wants to scan at
the field. Selecting a game reads its rows from `bets.csv` for the
S3-style breakdown.

S4 also shows the current (most recent) game's score compared against two
computed figures, both derived from `games.csv` at read time rather than
stored separately, so they're never stale:
- **avg (last 5)** — mean `score_s` of the 5 most recent *complete* games
  before the current one
- **best ever** — max `score_s` across all complete games

Each is shown as a signed delta (`-17s`, `+40s`) against the current game's
score, coloured by sign the same way Throw Trainer colours its before/after
delta — this is a direct visual answer to "am I improving," which is the
whole point of practising with this tool.

## 10. Theme

Poker suits (♠ ♥ ♦ ♣) as simple drawn or Unicode glyphs for bet-slot markers,
hit/bust indicators, and the log page — these are generic symbols, not
licensed artwork, so no IP concern (per the same standard this project
already applies to Throw Trainer's icon). No card-back art, casino branding,
or anything trademarked.

## 11. Open items

1. ~~Bench-verify `model.getTimer()`, `Timer:start()`, `Timer:reset()` on
   Ethos 26.1.1 specifically.~~ **Done — confirmed on both X14 (§6.3a) and
   X20RS (§6.3b) simulators.** Name-based lookup works, index-based doesn't
   past index 1 on either board; `start()`/`reset()`/`direction()`/
   `countingSource()` all confirmed writable; and on the X20RS, `AUTOCFG`
   proved the entire manual setup (Countdown mode + Start condition Always)
   can be eliminated and done by the script instead. Remaining: repeat
   AUTOCFG specifically on the X14 too (§6.3b), to rule out a board-specific
   quirk, and ideally confirm both boards on real hardware, not just the
   simulator.
2. Optional now, not required (§6.2/§6.3b): confirm Special Function
   `Reset Timer:X` exists as a selectable action, only relevant to the
   alternative (non-default) reset-on-launch path — the default path is
   now fully Lua-driven and doesn't need this at all.
3. Not required for the default path anymore (§6.4): Lua-timed landing
   detection reads `LANDING_MODE` directly, no new switch needed. Still
   relevant only for the optional native mode — whether a *newly
   pilot-created* `LANDED_STABLE` resolves by name — Poker Probe checks
   this automatically on open regardless, alongside `MOM_LAUNCH` and
   `LANDING_MODE`, so it's there whenever someone wants to test native mode.
4. ~~Decide whether the "fill remaining window" convenience bet ships in
   v1.~~ **Decided (§8): yes, as FS3 ALL IN**, computed at the `MOM_LAUNCH`
   edge rather than at the press, to avoid the staleness problem raised
   directly during design review. Still to verify on the bench once built:
   that `game deadline − now` computed inside the same `wakeup()` that
   handles the launch edge is fast enough to feel instantaneous, not a
   noticeable extra beat before the timer resets.
5. ~~Whether `model.getLogicalSwitch`/`setLogicalSwitch` exist on Ethos.~~
   **Done — CONFIRMED absent (§6.4a):** `get=false set=false`. Native
   mode's debounce field can never be authoritative; permanently a manually-
   mirrored number if that mode is ever used. Lua-timed mode (the default)
   was never affected by this either way.
6. Confirm what a genuine touch event actually reports for `category` on the
   X20RS (§5.5) — Poker Probe's touch handling deliberately ignores category
   and hit-tests on raw x/y instead, as the safest guess, but this should be
   replaced with whatever the real event shape turns out to be once it's
   been seen on hardware.
7. Confirm the X14-exclusion heuristic in `system.getVersion().board` (§5.5)
   actually reads `"X14"` on a real X14 — Poker Probe reports this as its
   own result row rather than assuming it.
8. ~~Get a real `wakeup()` rate reading.~~ **Done on both simulators
   (§6.4a/§6.3b): ~52/s on X14, ~40.3/s on X20RS** — same order of
   magnitude on both, far better than the whole-second fallback either way.
   Remaining: confirm the rate holds under real hardware conditions (screen
   off, other apps active), not just the simulator's best case, and decide
   whether the implementation recalibrates periodically or trusts one
   startup measurement.
9. ~~Get the reference photo of the radio.~~ **Done (§5.1) —
   `x14_switch_mapping.png`.** The default +MIN/+SEC/ALL IN/CONFIRM
   controls are the radio's **Function Switches**, `FS1`/`FS2`/`FS3`/`FS4`,
   the row of four pill buttons above the X14's touchscreen. Still open,
   low-risk: confirm `FS1`–`FS4` is exactly what Ethos's own source picker
   shows, not just what's silkscreened on the case — find out via S5's
   source picker, pressing each one live, same tip already used for
   `MOM_LAUNCH`/`ALT_CALL`.
10. New (§6.5): confirm the Function Switches group actually defaults to a
    latching mode on a fresh model, per the pilot's own screenshot of the
    `Edit model > Function switches` picker (`4-Pos with OFF`, `4-Pos`,
    `2×2-Pos`, `4×2-Pos`, `Momentary`) — this document assumes the factory
    default is one of the latching options based on that screenshot and the
    pilot's own report, but hasn't independently confirmed which one ships
    as default. Also worth a real bench check on the relationship between
    this threshold and hold-to-reset's (§5.1): reset should fire the
    instant its own hold threshold is crossed, so a pilot naturally
    releases right after seeing it happen — confirm that in practice a
    genuine, intentional reset-hold stays comfortably under the 2.0s
    stuck-switch threshold and never falsely triggers the warning.
11. ~~Confirm `ZOOM_MODE` (LSW18) resolves by name.~~ **Done — confirmed on
    the pilot's actual test model via Poker Probe v0.9:** `MOM_LAUNCH`,
    `ZOOM_MODE`, and `LANDING_MODE` all resolve correctly, and `L:` shows
    live dwell tracking. The signal chain feeding launch/false-start
    detection is fully live — the original "stuck on ARMED" report was not
    a model-configuration issue, it was Defect 4 (fixed in the same build
    pass as items 1–8 below) surfacing because brakes, not the actual
    launch switch, were being used to try to progress. Still open: a real
    end-to-end walkthrough confirming the fixed build responds correctly
    to an actual launch-switch hold-and-release, not just to brakes, and a
    genuine false-start walkthrough (press, release into Zoom, press again
    while still on the ground) confirming the timer visibly restarts and
    the status message fires exactly once.
12. New (§5.4): confirm on real hardware that a System Tool's `wakeup()`
    genuinely stops when the pilot navigates away, and resumes correctly
    on reopen with no stale state. This document's understanding of that
    lifecycle difference comes from Ethos community reports, not this
    project's own bench testing (unlike the timer/landing work, which was
    directly confirmed via Poker Probe) — worth a real check: open Poker
    Timer, arm a bet, back out to a model screen, launch, then reopen the
    tool and confirm the launch was indeed missed (expected, per the
    accepted tradeoff) rather than silently causing something worse, like
    a stale timer state or a crash on reopen.

## 12. Test plan — Poker Probe

Before any of the real Poker Timer screens get built, a small standalone
diagnostic tool — **Poker Probe** — answers every open API question in §6
and §6.4 in one bench session, the same role the "ALT Probe" and "ALT Probe
Keys" tools played for Throw Trainer before its own primary capture path was
locked in (§17–18). It is throwaway once the real tool exists; its only job
is to turn assumptions into confirmed rows.

**Install path.** Installing it at all is the first test: unzip
`scripts/PokerProbe/` onto the radio's SD card (same layout convention as
Throw Trainer — `scripts/<folder>/main.lua`, icon file alongside it), power
cycle, and confirm a **Poker Probe** tile appears in the System menu with
its icon. If the tile doesn't appear, the icon mask is almost certainly the
cause, per Throw Trainer's own §18 finding that a missing icon fails
silently with no error anywhere — nothing else in the script needs
debugging until that tile shows up.

**What it tests, automatically on open (read-only, no side effects):**

| Row | Confirms |
|---|---|
| Install / registration | `system.getVersion()` returns a board/version string at all — proof the script is actually running |
| Touch-capable heuristic | which board string the X14-exclusion check saw, and what it decided |
| `model.getTimer` by index | sweeps indices 0–8, reports which resolve |
| `model.getTimer` by name | sweeps `Timer1`–`Timer9` by name, reports which resolve |
| Timer3 resolved | whether index 2 or the name `"Timer3"` found a usable timer, and its current start value |
| `CATEGORY_FLIGHT_MODE` sweep | whether reading flight-mode state via `system.getSource` gives anything usable at all, per the open Ethos feature requests noted in §6.4 |
| `MOM_LAUNCH` / `LANDING_MODE` / `LANDED_STABLE` by name | whether this standalone script can resolve the template's existing logic switches by name, same as Throw Trainer already proved for itself independently (§6.4a) — `LANDED_STABLE` reads "not found" until the pilot has added it, which is itself the correct pre-setup result |
| `model.get/setLogicalSwitch` exist | whether Ethos carries forward the OpenTX/EdgeTX API for reading/writing a logic switch's own parameters — relevant to native landing-detection mode only (§6.4a) |
| `wakeup()` rate (auto, ~3s) | how many times `wakeup()` fires per second on this board — decides how close Lua-timed landing detection's default debounce can get to a true 0.5s versus falling back to whole-second resolution (§6.4) |

**What it tests on demand, via the RUN key (the one test with a side effect):**

- Sets Timer3's start value to a deliberately odd number (current + 37s) and
  reads it back, to confirm a Lua-side write actually lands
- Calls `reset()` and confirms `value()` comes back near the new start value
- Watches `value()` for ~3 real seconds afterward (no extra key press) to
  confirm the timer actually *counts*, not just that the number reloaded —
  this is what caught the Start-condition requirement in §6.3a
- **RESTORE** puts Timer3's original start value back immediately — this is
  designed to be safe to run against a radio that's actually configured for
  flying, not just the simulator, and `close()` also restores automatically
  as a safety net if the pilot forgets

**What it tests continuously, once assigned via SETUP (`L:` has a sensible
default already; A/B don't):**

- A dedicated `L:` line, **configurable rather than hardcoded**, defaults to
  `LANDING_MODE` (confirmed present on the template) so it's testable
  immediately with no setup, and is repointable via SETUP at `LANDED_STABLE`
  once built. Watching the default shows the debounce problem directly: tap
  the brake briefly and see `LANDING_MODE` flip instantly with no
  filtering; once `LANDED_STABLE` is built and selected there instead, the
  same tap should leave its dwell timer resetting to 0 without ever
  reaching the debounce threshold, while holding it past that threshold
  should let the dwell timer keep climbing.
- Two further source pickers (`Test source A`, `Test source B`) use Ethos's
  own source-selection UI — same `form.addSourceField` pattern already
  proven in Throw Trainer's config screen — for pointing at anything else
  worth comparing, timed the same way (`os.time()`, not `os.clock()`, per
  §6.4's documented pitfall). Source B is a good place to point at
  `MOM_LAUNCH` directly as a known-good comparison against `L:`.

The probe script and icon are attached to this conversation as
`PokerProbe.zip`.

## 13. Project shape

This is its **own script**, not a second tool/widget bolted onto the Throw
Trainer package — separate folder, separate registration, separate log
files. It targets **Timer3** by default and never touches Timer1 (owned by
the DLG template's flight timer) or Timer2 (left free). The two tools can
run side by side on the same radio, each independently reading whatever
named logic switches and sources it needs, with no shared state between
them — the same "multiple independent readers of one source" pattern the
DLG template already supports for its own logic switches.

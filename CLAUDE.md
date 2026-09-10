# DLG Poker — project context for Claude Code

**`PokerTimer/`** — "DLG Poker", the pilot-facing app. A launch-height
poker practice timer for the F3K "Poker" task (bet a time, launch, land as
close to (or past) your bet as possible, score the bet if you make it).

Developed alongside `PokerProbe/`, a standalone diagnostic tool built to
bench-test uncertain Ethos Lua API behavior before relying on it here — most
of the hard-won knowledge below came from it. **Removed** once its findings
were folded into this app and confirmed stable; see git history (and the
Requirements Spec) to resurrect it for future bench work.

Full history, every bench-test result, and the complete rationale for every
design decision is in `DLG_Poker_Timer___Requirements_Specification.md`. This
file is a quick-orientation layer, not a replacement for it — when in doubt
about *why* something is built the way it is, search the spec for the
relevant section number referenced in the code's own comments (the code is
heavily commented with spec cross-references, e.g. "S6.4", "S11 item 9").

**Read the spec's later sections first if picking this up cold** — §6.3c
(Timer3 hardware correction) and the open item at the very end are the most
recent, most likely to still be relevant.

## Directory structure

```
PokerTimer/       -- the app: main.lua, core.lua, screen.lua, config.lua,
                     draw.lua, pokertimer.png (system tool icon)
harness/          -- test.lua (56+ tests) + core.lua (a SYNCED COPY of
                     PokerTimer/core.lua -- see workflow below)
DLG_Poker_Timer___Requirements_Specification.md
```

Both apps are **system tools only, no widget** (a deliberate choice for
DLG Poker — see spec §5.4 — since a poker game demands continuous active
engagement, unlike a background-logging tool). Registering as a widget was
considered and explicitly rejected.

## Critical Ethos-specific findings (do not re-guess these)

These cost many rounds of real-hardware bench testing via Poker Probe. Do not
"correct" them back to standard Lua idioms without re-verifying on hardware.

**File I/O — this is the big one.** Ethos's Lua `io` library is NOT standard
Lua. Confirmed on real hardware:
- `f:lines()` — **throws outright**: `"method 'lines' is not callable (a nil value)"`.
- `f:read("*a")` / `f:read("a")` / `f:read()` (colon-method reads) — **do not
  throw, but silently return nil/garbage**. This is worse than throwing: it
  was originally masked by Poker Probe's own test rig not shipping a `Files/`
  folder (so failures looked identical either way), which caused a long,
  partly-misleading investigation. Once a real file/directory existed, these
  calls started throwing `"bad argument"` instead.
- **`f:write(...)` (colon-method) — CONFIRMED WORKING**, both `"w"` and `"a"`
  modes. Do not "fix" this; it was never broken.
- **The actual working read pattern**, confirmed via Poker Probe writing a
  known value and reading it back byte-for-byte:
  ```lua
  local f = io.open(path, "r")
  local chunks = {}
  while true do
    local chunk = io.read(f, 512)   -- GLOBAL function, handle as 1st arg
    if not chunk or #chunk == 0 then break end
    chunks[#chunks + 1] = chunk
  end
  io.close(f)                        -- GLOBAL function here too
  local content = table.concat(chunks)
  ```
  This matches Ethos/EdgeTX's own documented io library
  (luadoc.edgetx.org) — a restricted subset using global functions
  (`io.read(f, n)`, `io.write(f, ...)`, `io.close(f)`) with the handle as an
  explicit first argument, NOT the standard Lua colon-method convention.
  `core.lua`'s `readRows()` implements this correctly today. `appendRow()`
  and `rewrite()` use ordinary colon-method `f:write()`/`f:close()`
  deliberately, since that's confirmed to work.
- **Important caveat**: the test harness runs on real, unmocked Lua (not
  Ethos), where `io.read(f, n)` does NOT mean "read from handle f" — standard
  Lua's `io.read` reads from default stdin. The harness's own tests still all
  pass because nothing in the game-logic tests depends on `readRows()`
  returning real file content — but this means **the harness cannot validate
  file I/O correctness at all**. Only Poker Probe on real hardware can. Keep
  this in mind before assuming "harness passes" means a storage-related
  change is safe.

**Function Switches (FS1–FS4)** resolve via:
```lua
system.getSource({ category = 12, member = 0..3 })  -- FS1=0, FS2=1, FS3=2, FS4=3
```
`12` is a raw empirically-discovered number — confirmed via
`Source:category()` on a manually-picked FS1, not from any documented
`CATEGORY_*` constant (none of the ~20 discovered globals matched). Do not
replace with a symbolic constant unless Ethos ships one in a future version
and you've re-confirmed it.

**Timer3 setup — real hardware contradicts the simulator.**
`t:direction(-1)` + `t:countingSource(nil)` (called "AUTOCFG" in the code and
spec) was confirmed on an X20RS **simulator** to fully replace manually
setting Countdown mode + Start condition = Always in `SYSTEM > TIMERS`. A
later real X14 field report contradicted this: the countdown sets up
correctly but **never actually starts** without the manual "Always" step.
AUTOCFG is still called (harmless, probably still sets direction correctly)
but is no longer trusted as sufficient on its own — DLG Poker's CONFIG
screen states the manual step as required. See spec §6.3c. **Whether a real
(non-simulator) X20RS behaves like the simulator or like the X14 is still
unconfirmed** — that's the most likely next thing worth bench-testing if
picking this up.

**`system.registerSystemTool` needs an icon mask or it silently never
appears** in the System menu, with no error anywhere. Always pass
`lcd.loadMask("icon.png")`, wrapped in `pcall` in case the file is missing.

**Launch detection model** (core.lua, "launch (revised, field-tested)"
section) — this went through several field-corrected iterations, driven
directly by the DLG-for-Ethos template's actual flight-mode logic:
0. **No separate CONFIRM step** (removed 2026-09 per pilot field-test
   feedback — `core.confirmBet()` no longer exists). A bet is armed by the
   throw itself: if `handleLaunchFall()` (step 2) fires while the bet
   isn't armed yet, it locks in whatever `editMin`/`editSec` was showing
   at that instant as `target_s`, arms the bet, and proceeds exactly like
   an already-armed release — all in the same event. ALL IN is unaffected
   (`core.allIn()` still arms explicitly, ahead of the throw, since it has
   no fixed target yet to auto-confirm from).
1. **Press** (`MOM_LAUNCH` rises) = priming/re-grip. Resets the timer to the
   bet's target — but only if not yet confirmed (see step 3), and only if
   the bet is already armed (a press before the bet's first-ever throw does
   nothing — there's no target yet to reset to).
2. **Release** (`MOM_LAUNCH` falls) = the actual throw. Starts the timer
   counting and counts as an attempt (and, per step 0, arms the bet first
   if it wasn't already).
3. **Elevator push/pull** (`ZOOM_MODE` transitions true→false) = confirms a
   genuine flight happened. Until this fires, a landing signal (brakes) is
   ignored — protects against ground-fumbling falsely scoring a hit/bust.
   Once confirmed, the timer is **locked**: further presses/releases do
   nothing *while the flight is still genuinely in progress* — see step 3a.
3a. **Landed without braking, or the switch touched again before any
   landing at all** (pilot field-test reports, 2026-09, four rounds): if
   `LANDING_MODE` never fires (overshoots downwind and runs it in), OR the
   pilot's hand brushes `MOM_LAUNCH` while genuinely still airborne (there
   is no way to tell these apart from the switch signal alone), the bet
   used to stay confirmed-and-armed forever, and step 3's lockout made
   BOTH steps 1 and 2 permanent no-ops for it — a second throw sequence
   did nothing at all, so the physical timer (never stopped or reset)
   just silently kept counting straight through. Fixed via
   `autoBustUnresolvedFlight()`: if the bet is armed, confirmed, and
   still unresolved (`result == "pending"`) when a new throw sequence
   begins, that's auto-busted (not scored as a hit).
   - **Second round**: revised to NOT auto-restart the countdown — the
     first version re-armed and restarted immediately on the SAME throw's
     release, which defeated the (then-existing) alert's whole point
     ("stop and look at the screen"). That report was specifically about
     landing **without braking after the target was already reached**.
   - **Third round**: reported relaunching **while the timer was still
     actively counting**, well before the target — expected the OLD bet
     to bust and the SAME target to restart immediately, no third throw
     required. `autoBustUnresolvedFlight()` now reads the live timer
     value (`timerValue()`) to pick between the two:
     - **Still counting** (`liveVal > 0`, or unreadable): busts the old
       attempt, clears `S.flightConfirmed`, and immediately calls
       `timerSet(bet.target_s)` + `timerReset()` — `g.armed` stays `true`
       throughout. Reuses the SAME mechanism the ground re-grip case
       (step 1) already had for `not S.flightConfirmed` — clearing the
       flag here is what lets that "reset now, let the release actually
       start a fresh attempt" logic run for a CONFIRMED flight too.
       `handleLaunchFall()`'s own attempts-increment/`result = "pending"`
       logic (unchanged) is what turns the SAME throw's release into the
       actual new attempt.
     - **Already reached** (`liveVal <= 0`): unchanged from the second
       round — sets `g.armed = false`, pre-fills `g.editMin`/`g.editSec`
       from the interrupted bet's own `target_s`, and sets
       `S.suppressNextAutoConfirm = true` so the release half of THIS
       SAME throw doesn't immediately fall into step 0's auto-confirm and
       re-arm right back.
   - **Fourth round**: "the user could brush up against the launch button
     but won't hold it for say, more than a third of a second... just let
     them continue the flight" — plus "remove the vibration and audio
     alert even if they relaunch intentionally." Two changes:
     - **`pollRelaunchDebounce()`**, a new function polled every
       `core.wakeup()` (alongside `pollZoomConfirm()`/`pollLanding()`),
       now GATES `autoBustUnresolvedFlight()` entirely —
       `handleLaunchRise()`/`handleLaunchFall()` no longer call it
       directly at all. Same level-based call-counting pattern
       `pollLanding()` already uses for `LANDING_MODE` (`S.relaunchCalls`,
       `S.cfg.relaunchDebounce` default `1/3` second) — while armed,
       confirmed, and `result == "pending"`, it watches `MOM_LAUNCH`'s
       raw level every wakeup(); released before the threshold resets the
       counter to 0 and NOTHING happens (no bust, no timer change); held
       past it fires `autoBustUnresolvedFlight()` immediately, mid-hold.
       The existing rise/fall handlers didn't need restructuring beyond
       removing that one call each — both already no-op while
       `S.flightConfirmed` is true, which is exactly the state this new
       poller now owns exclusively; the poller's own bust clears that
       flag, letting the (unchanged) fall-through logic in each handler
       pick up correctly whichever way it resolved.
     - **`alertUnresolvedRelaunch()` (the `system.playTone`/`playHaptic`
       calls) was deleted outright**, not just silenced conditionally —
       once a real relaunch is reliably distinguishable from a brush by
       the debounce above, neither case needs an alarm: a brush is now a
       complete no-op, and a deliberate hold doesn't need one either.

   A real landing (brakes) is completely unaffected by any of this — it
   still resolves the attempt the normal way, via step 5, and stays armed
   for an immediate retry as it always has. Covered by harness Tests 13
   (target-reached case, held via `pump(0.4)` to cross the debounce),
   13b (still-counting case, same), and 13c (a brush shorter than the
   debounce — asserts NOTHING changes: not the result, not
   `flightConfirmed`, not the attempt count, no alert).
4. **Exception**: once the timer counts down to zero (target reached), the
   confirmation requirement is waived — that much real elapsed time already
   rules out ground-fumbling regardless of whether the elevator gesture
   happened. Confirmed via a dedicated regression test that early-flight
   protection (before target reached) is unaffected.
5. **Brakes held** (debounced, `landingDebounce` config, default **1.0s**
   as of 2026-09 pilot field-test feedback — was 0.5s, not long enough to
   rule out an accidental in-flight brake tap) = ends the attempt, scoring
   hit or bust based on whether the timer had reached zero.

## Rotary/FS edit mode for MIN/SEC/BETS (2026-09, screen.lua only)

On a rotary/FS radio (no touch), scrolling focus to MIN, SEC, or BETS
and pressing ENTER now starts editing that field directly: `rotaryEditField`
(`nil | "min" | "sec" | "bets"`, module-local in screen.lua) switches
ROTARY scroll from moving footer focus to calling that field's up/down
functions directly instead — looked up from `ROTARY_EDIT_FIELDS`, a small
table mapping each field to its `{label, up, down}` (MIN/SEC use
`core.bumpMin`/`bumpMinDown`/`bumpSec`/`bumpSecDown`; BETS wraps
`core.bumpBets(1)`/`core.bumpBets(-1)` since that one already took a
signed delta). Bidirectional either way, unlike the plain footer keys
which only ever bump up (BETS's footer key still wraps 5→1 on overshoot,
unchanged). ENTER again, or RTN/EXIT, leaves edit mode. `screen.paint()`
self-heals it to `nil` if the focused key stops matching that field's
label out from under it (e.g. a real throw arms the bet mid-edit).

**Touch radios use the exact same mechanism** (pilot request, 2026-09:
"the touch screen version should have the same scroll wheel behavior as
the non-touch screen... the only behavior that's different is that you
can tap directly on the number rather than scroll to min and sec at the
top of the screen"). Earlier touch-only designs — a full-screen native
form field, a compact +/- text row, then drawn arrow-triangle steppers
flanking each value — are all gone; SETUP and LIVE now render the exact
same layout on touch and non-touch radios (no more `isTouchCapable()`
branch for the WINDOW/BETS/MIN/SEC layout itself). The only touch
addition is a tap zone directly over each value (registered via
`registerEditTap()`, defined right after `keysFor()` since it calls it)
whose action is `toggleEditField()` — that function looks up the tapped
field's footer label in `ROTARY_EDIT_FIELDS`, sets `focus[]` to that
footer key's index (so the footer's own "editing" highlight lights up
exactly as it would from a non-touch ENTER press) and toggles
`rotaryEditField`, since touch has no physical ENTER to press a second
time to leave. WINDOW is one combined `"M:SS"` string on SETUP (not two
boxes the way LIVE's MIN/SEC already are), so its tap zone splits at the
digit boundary between the minutes part and the `":SS"` remainder —
`tostring(math.floor(core.S.setupWindow / 60))`'s width — so "tap
minutes or seconds" works without restructuring that display. Once
`rotaryEditField` is set, ROTARY scroll behaves identically regardless of
how it got set — no touch-specific bump logic exists anymore. A tapped
field also gets an accent-colored border drawn directly around it while
editing (`t.accent`, 2px `lcd.drawRectangle`) since a touch pilot's
finger is on the value itself, not the footer, when they need the
feedback.

Verified with a full end-to-end execution test (mocked `lcd`/`system`/
`model`/`form`/`FONT_*`/`KEY_*`, real `loadfile` require chain matching
`main.lua`, `system.getVersion().board = "X20RS"` to force
`isTouchCapable()` true) that grid-taps SETUP and LIVE's content area —
deliberately excluding the footer key row and SETUP's CONFIG button,
since a blind scan's first run tapped START mid-sweep and changed
`core.S.screen` out from under the probe — and confirms a tap toggles
`rotaryEditField` (value unchanged by the tap itself, changed by a
following ROTARY scroll) for WINDOW, BETS, and LIVE's MIN/SEC boxes, plus
re-confirms the non-touch ENTER+scroll path still works after the shared-
layout refactor. See [[reference_lua_testing_via_lupa]] (assistant
memory) for why this level of test — not just a syntax check — is
mandatory for any `draw.lua`/`screen.lua` change on this project.

**Deliberately does NOT use a long-press-ENTER gesture** (a `KEY_ENTER_LONG`-
style "hold to reset" mirroring the FS-switch hold-to-reset) even though
that was the pilot's first request. Checked the Ethos key-event constants
before building anything (same "verify before shipping" approach as the
touch/arrow-triangle work) and found a live FrSkyRC-Feedback-Community
report that receiving that long-press event in a System Tool **suspends
all key input** — a system-level side effect this app has no control
over, not just "did I get the constant name right." The ENTER-to-edit-
then-scroll design solves the same problem (reaching 0 without wrapping
through the whole range) using only `KEY_ENTER_BREAK`/`KEY_ROTARY_LEFT`/
`KEY_ROTARY_RIGHT`, all three already proven reliable elsewhere in this
file, so there was no reason to take on that risk.

## Footer row hides itself when nothing is actionable (2026-09, paintKeys)

`keysFor(LIVE)` returns `{"-","-","-","-"}` while a bet is mid-flight
(armed, `attempts > 0`, not yet resolved) — none of the four keys do
anything until landing. `paintKeys()` now checks whether every slot in
`topKeys` is `"-"` and skips drawing the row entirely in that case
(pilot request: "no reason to have the buttons up there"), rather than
rendering four empty bordered boxes. The CONFIG button (SETUP's 5th key,
drawn separately in the bottom-right corner) is unaffected either way.
**Note**: this only hides the row — it does not reflow the content below
it, which is still positioned from the fixed `CONTENT_TOP = CHROME_H +
KEY_ROW_H` constant regardless of whether the row actually drew anything,
so hiding it currently just leaves that space blank rather than reclaimed
for the countdown display. Revisit if that blank strip turns out to
bother pilots in practice.

## Timer-missing detection + recovery (2026-09, core.lua + config.lua + screen.lua)

Real field report: the pilot renamed the target Ethos timer (`Timer3` →
`Poker Timer`) for their own audio-callout purposes. `resolveTimer()`
(by-name lookup, deliberate -- see "Resolve by NAME only" above) then
found nothing, `S.timerObj` went `nil`, and every `timerSet`/
`timerReset`/`timerValue` call already silently no-ops on that (`if not
S.timerObj then return end`) -- so the whole app just went quietly dead
with zero indication why.

- `core.timerMissing()` -- `S.ready and S.timerObj == nil`. Checked by
  screen.lua on both SETUP and LIVE to show a persistent red "TIMER NOT
  FOUND" warning (not `core.setStatus()` -- that auto-clears after 3s,
  and this needs to stay up until actually fixed).
- `core.resolveTimerNow()` -- re-resolve + re-autoconfig without a
  restart. config.lua's Target timer field now calls this after every
  edit -- it never did before, so retyping the correct current name
  silently didn't take effect until the next restart either.
- `core.renameTimerToDefault()` -- pilot request ("can you have the lua
  change the name back"): renames the CURRENTLY-RESOLVED `S.timerObj`
  back to the default name and points config at it. Deliberately does
  NOT try to enumerate/guess candidate timers by numeric index to offer
  a picker -- Poker Probe's own bench-testing (S6.3a, see above) already
  found `model.getTimer(index)` unreliable past index 1 on real
  hardware, and Ethos's form API has no timer-picker field type either
  (confirmed against the official Lua reference: `addSourceField`/
  `addSwitchField`/`addSensorField` exist, no `addTimerField`). So the
  real recovery is still "retype Target timer to the timer's actual
  current name" (already resolves correctly once it matches, now
  immediately per the point above) -- this button only runs afterward,
  to restore the standard name if the pilot wants that back.
- `timer:name(newName)` as a setter confirmed via the official Ethos Lua
  reference before using it (get/set pattern, same as `direction()`/
  `countingSource()`/`start()` already established in this file).

## ThrowTrainer look-and-feel redesign (2026-09, draw.lua + screen.lua)

Pilot request after reviewing an HTML mockup (published as an Artifact,
not kept in this repo) comparing DLG Poker's LIVE screen against
ThrowTrainer's actual visual language: "this is what I was talking
about... let's upgrade this design."

- **`THEMES.day`/`THEMES.night` in draw.lua**: every value (both themes)
  copied verbatim from `ThrowTrainer/draw.lua`'s `lightPalette()`/
  `darkPalette()`, not re-invented. Night was already close to this by
  coincidence (same project ecosystem); day was the one that actually
  diverged -- DLG Poker's old day theme used flat, saturated colours
  (`accent = 0x0B63C9`, `bad = 0xC5221F`) vs. ThrowTrainer's softer,
  muted set. New `*Bg` tint variants (`accentBg`/`goodBg`/`badBg`/
  `dimBg`) didn't exist before this -- DLG Poker had no tinted-background
  concept at all -- and exist specifically to back the badge component.
- **`draw.badge(x, y, text, color, bg, maxW)`** + **`draw.badgeSize()`**:
  ported from ThrowTrainer's own `draw.badge()`, same flat-corner
  filled+bordered-pill construction. Applied to LIVE's SCORE readout, the
  "BET N: HIT +Ns credited" banner, and the "Attempt N on this bet" line
  specifically on a BUST (the other attempt-count states keep plain dim
  text -- they don't need the same visual weight).
- **`draw.dottedLine(x, y, w, color)`**: thin dotted rule via
  `lcd.pen(DOTTED)`, the same boundary-mark technique
  ThrowTrainer's `draw.strip()` uses for chart section breaks (that
  file's own comment already established DOTTED as hardware-confirmed --
  "no DASHED constant has been confirmed on this target" -- same Ethos
  Lua pen API, same radio family, not re-verified separately here).
  Replaces LIVE's plain gap under the BET/SCORE row and LOG's plain
  divider line above the vs-average/vs-best stats, both in `t.marker`
  (the same orange ThrowTrainer's own marker color uses).
- **One thing the mockup couldn't actually promise**: it used a
  monospace web font ("JetBrains Mono") for hero numbers, since that's
  free to do in HTML. Checked the real Ethos Lua font constants before
  building anything (`FONT_XXS` through `FONT_XXL`, some with `_BOLD`/
  `_ITALIC` variants) against the official reference -- confirmed these
  are all sizes of ONE system typeface, not a choice of font families.
  There is no way to render digits in an actual monospace face on real
  hardware. GAME LEFT / the live countdown stay on `FONT_L`/`FONT_XL` (no
  typeface change) rather than promising something the radio can't do.

Colour changes propagate automatically everywhere `draw.theme()` is
already read (SETUP/LIVE's tap-to-edit zones, SUMMARY's per-bet result
colours, CONFIG's "About" text, etc.) -- only the screens getting NEW structural
elements (badges, dotted dividers) needed screen.lua changes at all.

## LOG screen navigation fixes (2026-09, screen.lua only)

Two real bugs from a pilot field report, both in `screen.event()`'s
ROTARY/ENTER handling, which is entirely LOG-specific and not covered by
the core.lua harness:

- **Scrolling had no upper bound.** `logTop = math.max(1, logTop + d)`
  floored at 1 but never capped -- scrolling right past the actual game
  count left `logTop > #games`, and `paintLog()`'s draw loop
  (`for i = logTop, math.min(logTop + rows - 1, #games) do`) then has an
  empty range, so nothing renders at all. With few games logged this is
  trivially easy to hit (one or two clicks past a 3-game list), and reads
  as "the whole log vanished" rather than "you've scrolled past the
  oldest game." Fixed by caching `logGameCount`/`logVisibleRows` (set by
  `paintLog()` every frame -- same pattern `keyRects`/`valueRects`
  already use for paint-computes/event-consumes) and clamping to
  `math.max(1, logGameCount - logVisibleRows + 1)` as the ceiling.
- **BACK was unreachable via ENTER.** LOG's ROTARY is fully dedicated to
  list-scrolling (see above), so unlike every other screen, it never
  moves `focus[SCREEN.LOG]` -- that stays stuck at its initial value (1)
  forever, meaning ENTER always tried to `activate()` whatever's at
  index 1 (OPEN, before it was removed -- see the open-items list above).
  BACK was only reachable via the FS4 physical switch or the native
  RTN/EXIT key, with nothing on screen indicating either. Fixed by
  special-casing `KEY_ENTER_BREAK` on `SCREEN.LOG` to look up and
  `activate()` whichever footer slot is labelled `"BACK"` directly,
  bypassing `focus[]` entirely for this one screen.

## Test workflow (follow this before shipping any core.lua change)

Two ready-to-run scripts do this for you — no snippets to reconstruct:

```bash
python3 harness/syntax_check.py        # checks every .lua file parses
cp PokerTimer/core.lua harness/core.lua  # sync the harness's copy
python3 harness/run_tests.py           # runs the full suite (96 tests, as of last count -- grep "check(" harness/test.lua for the current one)
```

`run_tests.py` warns you directly if you forget the sync step — it diffs
`harness/core.lua` against `PokerTimer/core.lua` before running and tells you
if you're about to test a stale copy. Forgetting this sync was a recurring
source of confusion earlier in this project's history; the warning exists
specifically because of that.

Both scripts try to auto-locate a Lua 5.4/5.3 install and print a clear
message (rather than a cryptic ctypes error) if none is found. **This
machine has neither** (no `lua`/`luac`, no `gh` CLI either) — see
[[reference_lua_testing_via_lupa]] (assistant memory, not a file in this
repo) for `pip3 install lupa`, which gives a real embedded Lua 5.5
callable from Python and can run `harness/test.lua` directly, bypassing
these two scripts' `ctypes`-based lookup entirely (it won't find lupa's
interpreter that way).

When adding a new core.lua behavior, add a harness test for it in the same
pass — this project caught several real bugs this way (stale
`flightConfirmed` state, unregistered switch roles crashing `pollRole`,
`CONFIRM` reachable on the wrong screen) that static review missed.

**Harness gotcha**: test setup blocks frequently need to explicitly reset
screen/state (`core.S.screen`, `core.S.flightConfirmed`, `core.S.game.idx`,
etc.) before a new test section, since tests run sequentially against shared
module state. Several rounds of "test failed" turned out to be leftover
state from the previous test, not a real regression — always check this
before assuming a genuine bug.

## Packaging

```
scripts/PokerTimer/
  main.lua, core.lua, screen.lua, config.lua, draw.lua, pokertimer.png
  Files/.gitkeep          -- REQUIRED, ships an empty placeholder since Lua
                             cannot create missing parent directories, and
                             Poker Probe's own missing Files/ folder caused
                             a long, misleading debugging detour
```
Zip from a directory containing `scripts/`, not from inside it.

Install is a **merge/overwrite**, not delete-then-extract — deleting the
whole `PokerTimer/` folder first would take `Files/games.csv` etc. with it.
Ethos scans scripts only at boot — a full restart is required after any
install, not just closing/reopening the tool.

## Known-open items (as of last session)

1. **Timer1 coexistence** — the pilot runs a separate Timer1 (count-up,
   starts on launch) for normal flying alongside DLG Poker's Timer3. No
   conflict today (DLG Poker never touches Timer1), but pausing/resuming
   Timer1 automatically during a poker game was discussed as a possible
   future feature. **Explicitly deferred pending a Poker Probe test** of
   pausing/resuming an arbitrary timer's counting state on real hardware —
   given the countingSource() simulator/hardware divergence above, this
   should not be built into DLG Poker without that verification first.
2. **X20RS real-hardware Timer3 behavior** — unconfirmed (see above).
3. Minor: the one `games.csv` row written before the hit-count field was
   added will display bet count without a hit fraction (graceful, not a bug,
   but worth knowing if a log display looks slightly inconsistent for old
   data).
4. Viewing a single game's per-bet breakdown from the log list was never
   built (spec-noted, not forgotten). The `OPEN` footer key that used to
   sit there as a placeholder for it was removed entirely 2026-09 (pilot
   report: a visible button that does nothing reads as broken, not as
   "not built yet") — LOG's footer is just `{"-","-","-","BACK"}` now.
   Revisit both together if this view gets built.

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
   landing at all** (pilot field-test reports, 2026-09, two rounds): if
   `LANDING_MODE` never fires (overshoots downwind and runs it in), OR the
   pilot's hand brushes `MOM_LAUNCH` while genuinely still airborne (there
   is no way to tell these apart from the switch signal alone), the bet
   used to stay confirmed-and-armed forever, and step 3's lockout made
   BOTH steps 1 and 2 permanent no-ops for it — a second throw sequence
   did nothing at all, so the physical timer (never stopped or reset)
   just silently kept counting straight through. Fixed via
   `autoBustUnresolvedFlight()`, called at the top of both
   `handleLaunchRise()` and `handleLaunchFall()`: if the bet is armed,
   confirmed, and still unresolved (`result == "pending"`) when a NEW
   throw sequence begins, that's auto-busted (not scored as a hit) and
   plays an audible tone + haptic (`system.playTone`/`playHaptic`,
   confirmed present since Ethos 1.1.0) since this is otherwise a
   completely silent correction the pilot has no other way to notice.
   **Revised 2026-09 (second field-test round) to NOT auto-restart the
   countdown**: the first version of this fix re-armed and restarted
   immediately on the SAME throw's release, which defeated the alert's
   whole point ("stop and look at the screen") since nothing actually
   made the pilot look. Now `autoBustUnresolvedFlight()` also sets
   `g.armed = false`, pre-fills `g.editMin`/`g.editSec` from the
   interrupted bet's own `target_s` (so the editing screen shows a
   matching, ready-to-relaunch time), and sets
   `S.suppressNextAutoConfirm = true` so the release half of THIS SAME
   throw doesn't immediately fall into step 0's auto-confirm and re-arm
   right back — `handleLaunchFall()` checks that flag first and, if set,
   clears it and returns without arming. A genuinely separate, subsequent
   throw is what actually arms+starts again, going through step 0 exactly
   like any other bet. A real landing (brakes) is completely unaffected
   by any of this — it still resolves the attempt the normal way, via
   step 5, and stays armed for an immediate retry as it always has.
4. **Exception**: once the timer counts down to zero (target reached), the
   confirmation requirement is waived — that much real elapsed time already
   rules out ground-fumbling regardless of whether the elevator gesture
   happened. Confirmed via a dedicated regression test that early-flight
   protection (before target reached) is unaffected.
5. **Brakes held** (debounced, `landingDebounce` config, default **1.0s**
   as of 2026-09 pilot field-test feedback — was 0.5s, not long enough to
   rule out an accidental in-flight brake tap) = ends the attempt, scoring
   hit or bust based on whether the timer had reached zero.

## Rotary/FS edit mode for MIN/SEC (2026-09, screen.lua only)

On a rotary/FS radio (no touch), scrolling focus to MIN or SEC and
pressing ENTER now starts editing that field directly: `rotaryEditField`
(`nil | "min" | "sec"`, module-local in screen.lua) switches ROTARY scroll
from moving footer focus to calling `core.bumpMin`/`bumpMinDown`/
`bumpSec`/`bumpSecDown` directly (same functions/granularity the touch
arrow steppers already use) — bidirectional, unlike the plain MIN/SEC
footer keys which only ever bump up. ENTER again, or RTN/EXIT, leaves
edit mode. `screen.paint()` self-heals it to `nil` if the focused key
stops being MIN/SEC out from under it (e.g. a real throw arms the bet
mid-edit).

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

## Test workflow (follow this before shipping any core.lua change)

Two ready-to-run scripts do this for you — no snippets to reconstruct:

```bash
python3 harness/syntax_check.py        # checks every .lua file parses
cp PokerTimer/core.lua harness/core.lua  # sync the harness's copy
python3 harness/run_tests.py           # runs the full suite (65 tests)
```

`run_tests.py` warns you directly if you forget the sync step — it diffs
`harness/core.lua` against `PokerTimer/core.lua` before running and tells you
if you're about to test a stale copy. Forgetting this sync was a recurring
source of confusion earlier in this project's history; the warning exists
specifically because of that.

Both scripts try to auto-locate a Lua 5.4/5.3 install and print a clear
message (rather than a cryptic ctypes error) if none is found.

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
4. `OPEN` (FS1 on the LOG screen) has no functionality yet — viewing a
   single game's per-bet breakdown from the log list was never built,
   deliberately left as a placeholder (spec-noted, not forgotten).

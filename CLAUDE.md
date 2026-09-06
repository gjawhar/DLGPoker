# DLG Poker — project context for Claude Code

Two FrSky Ethos Lua scripts developed together over an extensive session of
real-hardware debugging:

- **`PokerTimer/`** — "DLG Poker", the actual pilot-facing app. A launch-height
  poker practice timer for the F3K "Poker" task (bet a time, launch, land as
  close to (or past) your bet as possible, score the bet if you make it).
- **`PokerProbe/`** — a standalone diagnostic tool, built specifically to
  bench-test uncertain Ethos Lua API behavior *before* relying on it in
  DLG Poker. Most of the hard-won knowledge below came from this tool.

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
PokerProbe/       -- the diagnostic tool: main.lua, probe.lua, pokerprobe.png
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
1. **Press** (`MOM_LAUNCH` rises) = priming/re-grip. Resets the timer to the
   bet's target — but only if not yet confirmed (see step 3).
2. **Release** (`MOM_LAUNCH` falls) = the actual throw. Starts the timer
   counting and counts as an attempt.
3. **Elevator push/pull** (`ZOOM_MODE` transitions true→false) = confirms a
   genuine flight happened. Until this fires, a landing signal (brakes) is
   ignored — protects against ground-fumbling falsely scoring a hit/bust.
   Once confirmed, the timer is **locked**: further presses do nothing.
4. **Exception**: once the timer counts down to zero (target reached), the
   confirmation requirement is waived — that much real elapsed time already
   rules out ground-fumbling regardless of whether the elevator gesture
   happened. Confirmed via a dedicated regression test that early-flight
   protection (before target reached) is unaffected.
5. **Brakes held** (debounced, `landingDebounce` config) = ends the attempt,
   scoring hit or bust based on whether the timer had reached zero.

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
Same structure for `scripts/PokerProbe/`. Zip from a directory containing
`scripts/`, not from inside it.

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

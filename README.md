# DLG Poker

A practice tool for the F3K "Poker" task (Task E) on FrSky Ethos radios.
Built/field-tested on an X14.

Poker is a *time* game, not a height game: within a 10-minute working-time
window, the pilot commits to a target flight time before each launch, then
tries to land as close to (or past) that bet as possible. DLG Poker's job
is to drive the radio's own countdown timer with each bet at the right
moment and keep score — it doesn't add its own audio or invent a second
timekeeping system, since Ethos timers already do countdown beeps and
voice announcements well.

## How a game works

| Term | Meaning |
|---|---|
| Game | The 10-minute working-time window (configurable) |
| Bet | One announced target time |
| Hit | The bet's timer reached zero before landing |
| Bust | Landed before the timer reached zero — bet stays locked, try again |
| Retry | Re-launching to attempt the same locked bet again after a Bust |
| Score | Sum of the target times for every Hit this game |

1. Open the tool (System Tool, no widget) and set the window length and
   number of bets for the game, or just start with the configured
   defaults.
2. Press **START**. The game clock begins and the first bet is live.
3. Bump the bet up with **+SEC** (adds 10s, rolling into +1 min past 50s)
   or **+MIN** (adds 1 min). On a rotary/FS radio (e.g. X14), you can also
   scroll focus to MIN or SEC and press **ENTER** to edit it directly —
   scrolling then adjusts that field up *or* down (same 1 min / 10s steps),
   and ENTER again (or EXIT) leaves the field. On touch-capable radios
   (e.g. X20RS), tap the up/down arrows next to the time instead — also
   bidirectional. Then just **launch**: releasing the glider locks in
   whatever time was showing and starts your target Ethos timer counting
   down, in the same motion — no separate confirm press.
4. The radio's own configured countdown beeps/voice alerts count the bet
   down as normal; DLG Poker doesn't add anything to that.
5. Land. Landing is detected from a debounced Landing-mode/brake signal
   (an instant brake tap mid-flight is ignored) the moment you land:
   - Timer already reached zero → **Hit**, the bet's time is scored, and
     the next bet becomes editable.
   - Timer still counting → **Bust** — the bet stays locked, and
     launching again (**Retry**) restarts the same countdown with no
     extra button press needed.
   - Landed without braking (e.g. overshot on a downwind leg and just ran
     it in)? Going through the throw sequence again automatically busts
     the unresolved attempt and restarts the same countdown, exactly like
     an explicit Bust — you don't need to touch anything else first.
6. **ALL IN** claims whatever time is left in the game window as your
   bet — computed at the moment you actually launch, not when you press
   the button. Unlike a normal bet, ALL IN still needs its own button
   press before you throw, since there's no edited time on screen for the
   throw itself to lock in.
7. After every bet in the game is resolved (or the window runs out), a
   summary shows each bet's result and the total score, logged for later
   review (recent games, best game, running average).

## Settings

- **Game defaults** — working-time window length, bets per game.
- **Timer** — which Ethos timer DLG Poker drives. **One-time manual setup
  required:** in `SYSTEM > TIMERS`, set that timer's Start condition to
  **Always**. Confirmed on real X14 hardware — without this, DLG Poker
  sets the countdown up correctly but it never actually starts. DLG Poker
  never touches that timer's own countdown/alert beeps, only its duration.
- **Landing detection** — Lua-timed or native-logic-switch mode, which
  switch to watch, and a debounce threshold (1.0s by default) so a quick
  accidental brake tap mid-flight doesn't end a bet early.
- **Controls** — switch assignment for +MIN / +SEC / ALL IN /
  START-CANCEL-NEXT (defaults to the X14's Function Switches FS1–FS4), a
  hold-to-reset threshold, and a stuck-switch warning.
- **Display** — day or night mode.

## Installation

### Install with Ethos Suite

1. Prepare a ZIP file containing the final folder structure directly: the
   archive's top-level path should be `scripts/PokerTimer/...`, not
   wrapped in an extra parent folder.
2. In Ethos Suite, open the **Lua Library** tab.
3. Choose **Install lua script** and select the ZIP file.
4. Let Ethos Suite copy the script to the radio, then reboot — DLG Poker
   is a System Tool, so it appears in the System menu as "DLG Poker" (no
   widget/screen assignment needed).
5. Open it once to set the Timer/Landing detection/Controls options in
   Settings (see above) — the one-time `SYSTEM > TIMERS` step is required
   before it will actually count down.

ZIP structure for Ethos Suite:

```
scripts/
└── PokerTimer/
    ├── main.lua
    ├── core.lua
    ├── draw.lua
    ├── screen.lua
    ├── config.lua
    ├── pokertimer.png
    └── Files/
```

`Files/` must exist (even empty) because the tool stores its game log
there automatically as it runs.

### Install manually via the SD card or internal storage

Ethos radios can store scripts either on a removable SD card or in the
transmitter's internal storage — use whichever your radio is set up with.

1. Connect the radio to your computer and open its storage (SD card or
   internal storage, depending on your setup) in your file manager.
2. Copy the `PokerTimer` folder into the `scripts` folder there so the
   final script path is `scripts/PokerTimer/main.lua`.
3. Safely disconnect/eject and reboot the radio — Ethos scans scripts
   only at boot.
4. Open **System > Tools > DLG Poker** and configure the Timer, Landing
   detection, and Controls settings before your first game.

## Status

Field-tested on a real X14. Touch-capable radios (e.g. X20RS) are
supported too — footer keys and the MIN/SEC up/down arrows are tappable
directly, with a fix for a double-fire quirk some touch radios have where
a single tap could otherwise register as two. A few known gaps are
tracked in [`CLAUDE.md`](./CLAUDE.md#known-open-items-as-of-last-session)
(e.g. X20RS hardware behavior for one timer API path is still
unconfirmed, and the log screen's per-game detail view isn't built yet).
Version `0.2` — actively evolving, not a finished 1.0.

## Development

See [`CLAUDE.md`](./CLAUDE.md) for architecture notes and the hard-won
Ethos-Lua findings this project ran into (timer API quirks, launch/landing
detection design, the required manual timer setup step) — read that before
touching `core.lua`. For the complete design rationale and every bench-test
result behind a given decision, see
[`DLG_Poker_Timer___Requirements_Specification.md`](./DLG_Poker_Timer___Requirements_Specification.md).

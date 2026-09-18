# 2026-09-18 1810 — Thermal protection is instrumented, not enforced, because its thresholds would be guesses

Every keep-awake session records thermal state, battery, power source, lid position and Low Power
Mode; `sleepless report` reads the corpus back. The app does not act on heat.

**Why:** every other safety net here has an obvious threshold — the battery floor is a number you
pick, the timer a duration you choose, Low Power Mode a boolean the OS hands you. Thermal has
none. "Trip at `.serious`" is a guess, and a guessed threshold in a safety net is worse than no
net: it fires when it shouldn't, teaching you to ignore it, and when it stays quiet you believe
you are protected without evidence.

**Why thermal state alone would not be enough to build the real net later:** "hot" means something
entirely different in a closed bag on battery than on a desk on AC. Every sample carries the
context that distinguishes them.

**Two properties the report is built around, both worth protecting:**
- **Only heat with the lid CLOSED is flagged.** A warm Mac on a desk is a working Mac; flagging
  that would train the user to ignore the case that matters.
- **It never concludes "safe".** With no lid-closed sessions on record it reports the design as
  *untested*, because that corpus is silent about the only risky shape.

**The corpus is never rotated.** Summaries (one line per session) and per-minute samples are
separate streams precisely so a size cap cannot discard the oldest sessions — the rare session
that cooked in a bag is the one the whole exercise exists to capture. Only the bulky sample
stream has a cap. `uninstall.sh` keeps `sessions.jsonl` for the same reason.

**When it becomes a real net**, it belongs in the watchdog as a *lease-shortener* rather than a
new mechanism — the watchdog already ticks every 30s with the authority to clear the flag.

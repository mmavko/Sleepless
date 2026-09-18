# Design note: the lease and the dead-man switch

**Status:** all five steps landed. The app holds and renews a lease, the watchdog is live, and
`./install.sh` is safe to run. Step 5 is deliberately **instrumentation, not enforcement** — the
app records what sessions do and reports afterwards rather than acting on guessed thresholds.

## The problem

`pmset -a disablesleep 1` sets global kernel state that **no process owns**. Every safety net
in the app today — the auto-off timer, the battery floor, the Low Power Mode check — is an
in-memory `Timer` inside the GUI process. Kill the GUI and all of them die at once, while the
flag they were guarding stays set.

So the current honest summary is: *if the app crashes while ON, the Mac stays awake until you
reboot.* Upstream states this as a deliberate choice ("reboot resets it, and that reset is a
safety feature") and it is at least honest, but it is not a dead-man switch — it's the absence
of one. It's upstream issue [#8](https://github.com/Aboudjem/Sleepless/issues/8), and it's the
main reason this fork exists.

A menu-bar app cannot watch itself die. Something outside the process has to.

## The shape of the fix: invert ownership

Today the GUI **latches** the flag: set it, and it stays set until something explicitly unsets
it. The fix is to make it a **lease** instead: the flag stays set only while somebody keeps
saying "still needed", and a watchdog outside the app clears it when nobody does.

Three pieces:

| Piece | Job |
|---|---|
| **Lease file** | An absolute expiry timestamp. The single source of truth for *intent*. |
| **Watchdog** | A `launchd` job. Every tick: if `SleepDisabled` is set and the lease is missing or expired → clear it. |
| **Renewers** | The GUI switch and the CLI. Both only ever write the lease; neither latches anything. |

The flag itself stays exactly what it is today — the app still shells out to the same two
`pmset` commands under the same sudoers grant. Nothing about the privilege model changes.

### Why this and not the alternatives

- **A `caffeinate`-style process assertion** would be self-cleaning, but assertions can't beat
  lid close. That's the whole reason `disablesleep` is being used.
- **`pmset` with a TTL** doesn't exist.
- **Clearing the flag at login** (a `RunAtLoad` agent) helps only if you log out, which you
  won't.
- **Reboot**, today's answer, is correct but can be days away.

## Decision: LaunchAgent, not LaunchDaemon

The watchdog needs to clear the flag, which needs root. Two ways:

| | LaunchAgent (as you) | LaunchDaemon (as root) |
|---|---|---|
| New privilege | **none** — reuses the existing `sudo -n pmset -a disablesleep 0` grant | a root daemon to install and keep correct |
| Runs when logged out / at login window | no | yes |
| Install footprint | one plist in `~/Library/LaunchAgents` | `/Library/LaunchDaemons`, root-owned |

**Start with the agent.** It adds *zero* new privilege — the grant that already exists is
exactly the capability the watchdog needs — and it covers the realistic failure: the app
crashes while you're logged in with work running. Logged-out coverage is the only gap, and if
you're logged out you're not running Claude Code. Revisit the daemon only if that gap turns
out to be real.

This is the load-bearing decision in the whole design. Getting it right is what keeps this a
small tool rather than something that installs a root daemon.

## Timing

| Parameter | Proposed | Reasoning |
|---|---|---|
| Lease TTL | 120s | Worst case the Mac stays awake ~2.5 min after a crash, vs. until reboot. |
| Renewal interval | 30s | 4× headroom, so a slow tick or a brief hang doesn't drop a live lease. |
| Watchdog tick | 30s | `StartInterval`. Doesn't fire while the Mac sleeps — which is fine, since a sleeping Mac is not the failure case. |

The asymmetry matters: renewal must be much more frequent than expiry, or normal operation
looks like a crash.

## Lease file format, v1 — implemented

`~/Library/Application Support/Sleepless/lease`, mode 0600:

```
version=1
expires=1789456789      # unix epoch seconds
boot=1789400000         # kern.boottime sec, so a lease cannot outlive its boot
```

Every field is matched as an explicit run of digits. The file is **parsed, never sourced
and never eval'd** — a corrupt or hostile lease yields an empty field, which reads as "no
live lease", which clears the flag. The failure direction is always toward sleeping.

Written with write-then-rename so the watchdog can never read a half-written lease.
`sleepless` (the CLI) is the reference writer; the GUI writes the same format directly.

## Lease semantics

- `extend <ttl>` → `expiry = max(existing, now + ttl)`. Never shortens someone else's lease.
- `release` → remove the file. Explicit, and always allowed.
- Reject an expiry more than a few hours out; treat a wildly future timestamp as corrupt.
- Store it under `~/Library/Application Support/Sleepless/`. Single-user machine, user-owned,
  readable by the user's own agent. No reason for `/var/run`.
- Ignore a lease written before the current boot.

## Renewers

**The GUI**, while its switch is on. Same UX as today, but the switch now expresses intent
rather than latching state.

**A CLI** — `sleepless on [duration] | off | status | extend <ttl>` — which is the point for
this machine: a Claude Code `Stop` hook calls `sleepless off`, and a `SessionStart` or
`PreToolUse` hook extends the lease. That way the keep-awake window is bounded by the work
that actually needs it, and ending the session ends the lease, with the watchdog as the
backstop if the hook never fires.

michalekmatej's fork already has a CLI in the same binary (`on|off|toggle|status|timer`, with
proper `EX_USAGE`) and is worth reading before writing ours — but ours writes leases, not
`pmset` calls, so it isn't a cherry-pick.

Deliberately **not** doing: inferring "is Claude busy" by sniffing processes. Fragile, and the
hook is explicit and free.

## Failure modes

- **Watchdog not installed.** The GUI must refuse to turn on, or warn unmissably. Silently
  degrading to today's latch behaviour is the worst outcome — the user believes they have a
  dead-man switch and they don't. `install.sh` should load the agent and verify it.
- **Watchdog clears the flag while the GUI thinks it's on.** Already handled: the 60s poll
  reads true system state and the UI resyncs. This is exactly why upstream's "never trust a
  cached assumption, re-read `SleepDisabled`" discipline is worth keeping.
- **The `pmset` call fails in the watchdog.** Log it, retry next tick. The flag stays set, so
  the failure is visible rather than silent.
- **Clock jumps.** Wall-clock expiry with sanity bounds is good enough for a personal tool;
  the cost of being wrong is an early turn-off, not a drained battery.

## Thermal: measure before enforcing

Built as instrumentation rather than a safety net, and the reasoning is the point.

Every other net in this app has an *obvious* threshold: the battery floor is a number you pick,
the timer is a duration you choose, Low Power Mode is a boolean the OS hands you. Thermal has
none. "Trip at `.serious`" is a guess, and a guessed threshold in a safety net is worse than no
net at all — it fires when it shouldn't, teaching you to ignore it, and when it stays quiet you
believe you are protected without evidence.

So the app records instead: thermal state, battery, power source, lid position and Low Power
Mode, sampled on the 60s poll and on every thermal transition, appended as JSONL to
`~/Library/Application Support/Sleepless/sessions.jsonl` with a summary per session.
`sleepless report` reads the corpus back.

Two properties the report is built around:

- **Only heat with the lid CLOSED counts.** A warm Mac on a desk is a working Mac; the risky
  shape is a Mac cooking in a bag. Flagging the first would train you to ignore the second.
- **It never concludes "safe".** With no lid-closed sessions on record it says *untested*,
  because that corpus is silent about the only case that matters.

The single exception to reporting after the fact is `.critical`, notified immediately: at that
point the machine is already in trouble and a post-mortem is too late. But a notification you
were not there to see is lost, and this app exists precisely for when you are *not* at the Mac —
so the event is also persisted and shown in the popover and `sleepless status` for 24 hours,
ageing out by itself.

**A session's ending has to survive the closed lid.** The same argument as `.critical`, one
level up: the end-of-session notification fires while the lid is shut, so by construction nobody
sees it. The outcome is persisted, announced on the lid-open edge, and kept in the popover and
`sleepless status` for six hours — long enough to find after a nap, short enough not to
permanently mask the watchdog warning underneath it in the caption.

The reason is carried through verbatim rather than flattened to "off", because *which* net
stopped it is the entire question being asked. Two endings are special: `external` (the watchdog
cleared the flag — the app was no longer renewing) and `crash` (the app died with keep-awake on,
recovered at next launch from a session that never wrote its own ending). Nothing else tells the
user the dead-man switch actually fired.

**The corpus is never rotated.** Summaries (one line per session) and samples (per minute) are
separate streams for that reason: a single capped file discards the oldest sessions first, and
the rare session that cooked in a bag is the one the whole exercise exists to capture. Only the
bulky sample stream has a size cap.

**When it becomes a real net**, the design below still holds — the watchdog already ticks every
30s with the authority to clear the flag, so thermal becomes *"shorten the lease"* rather than a
new mechanism. The difference is that its numbers will come from the corpus instead of guesswork.

### The original plan, for when that day comes

The AI proposal that started this led with `ProcessInfo.thermalState`. It's a real signal, but
it's the wrong centrepiece: your app isn't generating the heat, and its only lever — sleep the
machine — kills the work you were protecting.

Once the lease exists, thermal has an obvious home. The watchdog already runs every 30s with
the authority to clear the flag, so thermal becomes *"shorten the lease"* rather than a new
mechanism:

- `.serious` → cap the lease at ~2 min and notify, so work can wind down.
- `.critical` → release immediately.

Which is why it's step 5, not step 1.

## Order of work

1. ~~Lease file format + the watchdog agent + `install.sh` / `uninstall.sh` integration.~~ **Done.**
2. ~~GUI writes and renews the lease; refuses to arm without a loaded watchdog.~~ **Done.**
3. ~~CLI.~~ **Done** — `sleepless extend | status | hook | report | off | release`.
4. ~~Claude Code hook wiring.~~ **Done** — one `PreToolUse` hook, see below.
5. Thermal — **instrumented, not enforced**. See below.

Steps 1–2 are the whole safety argument. Everything after is convenience.

## The hook design, after it was wrong twice

The first sketch was "`SessionStart` → on, `Stop` → off". Both halves are wrong:

- **`Stop` fires at the end of every assistant turn**, not at session end, so it would release
  after every response. `SessionEnd` is the session-level event.
- **`SessionEnd` is unreliable anyway.** Sessions linger, terminals get closed, nothing fires.

The second sketch fixed the parallel-session problem — first session out releases the shared
lease and kills the others — with reference-counted per-session holders (`leases.d/<session_id>`).
That was over-engineering, and the unreliability of `SessionEnd` is what shows why:

**If release is never the mechanism, refcounting isn't needed.** When holders only ever
*extend*, the `max()` floor semantics already in `leaselib.sh` compose correctly across any
number of writers on one file: whoever is active keeps the lease alive, and it lapses after the
last one goes quiet. No holder ids, no locking, no races. Expiry is the mechanism; release is a
courtesy.

So the whole integration is one hook and one verb:

```json
"PreToolUse": [{ "hooks": [{ "type": "command", "command": ".../sleepless extend" }] }]
```

Tool activity is the heartbeat; its absence is the signal to stop.

**`extend` must never arm keep-awake**, only prolong it — otherwise any Claude session anywhere
silently disables this Mac's sleep. The hook replaces the **timer**, not the **switch**.

**The idle timeout does not replace the auto-off timer.** They bound different things: the timer
is a wall-clock ceiling, the idle setting bounds inactivity. Without the ceiling, a session that
keeps calling tools holds the Mac awake indefinitely — on battery the floor catches it, on AC
nothing does. The idle setting is also opt-in (off by default), because until a hook is wired
nothing would ever extend the lease and every session would look idle.

**Subagents were a worry and turned out not to be.** Their tool calls fire the same configured
`PreToolUse` hooks as the main conversation (the input gains `agent_id` and `agent_type`), so
delegated work holds the lease with no extra configuration. Worth having checked: if it had gone
the other way, a long subagent run with an idle main loop would have looked exactly like "Claude
stopped working", and the Mac would have slept in the middle of it.

**Cost, stated plainly.** The timeout must exceed the longest *gap between tool calls*, since a
long build fires no hook until it finishes. `PreToolUse` firing before the call covers that, at
the price of up to one timeout of idle overhang after work stops — bounded by the floor and the
timer.

**The one real gap: background commands.** `PostToolUse` fires when a background command is
started, not while it runs. A long background job with the main loop waiting on it produces no
hooks at all. There is no "still running" event to hang a heartbeat on, so the answer is the
CLI's manual escape hatch — `sleepless extend 2h` before kicking one off — rather than more
machinery.

**A transcript fallback, so a missing hook is no longer silent.** Claude Code writes a
transcript per session under `~/.claude/projects`, from both the CLI and the desktop app, so
their mtimes say when it last did anything — with nothing to install and no way to fail quietly.
The hook stays primary (precise, push-based); this is the floor under it. The idea comes from
the sibling claude-tracker project, which rejected hooks for exactly this reason: *"transcripts
need no setup; hooks remain a fallback."*

We need far less than it does. It answers "is this session working, and is it the main agent or
only subagents", so it parses the last line for `end_turn` and tracks session identity. We need
one boolean heartbeat, so the newest mtime anywhere is enough — and double-counting a session
written to two project directories (which happens in a git worktree) is harmless here. Its
hard-won gotcha does carry over: a directory's mtime does not change when a file inside it is
written, so this stats files, not folders.

Cost: ~31 ms for 257 transcripts, on the main thread. So the scan only runs when the hook has
gone quiet — with a working hook it does not run at all.

**Detection, because a missing hook still matters.** Without a `PreToolUse` hook the idle
timeout has nothing to count and turns keep-awake off on schedule however hard Claude is working
— and nothing in that sequence looks like an error. So `sleepless hook` checks the user-level
settings files, `sleepless status` reports it, `install.sh` reminds, and the popover's hint line
shows the last time a tool call was actually seen. Project-level settings can't be checked from
outside the project, so a negative is always a reminder, never an error.

## Resolved while building

**Hard-refuse or warn when the watchdog is missing?** Neither, quite: the app presents it as
a choice, with **Cancel as the default button** and an explicit "Keep Awake Anyway" that lasts
for that app session only. Refusing outright is brittle; arming silently would recreate the
exact failure this fork exists to fix — believing you have a safety net you don't. The popover
caption also says so whenever the watchdog isn't loaded.

**Does the lease survive a GUI restart?** No. A clean quit releases the lease *and* restores
normal sleep directly, rather than leaving the Mac awake for up to one watchdog tick. The
watchdog stays the backstop for the case a clean quit cannot cover: a crash.

**Shell and Swift must agree on boot time, and that is now a test, not an assumption.** Both
scripts originally parsed `sysctl -n kern.boottime` with a greedy `.*sec = `, which matches
`usec = ` — so both read the *microseconds* field. They agreed with each other, so every test
passed, right up until `App.swift`'s `sysctlbyname` disagreed. That would have made the
watchdog reject every lease the app writes and clear the flag ~30s after arming. The shared
primitives now live in `leaselib.sh` so there is one copy to get wrong, and
`tests/watchdog-selftest.sh` asserts the shell and Swift values match.

## Open questions

- Agent vs daemon — agent recommended above, but it's a real trade and yours to make.
- TTL numbers: is ~2.5 min of unattended awake after a crash acceptable, or should it be tighter?

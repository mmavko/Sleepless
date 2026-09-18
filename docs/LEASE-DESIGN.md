# Design note: the lease and the dead-man switch

**Status:** design only. Nothing here is built yet.

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

## Where thermal fits — last, and as a lease-shortener

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

1. Lease file format + the watchdog agent + `install.sh` / `uninstall.sh` integration.
2. GUI writes and renews the lease; refuses to arm without a loaded watchdog.
3. CLI.
4. Claude Code hook wiring (`Stop` → `sleepless off`).
5. Thermal, as a lease-shortener.

Steps 1–2 are the whole safety argument. Everything after is convenience.

## Open questions

- Agent vs daemon — agent recommended above, but it's a real trade and yours to make.
- TTL numbers: is ~2.5 min of unattended awake after a crash acceptable, or should it be tighter?
- Should the GUI **hard-refuse** to arm without a watchdog, or arm with a loud warning?
- Does the lease survive a GUI restart (crash → relaunch inside the TTL keeps the Mac awake
  seamlessly), or should a fresh launch always start from released?

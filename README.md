# Sleepless (personal fork)

A macOS menu-bar toggle that keeps the Mac running with the lid closed, on battery, with no
external display — by flipping the kernel's `SleepDisabled` flag via `pmset disablesleep`.

This is a personal fork of **[Aboudjem/Sleepless](https://github.com/Aboudjem/Sleepless)** by
Adam Boudjemaa (MIT). All the hard-won mechanism is his. This fork trades the polished public
product for a smaller, stricter personal tool.

- **What's different, and why:** [docs/FORK.md](docs/FORK.md)
- **Upstream's original README**, kept verbatim: [README.upstream.md](README.upstream.md)
  (its Homebrew install, badges and comparison table apply to upstream, not here)

## Why this exists at all

`disablesleep` is only *needed* for one narrow case: **lid closed, on battery, no external
display**. Plug in power or attach a display and macOS clamshell mode already does the job.
Keeping that scope explicit is what stops the app growing into a power manager.

## Install

```bash
./install.sh
```

Builds the app, installs the sudoers grant, and loads the watchdog agent.

`build.sh` compiles `App.swift` with `swiftc` and hand-assembles an ad-hoc-signed bundle —
no Xcode project, no downloaded blobs.

`grant.sh` installs one `/etc/sudoers.d` drop-in (root:wheel, 0440) permitting exactly two
fully-specified commands and nothing else:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

Run it yourself, once per machine. **The app never installs it** — see
[docs/FORK.md](docs/FORK.md) for why that path was deleted rather than fixed.

`./uninstall.sh` removes the app, the login item and the grant, then proves the grant is gone.

## Safety nets

`disablesleep` is global kernel state that no process owns, and every in-app net dies with the
process. So the app doesn't latch the flag — it holds a **lease** it must keep renewing, and a
`launchd` watchdog clears the flag when nobody does. See [docs/LEASE-DESIGN.md](docs/LEASE-DESIGN.md).

| Net | Behaviour |
|---|---|
| Battery floor | Turns off at 5–50% on battery (default 15%). Beats a deliberate turn-on. |
| Low Power Mode | Steps aside when LPM is on and discharging, unless you deliberately turned it on. |
| Auto-off timer | 1h / 2h wall-clock ceiling, live countdown. Retries if the privileged call fails. |
| Idle timeout | Off by default. Stops N minutes after **Claude Code** last did anything. |
| Lid close | Puts the built-in display to sleep, so a closed laptop isn't lit, hot and unlocked. |
| Crash / force-quit | A watchdog outside the app clears the flag within ~2.5 min. **The dead man's switch.** |
| Reboot | macOS resets `disablesleep` to 0. |

Every net now **fails closed**: if the privileged call fails, the app says so and stays armed
rather than announcing a turn-off that never happened.

## Known gaps

- **Thermal protection is instrumented, not enforced.** The app records what each keep-awake
  session actually did and reports afterwards; it does not yet act on heat. See below.
- **No thermal awareness.** Deliberately last; see the design note.
- **Lid-close display sleep is untested on hardware.** Verify before trusting it in a bag.

## Claude Code integration

> This feature knows about **Claude Code specifically** — nothing else. It watches Claude Code
> tool calls and transcripts, and has no idea whether any other agent or long-running job is
> working. For those, use the auto-off timer.


The point of the idle timeout: keep the Mac awake exactly as long as Claude is working, with
no timer to guess at. One hook does it — in `~/.claude/settings.json` for every session on
this machine, or `.claude/settings.json` for one project:

```json
{
  "hooks": {
    "PreToolUse": [
      { "hooks": [{ "type": "command", "command": "/Users/you/dev/sleepless/sleepless extend" }] }
    ]
  }
}
```

Then set **Stop when Claude Code goes idle** in the popover.

**The hook is optional.** Without it the app falls back to watching Claude Code transcript
mtimes under `~/.claude/projects`, which needs no setup and cannot silently fail — the idea is
borrowed from the sibling claude-tracker project. The hook is still worth adding because it's
precise and push-based; the fallback only knows that Claude did *something*. `./sleepless hook`
tells you whether it's wired up, and `./install.sh` reminds you if it isn't.

- **`extend` never arms keep-awake**, only prolongs it. You still flip the switch deliberately
  when you're about to close the lid; the hook only decides *when it ends*. Otherwise any
  Claude session anywhere would silently disable your Mac's sleep.
- **Parallel sessions just work.** Everyone extends, nobody releases, and the lease uses
  `max()` — so it lapses once the last session goes quiet, not the first. No session ids, no
  refcounting, no locking.
- **No `Stop` or `SessionEnd` hook.** `Stop` fires at the end of *every turn*, and `SessionEnd`
  often never fires at all. Expiry is the mechanism; release is only a courtesy.
- **Subagents count.** A subagent's tool calls fire the same configured `PreToolUse` hooks as
  the main conversation, with `agent_id` / `agent_type` added to the input. So a long
  delegated job keeps the lease alive without any extra configuration.
- **Pick a timeout longer than your longest gap between tool calls.** A 30-minute build fires no
  hook until it finishes, and `PreToolUse` fires before it — so a 20m timeout covers it, at the
  cost of up to 20 minutes of idle overhang. The battery floor and the auto-off timer bound that.
- **Background commands are the one real gap.** `PostToolUse` fires when a background command is
  *started*, not while it runs — so if Claude kicks off a 40-minute background build and then
  waits, nothing fires for that whole stretch. Before something like that, hold the lease by
  hand:

  ```bash
  ./sleepless extend 2h
  ```

`sleepless status` shows all three things that matter:

```bash
./sleepless status
```

## What actually happened: `sleepless report`

Thermal protection is the one safety net whose thresholds would be **guessed**, and a guessed
threshold is worse than none — it trips when it shouldn't and lends false confidence when it
doesn't. So rather than act on heat, the app records it:

```bash
./sleepless report
```

Two streams, with deliberately different lifetimes:

| File | What | Rotated |
|---|---|---|
| `sessions.jsonl` | one summary line per keep-awake session — **the corpus** | **never** |
| `samples.jsonl` | thermal / battery / lid / power, each minute and on every thermal change | at 20 MB |

The summaries are never discarded, because a size cap drops the oldest sessions first and the
rare one that cooked in a bag is exactly the one worth keeping. They're tiny — a few hundred
bytes per session. The per-minute samples are the bulk (~115 bytes each, ~10 MB/year at 4h/day)
and only matter for recent detail, so those rotate.

Two things it deliberately does:

- **It only flags heat with the lid closed.** A warm Mac on a desk is a working Mac. The risky
  shape is heat in a closed bag, and a report that cried wolf on the first would be worse than
  no report.
- **It never says "safe".** If no session has run with the lid closed, it says the design is
  *untested*, not safe — because that corpus cannot tell you anything about the case that matters.

`.critical` thermal state is the one thing reported in the moment, since a post-mortem there is
too late. It's also **recorded where it outlives the notification** — you were probably not at
the Mac when it fired — so the popover and `sleepless status` keep showing it for 24 hours,
then it ages out on its own.

## Verify it yourself

The whole app is one 750-line file. [SECURITY.md](SECURITY.md) explains why the design is
safe; [docs/AUDIT.md](docs/AUDIT.md) shows how to confirm it. Both are upstream's, and both
became *more* accurate in this fork — the code path they never mentioned is the one that's
now gone.

## License

MIT, © 2026 Adam Boudjemaa. See [LICENSE](LICENSE).
